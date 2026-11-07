import SwiftUI
import MediaPlayer
import Combine
import Network
import ReplayKit

// MARK: - Now playing

/// What is playing on the phone. It first asks the system now-playing service
/// (MediaRemote, which Control Center uses, so it covers Spotify, YouTube and
/// others). That is a private framework and iOS may refuse it for this app,
/// so it falls back to the Music app's player, the only public source.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPlaying = false
    /// Song position at `positionDate`, so the visualizer can follow the song.
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var positionDate = Date()
    /// Track tempo when Music knows it, otherwise a typical 118 BPM.
    @Published private(set) var tempo: Double = 118
    @Published private(set) var seed: UInt64 = 0

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var musicAuthorized = false
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var pollTimer: Timer?
    private var systemInfoAvailable = false
    private var lastArtworkKey: String?

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        // MediaRemote has no public change notification we can rely on, so poll
        // lightly while the app is on screen.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                self?.refresh()
            }
        }

        let begin = { [weak self] in
            guard let self else { return }
            self.musicAuthorized = true
            self.player.beginGeneratingPlaybackNotifications()
            for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                         .MPMusicPlayerControllerPlaybackStateDidChange] {
                self.observers.append(center.addObserver(forName: name, object: self.player, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
            }
            self.refresh()
        }
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            begin()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { status in
                guard status == .authorized else { return }
                Task { @MainActor in begin() }
            }
        default:
            refresh()
        }
    }

    func togglePlayback() {
        if systemInfoAvailable, SystemNowPlaying.togglePlayPause() {
            isPlaying.toggle()
            anchor(position: songTime(at: Date()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
            return
        }
        if player.playbackState == .playing { player.pause() } else { player.play() }
        isPlaying.toggle()
        anchor(position: musicPosition)
    }

    func skip(forward: Bool) {
        if systemInfoAvailable, SystemNowPlaying.skip(forward: forward) { return }
        if forward { player.skipToNextItem() } else { player.skipToPreviousItem() }
    }

    /// The Music app is playing. Its audio is protected and comes through
    /// silent in screen broadcasts, so the live waveform can't show it.
    var isMusicAppPlaying: Bool {
        !systemInfoAvailable ? player.playbackState == .playing : (player.playbackState == .playing && isPlaying)
    }

    /// Current song position, extrapolated while playing.
    func songTime(at date: Date) -> TimeInterval {
        isPlaying ? position + date.timeIntervalSince(positionDate) : position
    }

    private func refresh() {
        SystemNowPlaying.fetch { [weak self] info in
            Task { @MainActor in self?.apply(info) }
        }
    }

    private func apply(_ info: SystemNowPlaying.Info?) {
        if let info, info.title != nil {
            systemInfoAvailable = true
            let changed = info.title != title || info.artist != artist
            title = info.title
            artist = info.artist
            let artworkKey = "\(info.title ?? "")|\(info.artist ?? "")|\(info.artworkData?.count ?? 0)"
            if artworkKey != lastArtworkKey {
                lastArtworkKey = artworkKey
                artwork = info.artworkData.flatMap(UIImage.init(data:))
            }
            if changed {
                seed = UInt64(truncatingIfNeeded: (info.title ?? "").hashValue)
                tempo = 118
            }
            let wasPlaying = isPlaying
            isPlaying = info.isPlaying
            if let elapsed = info.elapsed {
                // Only re-anchor on real jumps, so the animation stays smooth.
                let drift = abs(songTime(at: info.timestamp) - elapsed)
                if changed || wasPlaying != isPlaying || drift > 1.0 {
                    position = elapsed
                    positionDate = info.timestamp
                }
            } else if changed || wasPlaying != isPlaying {
                anchor(position: songTime(at: Date()))
            }
            return
        }
        systemInfoAvailable = false
        guard musicAuthorized else {
            title = nil; artist = nil; artwork = nil; isPlaying = false
            return
        }
        let item = player.nowPlayingItem
        title = item?.title
        artist = item?.artist
        artwork = item?.artwork?.image(at: CGSize(width: 160, height: 160))
        let bpm = item?.beatsPerMinute ?? 0
        tempo = (60...200).contains(bpm) ? Double(bpm) : 118
        seed = item?.persistentID ?? 0
        let playing = player.playbackState == .playing
        if playing != isPlaying || abs(songTime(at: Date()) - musicPosition) > 1.0 {
            anchor(position: musicPosition)
        }
        isPlaying = playing
    }

    private var musicPosition: TimeInterval {
        let current = player.currentPlaybackTime
        return current.isFinite ? current : 0
    }

    private func anchor(position: TimeInterval) {
        self.position = position
        positionDate = Date()
    }
}

/// Best-effort bridge to the private MediaRemote framework. Every symbol is
/// looked up at runtime; if any is missing or iOS returns nothing, callers
/// fall back to public APIs.
enum SystemNowPlaying {
    struct Info {
        var title: String?
        var artist: String?
        var artworkData: Data?
        var isPlaying: Bool
        var elapsed: TimeInterval?
        var timestamp: Date
    }

    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    private static let getInfo: GetInfo? = {
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(symbol, to: GetInfo.self)
    }()

    private static let sendCommand: SendCommand? = {
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    static func fetch(_ completion: @escaping (Info?) -> Void) {
        guard let getInfo else { completion(nil); return }
        getInfo(DispatchQueue.main) { dictionary in
            guard let values = dictionary as? [String: Any], !values.isEmpty else { completion(nil); return }
            let rate = (values["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            completion(Info(
                title: values["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
                artist: values["kMRMediaRemoteNowPlayingInfoArtist"] as? String,
                artworkData: values["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                isPlaying: rate > 0,
                elapsed: (values["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue,
                timestamp: values["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
            ))
        }
    }

    /// MediaRemote command IDs: 2 = toggle play/pause, 4 = next, 5 = previous.
    static func togglePlayPause() -> Bool { sendCommand?(2, nil) ?? false }
    static func skip(forward: Bool) -> Bool { sendCommand?(forward ? 4 : 5, nil) ?? false }
}

// MARK: - EQ curve

/// Layout shared by the bars and the curve. The five EQ bands (400 Hz, 1 kHz,
/// 2.5 kHz, 6.3 kHz, 16 kHz) are evenly spaced on a log axis, so each band
/// owns an equal column and its handle sits in the column's center.
struct EqualizerCurve {
    /// Curve bands only (Clear Bass is excluded).
    let bands: [Int]
    let clearBass: Int

    init(reported: [Int]) {
        if reported.count == 6 {
            clearBass = reported[0]
            bands = Array(reported.dropFirst())
        } else {
            clearBass = 0
            bands = reported
        }
    }

    /// Horizontal position (0...1) of band `index`'s handle.
    func position(of index: Int) -> Double {
        (Double(index) + 0.5) / Double(max(1, bands.count))
    }

    /// Gain in steps (-10...+10) at horizontal position `x` (0...1). Flat
    /// beyond the outer handles, smooth between neighbours.
    func gain(at x: Double) -> Double {
        guard !bands.isEmpty else { return 0 }
        let first = position(of: 0), last = position(of: bands.count - 1)
        if x <= first { return Double(bands[0]) }
        if x >= last { return Double(bands[bands.count - 1]) }
        let step = 1 / Double(bands.count)
        let i = min(bands.count - 2, Int((x - first) / step))
        let t = (x - position(of: i)) / step
        let smooth = t * t * (3 - 2 * t)
        return Double(bands[i]) + Double(bands[i + 1] - bands[i]) * smooth
    }

    /// Gain the bars use: the curve plus Clear Bass on the lowest frequencies.
    func barGain(at x: Double) -> Double {
        let bassWeight = max(0, 1 - x / 0.09) // below ~300 Hz on the shared axis
        return gain(at: x) + Double(clearBass) * bassWeight * bassWeight
    }
}

// MARK: - Visualizer

/// EQ curve with draggable points over a live waveform. Bars appear only while
/// real levels arrive from the broadcast extension; otherwise the plot shows
/// just the curve. Styled after Apple's AirPods equalizer; the line's color
/// depends on its value: blue at 0, then cyan, green, yellow, orange and red
/// toward +10, and darker blue toward -10.
struct EqualizerVisualizer: View {
    let bands: [Int]
    /// Real levels from the broadcast extension; used whenever they are fresh.
    var live: LiveSpectrumReceiver? = nil
    var isLive = false
    var editable = false
    var onChange: (Int, Int) -> Void = { _, _ in }
    var onCommit: () -> Void = {}

    private let barCount = LiveSpectrum.barCount
    private let plotInset: CGFloat = 18
    /// How close (points) a touch must start to a point to grab it.
    private let grabRadius: CGFloat = 34

    /// Band being dragged (curve index) and its value when the drag began.
    @State private var drag: (index: Int, startValue: Int)?
    /// Set when a touch started away from every point; the whole gesture is ignored.
    @State private var dragMissed = false
    @State private var canvasSize: CGSize = .zero

    /// Symmetric fade by height: blue at 0, red at +10 (top) and -10 (bottom).
    static let gainGradient = Gradient(stops: [
        .init(color: Color(red: 1.00, green: 0.27, blue: 0.23), location: 0.00),
        .init(color: Color(red: 1.00, green: 0.62, blue: 0.10), location: 0.08),
        .init(color: Color(red: 0.98, green: 0.86, blue: 0.24), location: 0.18),
        .init(color: Color(red: 0.30, green: 0.88, blue: 0.52), location: 0.30),
        .init(color: Color(red: 0.16, green: 0.82, blue: 0.92), location: 0.40),
        .init(color: Color(red: 0.10, green: 0.52, blue: 1.00), location: 0.50),
        .init(color: Color(red: 0.12, green: 0.36, blue: 0.86), location: 0.75),
        .init(color: Color(red: 0.14, green: 0.24, blue: 0.70), location: 1.00),
    ])

    /// Waveform bars, as in Apple's equalizer: blue in the middle, then cyan,
    /// green and yellow toward the tips, with red at the very top and bottom.
    static let barGradient = Gradient(stops: [
        .init(color: Color(red: 1.00, green: 0.27, blue: 0.23), location: 0.00),
        .init(color: Color(red: 0.98, green: 0.86, blue: 0.24), location: 0.07),
        .init(color: Color(red: 0.30, green: 0.88, blue: 0.52), location: 0.16),
        .init(color: Color(red: 0.16, green: 0.82, blue: 0.92), location: 0.28),
        .init(color: Color(red: 0.10, green: 0.56, blue: 1.00), location: 0.42),
        .init(color: Color(red: 0.10, green: 0.56, blue: 1.00), location: 0.58),
        .init(color: Color(red: 0.16, green: 0.82, blue: 0.92), location: 0.72),
        .init(color: Color(red: 0.30, green: 0.88, blue: 0.52), location: 0.84),
        .init(color: Color(red: 0.98, green: 0.86, blue: 0.24), location: 0.93),
        .init(color: Color(red: 1.00, green: 0.27, blue: 0.23), location: 1.00),
    ])

    /// The same scale as a single color for a value (-10...+10).
    static func color(for value: Int) -> Color {
        if value < 0 {
            // Below 0: blue darkening toward -10.
            let f = min(1, Double(-value) / 10)
            return Color(red: 0.10 + 0.04 * f, green: 0.52 - 0.28 * f, blue: 1.00 - 0.30 * f)
        }
        let t = min(1, Double(value) / 10)
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (0.10, 0.52, 1.00)), (0.2, (0.16, 0.82, 0.92)), (0.4, (0.30, 0.88, 0.52)),
            (0.64, (0.98, 0.86, 0.24)), (0.84, (1.00, 0.62, 0.10)), (1.0, (1.00, 0.27, 0.23)),
        ]
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            let f = (t - t0) / (t1 - t0)
            return Color(red: c0.0 + (c1.0 - c0.0) * f, green: c0.1 + (c1.1 - c0.1) * f, blue: c0.2 + (c1.2 - c0.2) * f)
        }
        return Color(red: 1.00, green: 0.27, blue: 0.23)
    }

    private var curve: EqualizerCurve { EqualizerCurve(reported: bands) }

    var body: some View {
        VStack(spacing: 8) {
            if !curve.bands.isEmpty {
                valueRow
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isLive)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, now: timeline.date)
                }
            }
            .frame(height: 220)
            .contentShape(Rectangle())
            .gesture(dragGesture, including: editable && !curve.bands.isEmpty ? .all : .subviews)

            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(drag?.index == index ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer")
        .accessibilityValue(curve.bands.map(Self.signed).joined(separator: ", "))
    }

    /// Current value of each band, above its column.
    private var valueRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(curve.bands.enumerated()), id: \.offset) { index, value in
                Text(Self.signed(value))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Self.color(for: value))
                    .scaleEffect(drag?.index == index ? 1.2 : 1)
                    .animation(.snappy(duration: 0.15), value: drag?.index == index)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
            }
        }
    }

    static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    private var labels: [String] {
        switch curve.bands.count {
        case 0: return ["LOW", "MID", "HIGH"]
        case 5: return ["400", "1k", "2.5k", "6.3k", "16k"]
        default: return (1...curve.bands.count).map { "\($0)" }
        }
    }

    // MARK: Interaction

    /// A point moves only when the drag starts on or near it, and it moves by
    /// the finger's travel. Taps and drags that start elsewhere change nothing.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { gesture in
                if dragMissed { return }
                if drag == nil {
                    guard let index = handle(near: gesture.startLocation) else { dragMissed = true; return }
                    drag = (index, curve.bands[index])
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                guard let drag else { return }
                let step = max(1, (canvasSize.height - plotInset * 2) / 20)
                let value = max(-10, min(10, drag.startValue + Int((-gesture.translation.height / step).rounded())))
                let bandIndex = bands.count == 6 ? drag.index + 1 : drag.index
                if bands.indices.contains(bandIndex), bands[bandIndex] != value {
                    UISelectionFeedbackGenerator().selectionChanged()
                    onChange(bandIndex, value)
                }
            }
            .onEnded { _ in
                let changed = drag != nil
                drag = nil
                dragMissed = false
                if changed { onCommit() }
            }
    }

    private func handle(near location: CGPoint) -> Int? {
        let size = canvasSize
        var best: (index: Int, distance: CGFloat)?
        for i in curve.bands.indices {
            let center = CGPoint(x: size.width * curve.position(of: i), y: yForGain(Double(curve.bands[i]), size: size))
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= grabRadius, distance < (best?.distance ?? .infinity) { best = (i, distance) }
        }
        return best?.index
    }

    private func yForGain(_ gain: Double, size: CGSize) -> CGFloat {
        let top = plotInset, bottom = size.height - plotInset
        return bottom - (bottom - top) * CGFloat((gain + 10) / 20)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        if canvasSize != size {
            DispatchQueue.main.async { canvasSize = size }
        }
        let curve = self.curve
        let mid = size.height / 2
        let columns = max(1, curve.bands.count)
        let column = size.width / CGFloat(columns)
        let shading = GraphicsContext.Shading.linearGradient(
            Self.gainGradient, startPoint: CGPoint(x: 0, y: plotInset), endPoint: CGPoint(x: 0, y: size.height - plotInset)
        )

        // Active column highlight while dragging.
        if let drag {
            context.fill(
                Path(CGRect(x: column * CGFloat(drag.index), y: 0, width: column, height: size.height)),
                with: .linearGradient(
                    Gradient(colors: [.clear, .white.opacity(0.08), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        // Dashed guide at each point.
        let guideCount = curve.bands.isEmpty ? 3 : columns
        for i in 0..<guideCount {
            let x = size.width * (CGFloat(i) + 0.5) / CGFloat(guideCount)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }

        // Live bars only; nothing when no live sound is arriving.
        if let levels = live?.snapshot(at: now) {
            let slot = size.width / CGFloat(barCount)
            let barWidth = max(1.5, slot * 0.5)
            let barShading = GraphicsContext.Shading.linearGradient(
                Self.barGradient, startPoint: CGPoint(x: 0, y: plotInset), endPoint: CGPoint(x: 0, y: size.height - plotInset)
            )
            let maxHeight = size.height - plotInset * 2
            for i in 0..<barCount where levels.indices.contains(i) {
                let x = (Double(i) + 0.5) / Double(barCount)
                let gain = pow(10, curve.barGain(at: x) * 0.045)
                let height = min(maxHeight, max(barWidth, maxHeight * Double(levels[i]) * gain))
                let rect = CGRect(x: slot * CGFloat(i) + (slot - barWidth) / 2, y: mid - height / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: barShading)
            }
        }

        // EQ curve with points.
        guard !curve.bands.isEmpty else { return }
        var path = Path()
        for s in 0...120 {
            let x = Double(s) / 120
            let point = CGPoint(x: size.width * x, y: yForGain(curve.gain(at: x), size: size))
            if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        for i in curve.bands.indices {
            let center = CGPoint(x: size.width * curve.position(of: i), y: yForGain(Double(curve.bands[i]), size: size))
            let radius: CGFloat = drag?.index == i ? 12 : 9
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(Self.color(for: curve.bands[i])))
            context.stroke(circle, with: .color(.black.opacity(0.6)), lineWidth: 2)
        }
    }
}

// MARK: - Live spectrum (broadcast extension)

/// Receives bar levels from the LiveAudio broadcast extension over loopback
/// UDP. The canvas reads `snapshot()` each frame; only the coarse live/silent
/// flags are published so SwiftUI does not re-render at the packet rate.
final class LiveSpectrumReceiver: ObservableObject {
    static let shared = LiveSpectrumReceiver()

    /// Packets are arriving.
    @Published private(set) var isLive = false
    /// Packets are arriving but carry no sound (for example protected audio).
    @Published private(set) var isSilent = false

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: LiveSpectrum.barCount)
    private var lastPacket = Date.distantPast
    private var lastSound = Date.distantPast
    private var listener: NWListener?
    private var statusTimer: Timer?
    private let queue = DispatchQueue(label: "LiveSpectrumReceiver")

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: LiveSpectrum.port) else { return }
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(on: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.listener?.cancel()
                self?.listener = nil
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    /// Smoothed levels (0...1), or nil when no packet arrived recently.
    func snapshot(at date: Date = Date()) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard date.timeIntervalSince(lastPacket) < 0.5 else { return nil }
        return levels
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let incoming = LiveSpectrum.decode(data), incoming.count == LiveSpectrum.barCount {
                self.apply(incoming)
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func apply(_ incoming: [Float]) {
        let now = Date()
        lock.lock()
        // Meter ballistics: rise fast, fall back gradually.
        for i in levels.indices {
            let target = incoming[i]
            levels[i] = target > levels[i] ? levels[i] + (target - levels[i]) * 0.7 : max(target, levels[i] * 0.86)
        }
        lastPacket = now
        if incoming.contains(where: { $0 > 0.02 }) { lastSound = now }
        lock.unlock()
    }

    private func updateStatus() {
        lock.lock()
        let now = Date()
        let live = now.timeIntervalSince(lastPacket) < 0.5
        let silent = live && now.timeIntervalSince(lastSound) > 2.5
        lock.unlock()
        if live != isLive { isLive = live }
        if silent != isSilent { isSilent = silent }
    }
}

/// Hidden system broadcast picker, opened by `BroadcastPicker.open()`.
/// The picker is the only API that can start a broadcast for our extension.
@MainActor
final class BroadcastPicker: ObservableObject {
    fileprivate weak var view: RPSystemBroadcastPickerView?
    /// True when the app bundle has no broadcast extension (for example a
    /// signing tool dropped it), so the sheet would only offer Screen Recording.
    @Published private(set) var extensionMissing = false

    /// Bundle ID of the embedded LiveAudio extension, read from the app bundle
    /// rather than hard-coded, since signing tools may rewrite bundle IDs.
    static let extensionID: String? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload" else { continue }
            return bundle.bundleIdentifier
        }
        return nil
    }()

    func open() {
        // Without an extension the sheet could only offer Screen Recording.
        guard let id = Self.extensionID else {
            extensionMissing = true
            return
        }
        extensionMissing = false
        view?.preferredExtension = id
        guard let button = view?.subviews.compactMap({ $0 as? UIButton }).first else { return }
        button.sendActions(for: .touchUpInside)
    }
}

struct BroadcastPickerHost: UIViewRepresentable {
    let picker: BroadcastPicker

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Limits the sheet to our streaming extension, so Screen Recording
        // (which saves a video) is not offered.
        view.preferredExtension = BroadcastPicker.extensionID
        view.showsMicrophoneButton = false
        view.alpha = 0.011
        picker.view = view
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        picker.view = uiView
    }
}
