import Foundation

enum ANCMode: Equatable {
    case anc
    case ambient
    case off
}

/// A device reported by the headphones' pairing-device-management message.
struct MultipointDevice: Identifiable, Equatable {
    let address: String
    let name: String
    let isConnected: Bool

    var id: String { address }
    var displayName: String { name.isEmpty ? address : name }
}

/// Equalizer state reported by the headphones (table 1 EQ/EBB, preset EQ).
/// `bands` are signed steps (normally -10...+10). On 6-value models the first
/// value is Clear Bass and the rest are 400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz, 16 kHz.
struct EqualizerState: Equatable {
    var presetID: UInt8
    var bands: [Int]
}

struct EqualizerPreset: Identifiable, Hashable {
    let id: UInt8
    let name: String

    var isCustomSlot: Bool { id >= 0xA0 && id <= 0xA5 }

    static func name(for id: UInt8) -> String {
        switch id {
        case 0x00: return "Off"
        case 0x01: return "Rock"
        case 0x02: return "Pop"
        case 0x03: return "Jazz"
        case 0x04: return "Dance"
        case 0x05: return "EDM"
        case 0x06: return "R&B/Hip-Hop"
        case 0x07: return "Acoustic"
        case 0x10: return "Bright"
        case 0x11: return "Excited"
        case 0x12: return "Mellow"
        case 0x13: return "Relaxed"
        case 0x14: return "Vocal"
        case 0x15: return "Treble Boost"
        case 0x16: return "Bass Boost"
        case 0x17: return "Speech"
        case 0x18: return "Heavy"
        case 0x19: return "Clear"
        case 0x1A: return "Hard"
        case 0x1B: return "Soft"
        case 0xA0: return "Manual"
        case 0xA1...0xA5: return "Custom \(id - 0xA0)"
        default: return String(format: "Preset %02X", id)
        }
    }

    /// Presets offered by current WF/WH-1000X-class models when the headset
    /// does not describe its own list.
    static let defaultList: [EqualizerPreset] = [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0, 0xA1, 0xA2]
        .map { EqualizerPreset(id: $0, name: name(for: $0)) }
}

/// Battery levels in percent. `nil` means the headset has not reported it.
struct BatteryState: Equatable {
    var single: Int?
    var singleCharging = false
    var left: Int?
    var leftCharging = false
    var right: Int?
    var rightCharging = false
    var caseLevel: Int?
    var caseCharging = false

    var hasAny: Bool { single != nil || left != nil || right != nil || caseLevel != nil }
}

/// MDR V2 client for compatible link2 accessories.
///
/// Noise control uses table 1 messages. Multipoint audio-source switching uses
/// table 2 "peripheral" messages carried over the second command channel.
final class HeadsetClient {
    static let accessoryProtocol = "jp.co.sony.songpal.mdr.link2"

    private enum FrameType {
        static let ack: UInt8 = 0x01
        static let command1: UInt8 = 0x0C
        static let command2: UInt8 = 0x0E
    }

    /// Table 2 peripheral command and inquired-type values, as used by the headset's
    /// link2 implementation for pairing-device management and source switching.
    private enum Table2 {
        static let frameType = FrameType.command2
        static let getParam: UInt8 = 0x36
        static let retParam: UInt8 = 0x37
        static let setParam: UInt8 = 0x38
        static let notifyParam: UInt8 = 0x39
        static let setExtendedParam: UInt8 = 0x3C
        static let notifyExtendedParam: UInt8 = 0x3D

        static let inquiredPairingDeviceManagement: UInt8 = 0x00
        static let inquiredSourceSwitchControl: UInt8 = 0x01

        /// Address fields are fixed-width 17-byte ASCII strings ("AA:BB:...").
        static let addressLength = 17
    }

    /// Table 1 device-information messages. The headset answers a GET with the
    /// requested field. Info types start at 1:
    /// 1 = model name, 2 = firmware version, 3 = series/color, 4 = guide.
    /// The model name occupies the rest of the payload as UTF-8 text.
    private enum Table1 {
        static let getDeviceInfo: UInt8 = 0x04
        static let retDeviceInfo: UInt8 = 0x05
        static let deviceInfoModelName: UInt8 = 0x01

        // Power (battery) family: get status / ret status / notify status.
        static let powerGetStatus: UInt8 = 0x22
        static let powerRetStatus: UInt8 = 0x23
        static let powerNotifyStatus: UInt8 = 0x25
        static let batterySingle: UInt8 = 0x00
        static let batteryLeftRight: UInt8 = 0x01
        static let batteryCradle: UInt8 = 0x02

        // EQ/EBB family. Inquired type 0x00 is the preset EQ.
        static let eqGetCapability: UInt8 = 0x50
        static let eqRetCapability: UInt8 = 0x51
        static let eqGetParam: UInt8 = 0x56
        static let eqRetParam: UInt8 = 0x57
        static let eqSetParam: UInt8 = 0x58
        static let eqNotifyParam: UInt8 = 0x59
        static let eqInquiredPresetEq: UInt8 = 0x00
        /// Band values are sent and received offset by +10 (0...20 on the wire).
        static let eqBandOffset = 10
    }

    private enum Stage {
        case idle, protocolInfo, supportFunctions, noiseControl, ready
    }

    private let sendBytes: (Data) -> Void
    private var receiveBuffer = Data()
    private var transmitSequence: UInt8 = 0
    private var waitingForAck = false
    private var queue: [Data] = []
    private var stage: Stage = .idle
    private var selectedAsm: UInt8?
    private(set) var currentMode: ANCMode?
    private var focusVoice: UInt8 = 0
    private var ambientLevel: UInt8 = 10
    private var ackTimeout: DispatchWorkItem?
    private var multipointRefreshWorkItem: DispatchWorkItem?
    private var lastMultipointRequest: Date?

    private(set) var equalizer: EqualizerState?
    private(set) var battery = BatteryState()

    /// Whether the device list's playback byte counts devices from 0 or 1.
    /// A WF-1000XM5 reported 1 while the second device was playing, so 0 is
    /// the default. The value is confirmed (and saved) the first time a switch
    /// we requested changes the byte: it then must point at the target.
    private var playbackIndexBase = UserDefaults.standard.object(forKey: "multipointPlaybackIndexBase") as? Int ?? 0
    private var lastRawPlaybackIndex: Int?
    private var switchTarget: (address: String, requested: Date)?

    private(set) var multipointDevices: [MultipointDevice] = []
    private(set) var activeSourceAddress: String?

    var onStatus: ((String, Bool, String?) -> Void)?
    var onAmbientLevel: ((Int) -> Void)?
    var onMode: ((ANCMode) -> Void)?
    var onNoiseCancellationAvailability: ((Bool) -> Void)?
    var onMultipoint: (([MultipointDevice], String?) -> Void)?
    var onModelName: ((String) -> Void)?
    var onEqualizer: ((EqualizerState) -> Void)?
    var onEqualizerPresets: (([EqualizerPreset]) -> Void)?
    var onBattery: ((BatteryState) -> Void)?

    init(send: @escaping (Data) -> Void) {
        self.sendBytes = send
    }

    func start() {
        receiveBuffer.removeAll()
        queue.removeAll()
        waitingForAck = false
        transmitSequence = 0
        stage = .protocolInfo
        ackTimeout?.cancel()
        ackTimeout = nil
        multipointRefreshWorkItem?.cancel()
        multipointRefreshWorkItem = nil
        lastMultipointRequest = nil
        multipointDevices = []
        activeSourceAddress = nil
        equalizer = nil
        battery = BatteryState()
        onMultipoint?([], nil)
        onStatus?("Connected · checking headset protocol", false, nil)
        enqueue(payload: [0x00, 0x00])
    }

    func setMode(_ mode: ANCMode) {
        guard stage == .ready, let asm = selectedAsm else {
            onStatus?("ANC control is not ready", false, "Wait for the headset capability check to finish.")
            return
        }
        if mode == .anc, asm == 0x21 || asm == 0x22 {
            onStatus?("Noise cancellation is not supported", true, "This model advertises Ambient Sound control only.")
            return
        }

        let on: UInt8 = mode == .off ? 0 : 1
        var payload: [UInt8] = [0x68, asm, 0x01, on]
        if asm != 0x21 && asm != 0x22 {
            payload.append(mode == .ambient ? 0x01 : 0x00)
        }
        if asm == 0x15 { payload.append(0x02) } // stable non-wind noise-cancelling mode
        payload += [focusVoice, max(1, ambientLevel)]
        if asm == 0x19 { payload += [0x00, 0x00] }
        enqueue(payload: payload)
        currentMode = mode
        let name: String
        switch mode {
        case .anc: name = "ANC On"
        case .ambient: name = "Ambient Sound"
        case .off: name = "ANC Off"
        }
        onStatus?("\(name) command sent", true, "The headset should confirm the change over the accessory session.")
    }

    func setAmbientLevel(_ level: Int, applyIfAmbient: Bool = false) {
        ambientLevel = UInt8(max(1, min(level, 20)))
        if applyIfAmbient, currentMode == .ambient { setMode(.ambient) }
    }

    func refreshNoiseControlState() {
        guard stage == .ready, let asm = selectedAsm else { return }
        enqueue(payload: [0x66, asm])
    }

    /// Asks the headphones for their paired/connected device list and the
    /// device that currently owns audio playback.
    func requestMultipointState() {
        guard stage == .ready else { return }
        lastMultipointRequest = Date()
        enqueue(
            payload: [Table2.getParam, Table2.inquiredPairingDeviceManagement],
            type: Table2.frameType
        )
    }

    /// Asks the headphones to move audio playback to `address`
    /// (a "AA:BB:CC:DD:EE:FF" Bluetooth address reported earlier).
    func switchAudioSource(to address: String) {
        guard stage == .ready else {
            onStatus?("Audio source switching is not ready", false, "Wait for the headset capability check to finish.")
            return
        }
        let normalized = address.uppercased()
        let addressBytes = Array(normalized.utf8)
        guard addressBytes.count == Table2.addressLength else {
            onStatus?("Could not switch audio source", false, "The headset reported an unusable device address.")
            return
        }
        enqueue(
            payload: [Table2.setExtendedParam, Table2.inquiredSourceSwitchControl] + addressBytes,
            type: Table2.frameType
        )
        switchTarget = (normalized, Date())
        scheduleMultipointRefresh()
    }

    func requestEqualizer() {
        guard stage == .ready else { return }
        enqueue(payload: [Table1.eqGetParam, Table1.eqInquiredPresetEq])
    }

    /// Selects a preset. The headset replies/notifies with the preset's bands.
    func setEqualizerPreset(_ presetID: UInt8) {
        guard stage == .ready else { return }
        enqueue(payload: [Table1.eqSetParam, Table1.eqInquiredPresetEq, presetID, 0x00])
        if var state = equalizer {
            state.presetID = presetID
            equalizer = state
        }
    }

    /// Writes custom band values (signed steps, clamped to -10...+10) into
    /// `presetID`, which should be a custom slot (0xA0...0xA5).
    func setEqualizerBands(_ bands: [Int], presetID: UInt8) {
        guard stage == .ready, !bands.isEmpty else { return }
        let encoded = bands.map { UInt8(max(0, min(20, $0 + Table1.eqBandOffset))) }
        enqueue(payload: [Table1.eqSetParam, Table1.eqInquiredPresetEq, presetID, UInt8(encoded.count)] + encoded)
        equalizer = EqualizerState(presetID: presetID, bands: bands.map { max(-10, min(10, $0)) })
    }

    func requestBattery() {
        guard stage == .ready else { return }
        // Models answer only the battery types they have; unsupported ones
        // fall through the ACK timeout.
        enqueue(payload: [Table1.powerGetStatus, Table1.batteryLeftRight])
        enqueue(payload: [Table1.powerGetStatus, Table1.batteryCradle])
        enqueue(payload: [Table1.powerGetStatus, Table1.batterySingle])
    }

    func receive(_ bytes: Data) {
        receiveBuffer.append(bytes)
        while let start = receiveBuffer.firstIndex(of: 0x3E) {
            if start > receiveBuffer.startIndex { receiveBuffer.removeSubrange(..<start) }
            guard let end = receiveBuffer.dropFirst().firstIndex(of: 0x3C) else { return }
            let frame = Data(receiveBuffer[...end])
            receiveBuffer.removeSubrange(...end)
            parse(frame)
        }
    }

    private func parse(_ frame: Data) {
        guard frame.count >= 3 else { return }
        var raw: [UInt8] = []
        var index = 1
        while index < frame.count - 1 {
            let byte = frame[index]
            if byte == 0x3D {
                index += 1
                guard index < frame.count - 1 else { return }
                raw.append(frame[index] | 0x10)
            } else {
                raw.append(byte)
            }
            index += 1
        }
        guard raw.count >= 7,
              raw.dropLast().reduce(0, { ($0 + Int($1)) & 0xFF }) == Int(raw.last!) else { return }
        let type = raw[0]
        let sequence = raw[1]
        let length = Int(raw[2]) << 24 | Int(raw[3]) << 16 | Int(raw[4]) << 8 | Int(raw[5])
        guard length >= 0, length <= raw.count - 7 else { return }
        let payload = Array(raw[6..<(6 + length)])

        if type == FrameType.ack {
            ackTimeout?.cancel()
            ackTimeout = nil
            waitingForAck = false
            pump()
            return
        }
        guard type == FrameType.command1 || type == FrameType.command2 else { return }
        send(payload: [], type: FrameType.ack, sequence: 1 - sequence)
        if type == FrameType.command2 {
            handleTable2Payload(payload)
            return
        }
        guard let command = payload.first else { return }

        switch command {
        case 0x01 where stage == .protocolInfo:
            stage = .supportFunctions
            enqueue(payload: [0x06, 0x00])
        case 0x07 where stage == .supportFunctions:
            guard payload.count >= 3 else { fail("Invalid support-function reply."); return }
            let numberOfFunctions = Int(payload[2])
            guard payload.count >= 3 + numberOfFunctions * 2 else { fail("Truncated support-function reply."); return }
            var functions = Set<UInt8>()
            for i in 0..<numberOfFunctions { functions.insert(payload[3 + i * 2]) }
            let supported: [(UInt8, UInt8)] = [(0x6D, 0x19), (0x6B, 0x17), (0x68, 0x15), (0x67, 0x22), (0x66, 0x21)]
            guard let chosen = supported.first(where: { functions.contains($0.0) }) else {
                fail("The headset did not advertise a supported NC/ambient control function.")
                return
            }
            selectedAsm = chosen.1
            onNoiseCancellationAvailability?(chosen.1 != 0x21 && chosen.1 != 0x22)
            stage = .noiseControl
            enqueue(payload: [0x66, chosen.1])
            // Ask for the model name so the UI can name the headset instead of
            // showing a generic label. Sent after the mode request so it does
            // not delay the first state refresh.
            enqueue(payload: [Table1.getDeviceInfo, Table1.deviceInfoModelName])
        case Table1.retDeviceInfo where payload.count >= 2 && payload[1] == Table1.deviceInfoModelName:
            var nameBytes = Array(payload.dropFirst(2))
            while nameBytes.last == 0 { nameBytes.removeLast() }
            let modelName = String(decoding: nameBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelName.isEmpty { onModelName?(modelName) }
        case Table1.eqRetParam, Table1.eqNotifyParam:
            guard payload.count >= 4, payload[1] == Table1.eqInquiredPresetEq else { return }
            let count = Int(payload[3])
            let values = payload.dropFirst(4).prefix(count).map { Int($0) - Table1.eqBandOffset }
            let state = EqualizerState(
                presetID: payload[2],
                bands: values.count == count ? values : (equalizer?.bands ?? values)
            )
            equalizer = state
            onEqualizer?(state)
        case Table1.eqRetCapability:
            if let presets = parseEqualizerPresets(payload), !presets.isEmpty {
                onEqualizerPresets?(presets)
            }
        case Table1.powerRetStatus, Table1.powerNotifyStatus:
            applyBattery(payload)
        case 0x67, 0x69:
            guard payload.count >= 4, payload.count > 1, payload[1] == selectedAsm else { return }
            if payload.count >= 6 {
                let levelIndex = payload.count - (selectedAsm == 0x19 ? 3 : 1)
                if payload.indices.contains(levelIndex), payload[levelIndex] <= 20 {
                    ambientLevel = max(1, payload[levelIndex])
                    onAmbientLevel?(Int(ambientLevel))
                }
            }
            let ambientOnly = selectedAsm == 0x21 || selectedAsm == 0x22
            let mode: ANCMode = payload[3] == 0 ? .off : (ambientOnly || (payload.count > 4 && payload[4] != 0) ? .ambient : .anc)
            currentMode = mode
            onMode?(mode)
            if stage == .noiseControl {
                stage = .ready
                onStatus?("Connected · ready", true, "\(mode.displayName) reported by the headphones.")
                enqueue(payload: [Table1.eqGetCapability, Table1.eqInquiredPresetEq])
                requestEqualizer()
                requestBattery()
                scheduleMultipointRefresh(delay: 0.2)
            } else if stage == .ready {
                onStatus?("Connected · ready", true, "\(mode.displayName) reported by the headphones.")
            }
        default:
            break
        }
    }

    private func enqueue(payload: [UInt8], type: UInt8 = FrameType.command1) {
        queue.append(makeFrame(type: type, sequence: nil, payload: payload))
        pump()
    }

    private func send(payload: [UInt8], type: UInt8, sequence: UInt8?) {
        sendBytes(makeFrame(type: type, sequence: sequence, payload: payload))
    }

    private func pump() {
        guard !waitingForAck, !queue.isEmpty else { return }
        waitingForAck = true
        sendBytes(queue.removeFirst())
        // A headset may ignore a command it does not implement (for example
        // multipoint messages on a non-multipoint model). Do not let that stall
        // everything behind it in the queue.
        ackTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.waitingForAck else { return }
            self.ackTimeout = nil
            self.waitingForAck = false
            self.pump()
        }
        ackTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }

    private func makeFrame(type: UInt8, sequence: UInt8?, payload: [UInt8]) -> Data {
        let seq: UInt8
        if let sequence { seq = sequence }
        else {
            seq = transmitSequence
            transmitSequence = 1 - transmitSequence
        }
        let length = UInt32(payload.count)
        var body: [UInt8] = [type, seq, UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + payload
        let checksum = UInt8(body.reduce(0) { ($0 + Int($1)) & 0xFF })
        body.append(checksum)
        var result: [UInt8] = [0x3E]
        for byte in body {
            if byte == 0x3C || byte == 0x3D || byte == 0x3E {
                result += [0x3D, byte & 0xEF]
            } else {
                result.append(byte)
            }
        }
        result.append(0x3C)
        return Data(result)
    }

    private func handleTable2Payload(_ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        let command = payload[0]
        let inquiredType = payload[1]

        if (command == Table2.retParam || command == Table2.notifyParam),
           inquiredType == Table2.inquiredPairingDeviceManagement {
            applyDeviceList(payload)
            return
        }
        if command == Table2.notifyParam || command == Table2.notifyExtendedParam {
            // A device connected/disconnected or playback moved (including the
            // confirmation of our own switch request). Re-read the list so the
            // active-device marker comes from the headset. Debounced rather than
            // dropped: a switch confirmation usually lands within a second of the
            // previous request, and dropping it left the old device marked.
            // Replies to our GET are `retParam`, not notifies, so this cannot loop.
            let sinceLast = lastMultipointRequest.map { Date().timeIntervalSince($0) } ?? 10
            scheduleMultipointRefresh(delay: max(0.3, 1.0 - sinceLast))
        }
    }

    /// Payload layout reported by the headphones:
    /// `[command, 0x00, count]` followed by `count` entries of
    /// `17-byte ASCII address | 1-byte status | 1-byte name length | name`,
    /// and finally one byte with the 1-based index of the playback device
    /// (0 when no device is active).
    private func applyDeviceList(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        let count = Int(payload[2])
        guard count >= 0, count <= 32 else { return }

        var index = 3
        var devices: [MultipointDevice] = []
        for _ in 0..<count {
            guard index + Table2.addressLength + 2 <= payload.count else { return }
            let address = String(decoding: payload[index..<(index + Table2.addressLength)], as: UTF8.self)
            index += Table2.addressLength
            let status = Int(payload[index])
            index += 1
            let nameLength = Int(payload[index])
            index += 1
            guard nameLength >= 0, index + nameLength <= payload.count else { return }
            let name = String(decoding: payload[index..<(index + nameLength)], as: UTF8.self)
            index += nameLength
            devices.append(MultipointDevice(address: address, name: name, isConnected: status > 0))
        }

        var active: String?
        if index < payload.count {
            let raw = Int(payload[index])
            learnPlaybackIndexBase(raw: raw, devices: devices)
            lastRawPlaybackIndex = raw
            let position = raw - playbackIndexBase
            if devices.indices.contains(position) {
                active = devices[position].address
            }
        }

        multipointDevices = devices
        activeSourceAddress = active
        onMultipoint?(devices, active)
    }

    /// After a switch we asked for, the first change in the playback byte
    /// tells us how it counts: equal to the target's position means 0-based,
    /// one more means 1-based.
    private func learnPlaybackIndexBase(raw: Int, devices: [MultipointDevice]) {
        guard let target = switchTarget else { return }
        if Date().timeIntervalSince(target.requested) > 10 { switchTarget = nil; return }
        guard let last = lastRawPlaybackIndex, raw != last,
              let position = devices.firstIndex(where: { $0.address.uppercased() == target.address }) else { return }
        switchTarget = nil
        let base: Int
        if raw == position { base = 0 } else if raw == position + 1 { base = 1 } else { return }
        if base != playbackIndexBase {
            playbackIndexBase = base
        }
        UserDefaults.standard.set(base, forKey: "multipointPlaybackIndexBase")
    }

    private func applyBattery(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        func level(_ byte: UInt8) -> Int? { byte <= 100 ? Int(byte) : nil }
        switch payload[1] {
        case Table1.batteryLeftRight where payload.count >= 6:
            battery.left = payload[2] == 0 ? nil : level(payload[2])
            battery.leftCharging = payload[3] != 0
            battery.right = payload[4] == 0 ? nil : level(payload[4])
            battery.rightCharging = payload[5] != 0
        case Table1.batteryCradle where payload.count >= 4:
            battery.caseLevel = level(payload[2])
            battery.caseCharging = payload[3] != 0
        case Table1.batterySingle where payload.count >= 4:
            battery.single = level(payload[2])
            battery.singleCharging = payload[3] != 0
        default:
            return
        }
        onBattery?(battery)
    }

    /// Best-effort read of the preset list in an EQ capability reply. The
    /// layout is not confirmed, so only a list that consumes the payload
    /// exactly as `[id, nameLength, name...]` entries is accepted; otherwise
    /// the caller keeps its default list.
    private func parseEqualizerPresets(_ payload: [UInt8]) -> [EqualizerPreset]? {
        guard payload.count >= 5, payload[1] == Table1.eqInquiredPresetEq else { return nil }
        for countIndex in 3...min(5, payload.count - 1) {
            let count = Int(payload[countIndex])
            guard count > 0, count <= 32 else { continue }
            var index = countIndex + 1
            var presets: [EqualizerPreset] = []
            var valid = true
            for _ in 0..<count {
                guard index + 2 <= payload.count else { valid = false; break }
                let id = payload[index]
                let nameLength = Int(payload[index + 1])
                index += 2
                guard index + nameLength <= payload.count else { valid = false; break }
                let reported = String(decoding: payload[index..<(index + nameLength)], as: UTF8.self)
                index += nameLength
                let name = reported.trimmingCharacters(in: .whitespacesAndNewlines)
                presets.append(EqualizerPreset(id: id, name: name.isEmpty ? EqualizerPreset.name(for: id) : name))
            }
            if valid, index == payload.count, Set(presets.map(\.id)).count == presets.count { return presets }
        }
        return nil
    }

    private func scheduleMultipointRefresh(delay: TimeInterval = 0.8) {
        multipointRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.stage == .ready else { return }
            self.multipointRefreshWorkItem = nil
            self.requestMultipointState()
        }
        multipointRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func fail(_ message: String) {
        stage = .idle
        selectedAsm = nil
        onStatus?("Headset protocol not ready", false, message)
    }
}

extension ANCMode {
    var shortcutValue: String {
        switch self {
        case .anc: return "ANC"
        case .ambient: return "Ambient"
        case .off: return "Off"
        }
    }

    var displayName: String {
        switch self {
        case .anc: return "Noise Cancellation"
        case .ambient: return "Ambient Sound"
        case .off: return "Off"
        }
    }
}
