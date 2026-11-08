import Foundation
import ExternalAccessory
import Combine

@MainActor
final class ANCController: ObservableObject {
    @Published private(set) var status = "Pair and connect your headphones in iOS Settings, then refresh."
    @Published private(set) var detail: String?
    @Published private(set) var accessoryName: String?
    @Published private(set) var accessoryModelNumber: String?
    @Published private(set) var reportedModelName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isReady = false
    @Published private(set) var ambientLevel = 10
    @Published private(set) var currentMode: ANCMode?
    @Published private(set) var supportsNoiseCancellation = true
    @Published private(set) var multipointDevices: [MultipointDevice] = []
    @Published private(set) var activeSourceAddress: String?
    /// Device we asked the headset to switch to, until it reports it active
    /// or the request times out.
    @Published private(set) var pendingSourceAddress: String?
    @Published private(set) var sourceSwitchFailed = false
    @Published private(set) var sourceSwitchMessage = "The headphones didn't confirm the switch."
    private var sourceSwitchTask: Task<Void, Never>?
    @Published private(set) var equalizer: EqualizerState?
    @Published private(set) var equalizerPresets: [EqualizerPreset] = EqualizerPreset.defaultList
    @Published private(set) var battery = BatteryState()
    private var modeRevision = 0
    private var multipointRevision = 0

    static let shared = ANCController()

    /// Name shown in the header. The headset's own model string is preferred,
    /// then an accessory name that looks like a headphone model, then the
    /// accessory's model number, then the raw accessory name.
    var displayName: String {
        if let reportedModelName, !reportedModelName.isEmpty { return reportedModelName }
        if let accessoryName, Self.looksLikeModelName(accessoryName) { return accessoryName }
        if let accessoryModelNumber, !accessoryModelNumber.isEmpty { return accessoryModelNumber }
        return accessoryName ?? "Headphones"
    }

    private static func looksLikeModelName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["WH-", "WF-", "WI-", "MDR-", "LINKBUDS", "ULT "].contains { upper.contains($0) }
    }

    private let manager = EAAccessoryManager.shared()
    private var transport: ExternalAccessoryTransport?
    private var protocolClient: HeadsetClient?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryChanged(_:)),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryChanged(_:)),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )
        manager.registerForLocalNotifications()
        refreshAccessories()
        widgetSync = WidgetSync(controller: self)
    }

    private var widgetSync: WidgetSync?

    deinit {
        NotificationCenter.default.removeObserver(self)
        manager.unregisterForLocalNotifications()
    }

    @objc private func accessoryChanged(_ notification: Notification) {
        Task { @MainActor in refreshAccessories() }
    }

    func refreshAccessories() {
        let accessories = manager.connectedAccessories
        guard let accessory = accessories.first(where: {
            $0.protocolStrings.contains(HeadsetClient.accessoryProtocol)
        }) else {
            isConnected = false
            isReady = false
            currentMode = nil
            supportsNoiseCancellation = true
            multipointDevices = []
            activeSourceAddress = nil
            equalizer = nil
            battery = BatteryState()
            accessoryName = nil
            accessoryModelNumber = nil
            reportedModelName = nil
            status = "No compatible accessory session is available. Pair and connect your headphones in iOS Settings, then refresh."
            detail = "This build looks for the link2 accessory protocol and compatible noise-control features."
            transport?.close()
            transport = nil
            protocolClient = nil
            return
        }

        accessoryName = accessory.name
        let modelNumber = accessory.modelNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        accessoryModelNumber = modelNumber.isEmpty ? nil : modelNumber
        open(accessory)
    }

    func setMode(_ mode: ANCMode) {
        currentMode = mode
        protocolClient?.setMode(mode)
    }

    /// Toggles between ANC and Ambient, used by the switch button next to the
    /// listening-mode control.
    func toggleANCAndAmbient() {
        guard supportsNoiseCancellation else { return }
        let next: ANCMode = currentMode == .ambient ? .anc : .ambient
        setMode(next)
    }

    /// Cycles through the listening modes the headset supports, for a horizontal
    /// swipe on the mode control.
    func switchToAdjacentMode(forward: Bool) {
        let modes: [ANCMode] = supportsNoiseCancellation ? [.anc, .ambient, .off] : [.ambient, .off]
        guard modes.count > 1,
              let current = currentMode,
              let index = modes.firstIndex(of: current) else { return }
        let step = forward ? 1 : -1
        let next = ((index + step) % modes.count + modes.count) % modes.count
        setMode(modes[next])
    }

    func setAmbientLevel(_ level: Int, applyIfAmbient: Bool = false) {
        ambientLevel = max(1, min(level, 20))
        protocolClient?.setAmbientLevel(ambientLevel, applyIfAmbient: applyIfAmbient)
    }

    func refreshMultipointState() {
        protocolClient?.requestMultipointState()
    }

    /// Pull-to-refresh: re-read everything the headset reports.
    func refreshDeviceState() {
        protocolClient?.refreshNoiseControlState()
        protocolClient?.requestEqualizer()
        protocolClient?.requestBattery()
        protocolClient?.requestMultipointState()
    }

    /// Band values last reported for each preset, so the profile picker can
    /// preview curves. Stored per headset model.
    @Published private(set) var presetCurves: [UInt8: [Int]] = [:]

    private var curveStoreKey: String { "presetCurves.\(displayName)" }

    private func rememberCurve(_ state: EqualizerState) {
        guard !state.bands.isEmpty, presetCurves[state.presetID] != state.bands else { return }
        if presetCurves.isEmpty { loadCurves() }
        presetCurves[state.presetID] = state.bands
        let stored = Dictionary(uniqueKeysWithValues: presetCurves.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(stored, forKey: curveStoreKey)
    }

    func loadCurves() {
        guard let stored = UserDefaults.standard.dictionary(forKey: curveStoreKey) as? [String: [Int]] else { return }
        for (key, bands) in stored {
            if let id = UInt8(key), presetCurves[id] == nil { presetCurves[id] = bands }
        }
    }

    func selectEqualizerPreset(_ preset: EqualizerPreset) {
        guard isReady else { return }
        if var state = equalizer {
            state.presetID = preset.id
            equalizer = state
        }
        protocolClient?.setEqualizerPreset(preset.id)
        // Presets carry their own band values; read them back for the curve.
        protocolClient?.requestEqualizer()
    }

    /// Local band edit while dragging; nothing is sent until `commitEqualizerBands`.
    func previewEqualizerBand(_ index: Int, value: Int) {
        guard var state = equalizer, state.bands.indices.contains(index) else { return }
        state.bands[index] = max(-10, min(10, value))
        if !EqualizerPreset(id: state.presetID, name: "").isCustomSlot { state.presetID = 0xA0 }
        equalizer = state
    }

    func commitEqualizerBands() {
        guard isReady, let state = equalizer else { return }
        let target = EqualizerPreset(id: state.presetID, name: "").isCustomSlot ? state.presetID : 0xA0
        protocolClient?.setEqualizerBands(state.bands, presetID: target)
        rememberCurve(EqualizerState(presetID: target, bands: state.bands))
    }

    /// Applies band values from an imported EQ file and sends them.
    /// `bands` are the five curve bands; `clearBass` is optional.
    /// Returns false if they don't fit this headset's equalizer.
    @discardableResult
    func importEqualizer(bands: [Int], clearBass: Int?) -> Bool {
        guard isReady, let state = equalizer else { return false }
        let curveStart = state.bands.count == 6 ? 1 : 0
        guard bands.count == state.bands.count - curveStart else { return false }
        for (offset, value) in bands.enumerated() { previewEqualizerBand(curveStart + offset, value: value) }
        if curveStart == 1, let clearBass { previewEqualizerBand(0, value: clearBass) }
        commitEqualizerBands()
        return true
    }

    func resetEqualizerBands() {
        guard let state = equalizer else { return }
        for index in state.bands.indices { previewEqualizerBand(index, value: 0) }
        commitEqualizerBands()
    }

    func switchAudioSource(to device: MultipointDevice) {
        // Always send, even to the device marked as playing: the marker can be
        // wrong, and the headset simply keeps playback where it already is.
        guard isReady, device.isConnected, device.address != pendingSourceAddress else { return }
        pendingSourceAddress = device.address
        sourceSwitchFailed = false
        protocolClient?.switchAudioSource(to: device.address)

        // The headset takes a moment to move playback. Re-read the list a few
        // times until it reports the new device, then give up quietly.
        sourceSwitchTask?.cancel()
        let target = device.address
        sourceSwitchTask = Task { @MainActor [weak self] in
            // Checks at about 1.2 s, 2.5 s, 4 s and 6 s after the request.
            for interval in [1.2, 1.3, 1.5, 2.0] {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                if self.activeSourceAddress == target { self.pendingSourceAddress = nil; return }
                self.protocolClient?.requestMultipointState()
            }
            try? await Task.sleep(for: .seconds(1.0))
            guard let self, !Task.isCancelled, self.pendingSourceAddress == target else { return }
            self.pendingSourceAddress = nil
            self.sourceSwitchMessage = "The headphones didn't confirm the switch."
            self.sourceSwitchFailed = self.activeSourceAddress != target
        }
    }

    /// Connected devices are the only switch targets the headphones offer.
    var connectedAudioSources: [MultipointDevice] {
        multipointDevices.filter { $0.isConnected }
    }

    var otherConnectedSource: MultipointDevice? {
        let connected = connectedAudioSources
        guard connected.count >= 2 else { return nil }
        if let activeSourceAddress,
           let other = connected.first(where: { $0.address != activeSourceAddress }) {
            return other
        }
        return connected.first
    }

    /// Cycles to the next/previous connected source, for a horizontal swipe on
    /// the audio-source control.
    func switchToAdjacentSource(forward: Bool) {
        let devices = connectedAudioSources
        guard devices.count > 1 else { return }
        let step = forward ? 1 : -1
        let currentIndex = devices.firstIndex { $0.address == activeSourceAddress }
        let base = currentIndex ?? (forward ? -1 : 0)
        let next = ((base + step) % devices.count + devices.count) % devices.count
        switchAudioSource(to: devices[next])
    }

    func performShortcutMode(_ mode: ANCMode) async throws {
        try await waitUntilReady()
        if mode == .anc, !supportsNoiseCancellation {
            throw ShortcutError.noiseCancellationUnavailable
        }
        currentMode = mode
        protocolClient?.setMode(mode)
    }

    func performShortcutToggle() async throws -> ANCMode {
        try await waitUntilReady()
        guard supportsNoiseCancellation else {
            throw ShortcutError.noiseCancellationUnavailable
        }
        let next: ANCMode = currentMode == .ambient ? .anc : .ambient
        currentMode = next
        protocolClient?.setMode(next)
        return next
    }

    func performShortcutGetStatus() async throws -> (mode: ANCMode, ambientLevel: Int) {
        try await waitUntilReady()
        let revisionBeforeQuery = modeRevision
        protocolClient?.refreshNoiseControlState()
        for _ in 0..<10 {
            if modeRevision > revisionBeforeQuery { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let currentMode else { throw ShortcutError.statusUnavailable }
        return (currentMode, ambientLevel)
    }

    func performShortcutAmbientLevel(_ level: Int) async throws {
        try await waitUntilReady()
        setAmbientLevel(level, applyIfAmbient: true)
    }

    /// Moves playback to the other connected multipoint device, mirroring the
    /// in-app switch button.
    func performShortcutSwitchAudioSource() async throws -> String {
        try await waitUntilReady()
        _ = try await waitForAudioSources()
        guard let other = otherConnectedSource else {
            throw ShortcutError.audioSourceUnavailable
        }
        switchAudioSource(to: other)
        return other.displayName
    }

    func performShortcutGetAudioSource() async throws -> String {
        try await waitUntilReady()
        _ = try await waitForAudioSources()
        guard let activeSourceAddress,
              let active = multipointDevices.first(where: { $0.address == activeSourceAddress }) else {
            throw ShortcutError.audioSourceUnavailable
        }
        return active.displayName
    }

    private func waitForAudioSources() async throws -> [MultipointDevice] {
        let revisionBeforeQuery = multipointRevision
        protocolClient?.requestMultipointState()
        for _ in 0..<15 {
            if multipointRevision > revisionBeforeQuery,
               !multipointDevices.filter({ $0.isConnected }).isEmpty {
                return multipointDevices
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !multipointDevices.filter({ $0.isConnected }).isEmpty else {
            throw ShortcutError.audioSourceUnavailable
        }
        return multipointDevices
    }

    private func waitUntilReady() async throws {
        if !isReady { refreshAccessories() }
        for _ in 0..<50 {
            if isReady { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ShortcutError.headphonesNotReady
    }

    private func open(_ accessory: EAAccessory) {
        if transport?.accessory.connectionID == accessory.connectionID, isConnected { return }
        transport?.close()

        guard let session = EASession(accessory: accessory, forProtocol: HeadsetClient.accessoryProtocol),
              let input = session.inputStream,
              let output = session.outputStream else {
            status = "Could not open the link2 accessory session."
            detail = "iOS may not grant this app access to the accessory protocol."
            isConnected = false
            isReady = false
            currentMode = nil
            return
        }

        let link = ExternalAccessoryTransport(accessory: accessory, session: session)
        let client = HeadsetClient(send: { [weak link] bytes in link?.write(bytes) })
        link.onBytes = { [weak client] bytes in client?.receive(bytes) }
        link.onState = { [weak self, weak client] connected, error in
            Task { @MainActor in
                self?.isConnected = connected
                if let error {
                    self?.status = error
                    self?.isReady = false
                } else if connected {
                    self?.status = "Connected · initializing protocol"
                    self?.reportedModelName = nil
                    client?.start()
                } else {
                    self?.status = "Disconnected"
                    self?.isReady = false
                    self?.currentMode = nil
                    self?.multipointDevices = []
                    self?.activeSourceAddress = nil
                    self?.reportedModelName = nil
                    self?.equalizer = nil
                    self?.battery = BatteryState()
                }
            }
        }
        client.onStatus = { [weak self] text, ready, detail in
            Task { @MainActor in
                self?.status = text
                self?.isReady = ready
                self?.detail = detail
            }
        }
        client.onAmbientLevel = { [weak self] level in
            Task { @MainActor in self?.ambientLevel = level }
        }
        client.onMode = { [weak self] mode in
            Task { @MainActor in
                self?.currentMode = mode
                self?.modeRevision += 1
            }
        }
        client.onNoiseCancellationAvailability = { [weak self] available in
            Task { @MainActor in self?.supportsNoiseCancellation = available }
        }
        client.onModelName = { [weak self] name in
            Task { @MainActor in self?.reportedModelName = name }
        }
        client.onEqualizer = { [weak self] state in
            Task { @MainActor in
                self?.equalizer = state
                self?.rememberCurve(state)
            }
        }
        client.onEqualizerPresets = { [weak self] presets in
            Task { @MainActor in self?.equalizerPresets = presets }
        }
        client.onBattery = { [weak self] battery in
            Task { @MainActor in self?.battery = battery }
        }
        client.onSourceSwitchResult = { [weak self] address, result in
            Task { @MainActor in
                guard let self else { return }
                self.sourceSwitchTask?.cancel()
                self.pendingSourceAddress = nil
                if result == 0 {
                    let match = self.multipointDevices.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
                    self.activeSourceAddress = match?.address ?? address
                    self.sourceSwitchFailed = false
                } else {
                    switch result {
                    case 2: self.sourceSwitchMessage = "Can't switch during a call."
                    case 3: self.sourceSwitchMessage = "That device isn't connected for audio. Start playback on it, then try again."
                    case 4: self.sourceSwitchMessage = "The voice assistant is active. Try again when it's done."
                    default: self.sourceSwitchMessage = "The headphones couldn't switch. Try again."
                    }
                    self.sourceSwitchFailed = true
                }
            }
        }
        client.onMultipoint = { [weak self] devices, activeAddress in
            Task { @MainActor in
                guard let self else { return }
                self.multipointDevices = devices
                self.activeSourceAddress = activeAddress
                self.multipointRevision += 1
                // The list carries the headphones' own view of the active device.
                if let pending = self.pendingSourceAddress, pending == activeAddress {
                    self.pendingSourceAddress = nil
                    self.sourceSwitchFailed = false
                    self.sourceSwitchTask?.cancel()
                }
                if let pending = self.pendingSourceAddress,
                   !devices.contains(where: { $0.address == pending && $0.isConnected }) {
                    self.pendingSourceAddress = nil
                }
            }
        }
        transport = link
        protocolClient = client
        _ = input
        _ = output
        link.open()
    }
}

enum ShortcutError: LocalizedError {
    case headphonesNotReady
    case noiseCancellationUnavailable
    case statusUnavailable
    case audioSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .headphonesNotReady:
            return "Connect compatible headphones and open Sound Control once, then try the shortcut again."
        case .noiseCancellationUnavailable:
            return "These headphones support Ambient Sound and Off, but do not advertise noise cancellation control."
        case .statusUnavailable:
            return "The headphones are connected, but their current listening mode is not available yet."
        case .audioSourceUnavailable:
            return "The headphones did not report a switchable audio source. Connect them to two devices at the same time, then try again."
        }
    }
}
