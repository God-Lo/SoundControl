import SwiftUI
import MediaPlayer
import Combine
import Network
import ReplayKit
import MachO

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

/// Mirrored bar visualizer with the EQ curve drawn on top. Drag a handle up or
/// down to change that band. Bars move while music plays and settle flat when
/// it stops. iOS does not give apps the audio of other apps, so the bars are a
/// typical music spectrum shaped by the EQ, not a measurement.
struct EqualizerVisualizer: View {
    let bands: [Int]
    let isPlaying: Bool
    /// Song position for a given time; the bars are a function of it, so they
    /// stay consistent across pauses and follow seeks.
    var songTime: (Date) -> TimeInterval = { $0.timeIntervalSinceReferenceDate }
    var tempo: Double = 118
    var seed: UInt64 = 0
    /// Real levels from the broadcast extension; used whenever they are fresh.
    var live: LiveSpectrumReceiver? = nil
    var isLive = false
    var editable = false
    var onChange: (Int, Int) -> Void = { _, _ in }
    var onCommit: () -> Void = {}

    private let barCount = LiveSpectrum.barCount
    private let plotInset: CGFloat = 18

    @State private var transitionStart = Date.distantPast
    @State private var animating = false
    @State private var dragIndex: Int?

    private static let barGradient = Gradient(stops: [
        .init(color: .yellow, location: 0.0),
        .init(color: .green, location: 0.12),
        .init(color: .cyan, location: 0.24),
        .init(color: .blue, location: 0.38),
        .init(color: .blue, location: 0.62),
        .init(color: .cyan, location: 0.76),
        .init(color: .green, location: 0.88),
        .init(color: .yellow, location: 1.0),
    ])

    /// Curve color by height: cyan at the bottom, mint around flat, yellow at the top.
    private static let curveGradient = Gradient(stops: [
        .init(color: Color(red: 0.98, green: 0.92, blue: 0.35), location: 0.0),
        .init(color: Color(red: 0.85, green: 0.95, blue: 0.45), location: 0.3),
        .init(color: Color(red: 0.45, green: 0.95, blue: 0.75), location: 0.5),
        .init(color: .cyan, location: 0.75),
        .init(color: .cyan, location: 1.0),
    ])

    private var curve: EqualizerCurve { EqualizerCurve(reported: bands) }

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying && !animating && !isLive)) { timeline in
                let t = songTime(timeline.date)
                Canvas { context, size in
                    draw(in: &context, size: size, time: t, now: timeline.date)
                }
            }
            .frame(height: 230)
            .contentShape(Rectangle())
            .gesture(dragGesture, including: editable && !curve.bands.isEmpty ? .all : .subviews)

            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(dragIndex == index ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            let start = Date()
            transitionStart = start
            animating = true
            if !playing {
                // Keep drawing until the bars have settled flat, then stop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if transitionStart == start { animating = false }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer")
        .accessibilityValue(curve.bands.map { $0 > 0 ? "+\($0)" : "\($0)" }.joined(separator: ", "))
    }

    private var labels: [String] {
        switch curve.bands.count {
        case 0: return ["LOW", "MID", "HIGH"]
        case 5: return ["400", "1k", "2.5k", "6.3k", "16k"]
        default: return (1...curve.bands.count).map { "\($0)" }
        }
    }

    // MARK: Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let count = curve.bands.count
                // Lock onto the column where the finger first landed.
                let index = dragIndex ?? min(count - 1, max(0, Int(drag.startLocation.x / max(1, columnWidth))))
                if dragIndex == nil { dragIndex = index }
                let value = valueForY(drag.location.y)
                let bandIndex = bands.count == 6 ? index + 1 : index
                if bands.indices.contains(bandIndex), bands[bandIndex] != value {
                    UISelectionFeedbackGenerator().selectionChanged()
                    onChange(bandIndex, value)
                }
            }
            .onEnded { _ in
                dragIndex = nil
                onCommit()
            }
    }

    @State private var canvasSize: CGSize = .zero
    private var columnWidth: CGFloat { canvasSize.width / CGFloat(max(1, curve.bands.count)) }

    private func valueForY(_ y: CGFloat) -> Int {
        let top = plotInset, bottom = canvasSize.height - plotInset
        guard bottom > top else { return 0 }
        let fraction = 1 - max(0, min(1, (y - top) / (bottom - top)))
        return Int((fraction * 20).rounded()) - 10
    }

    private func yForGain(_ gain: Double, size: CGSize) -> CGFloat {
        let top = plotInset, bottom = size.height - plotInset
        return bottom - (bottom - top) * CGFloat((gain + 10) / 20)
    }

    // MARK: Drawing

    /// 0 when paused (flat), 1 while playing, eased in between.
    private func energy(now: Date) -> Double {
        let elapsed = now.timeIntervalSince(transitionStart)
        let t = max(0, min(1, elapsed / 0.45))
        let eased = t * t * (3 - 2 * t)
        return isPlaying ? eased : 1 - eased
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double, now: Date) {
        if canvasSize != size {
            DispatchQueue.main.async { canvasSize = size }
        }
        let curve = self.curve
        let mid = size.height / 2
        let columns = max(1, curve.bands.count)
        let column = size.width / CGFloat(columns)

        // Active column highlight while dragging.
        if let dragIndex {
            context.fill(
                Path(CGRect(x: column * CGFloat(dragIndex), y: 0, width: column, height: size.height)),
                with: .linearGradient(
                    Gradient(colors: [.clear, .white.opacity(0.08), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        // Dashed guide at each handle.
        let guideCount = curve.bands.isEmpty ? 3 : columns
        for i in 0..<guideCount {
            let x = size.width * (CGFloat(i) + 0.5) / CGFloat(guideCount)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }

        // Bars.
        let energy = energy(now: now)
        let slot = size.width / CGFloat(barCount)
        let barWidth = max(2, slot * 0.55)
        let barShading = GraphicsContext.Shading.linearGradient(
            Self.barGradient, startPoint: CGPoint(x: 0, y: plotInset), endPoint: CGPoint(x: 0, y: size.height - plotInset)
        )
        let maxHeight = size.height - plotInset * 2
        let model = SpectrumModel(tempo: tempo, seed: seed)
        let liveLevels = live?.snapshot(at: now)
        for i in 0..<barCount {
            let x = (Double(i) + 0.5) / Double(barCount)
            var height = barWidth
            if let liveLevels, liveLevels.indices.contains(i) {
                let gain = pow(10, curve.barGain(at: x) * 0.045)
                let target = maxHeight * Double(liveLevels[i]) * gain
                height = min(maxHeight, max(barWidth, target))
            } else if energy > 0 {
                let level = model.level(bar: i, x: x, time: time)
                let gain = pow(10, curve.barGain(at: x) * 0.045) // ≈0.35× at -10, ≈2.8× at +10
                let target = maxHeight * level * gain
                height = barWidth + (min(maxHeight, max(barWidth, target)) - barWidth) * energy
            }
            let rect = CGRect(x: slot * CGFloat(i) + (slot - barWidth) / 2, y: mid - height / 2, width: barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: barShading)
        }

        // EQ curve with handles.
        guard !curve.bands.isEmpty else { return }
        var path = Path()
        let samples = 120
        for s in 0...samples {
            let x = Double(s) / Double(samples)
            let point = CGPoint(x: size.width * x, y: yForGain(curve.gain(at: x), size: size))
            if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let curveShading = GraphicsContext.Shading.linearGradient(
            Self.curveGradient, startPoint: CGPoint(x: 0, y: plotInset), endPoint: CGPoint(x: 0, y: size.height - plotInset)
        )
        context.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: curveShading, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

        for i in curve.bands.indices {
            let center = CGPoint(x: size.width * curve.position(of: i), y: yForGain(Double(curve.bands[i]), size: size))
            let radius: CGFloat = dragIndex == i ? 14 : 11
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(circle, with: curveShading)
            context.stroke(circle, with: .color(.black.opacity(0.55)), lineWidth: 3)
            if dragIndex == i {
                let value = curve.bands[i]
                let text = Text(value > 0 ? "+\(value)" : "\(value)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                let above = center.y - radius - 12 > 8
                context.draw(text, at: CGPoint(x: center.x, y: above ? center.y - radius - 12 : center.y + radius + 12))
            }
        }
    }
}

// MARK: - Spectrum model

/// A stand-in for an FFT of the playing song, built to move like one: smooth
/// noise that is correlated between neighbouring bars and over time, kick
/// drums on the beat in the lows, snare on beats 2 and 4 in the mids, hi-hats
/// on eighth notes in the highs, and slow loudness swells between sections.
/// It is driven by the song position and tempo, and seeded per song.
struct SpectrumModel {
    let tempo: Double
    let seed: UInt64

    /// Bar height as a fraction of the plot (roughly 0...1) before EQ gain.
    func level(bar i: Int, x: Double, time t: Double) -> Double {
        let s = Double(seed % 997)
        let beats = t * tempo / 60
        let beat = beats.rounded(.down)
        let phase = beats - beat
        let eighthPhase = beats * 2 - (beats * 2).rounded(.down)

        // Average spectrum: strong lows, a vocal/instrument hump, soft highs.
        let tilt = 0.16 + 0.22 * exp(-x * 3) + 0.4 * exp(-pow((x - 0.07) / 0.09, 2)) + 0.12 * exp(-pow((x - 0.45) / 0.18, 2))

        // Section dynamics (verse/chorus) and phrase-level movement.
        let section = 0.7 + 0.3 * Self.fbm(t * 0.07 + s, 11.3, octaves: 2)

        // Harmonic content: wide, slowly drifting shapes across the bars.
        let tonal = Self.fbm(Double(i) * 0.16 + s, t * 1.8, octaves: 3)
        // Fine grain: bar-to-bar detail that flickers like FFT bins.
        let grain = Self.noise(Double(i) * 0.9 + s * 3, t * 11)

        // Drums, with slight randomness in how hard each hit lands.
        let hit = 0.75 + 0.25 * Self.hash(Int(beat), Int(seed & 0xFFFF))
        let kick = exp(-phase * 7) * exp(-pow((x - 0.06) / 0.08, 2)) * hit
        let snare = (Int(beat) % 2 == 1 ? exp(-phase * 9) : 0) * exp(-pow((x - 0.55) / 0.25, 2)) * hit
        let hat = exp(-eighthPhase * 16) * max(0, (x - 0.55) / 0.45)

        var value = tilt * section * (0.2 + 1.1 * tonal) * (0.5 + 0.7 * grain)
        value += 0.38 * kick + 0.16 * snare + 0.12 * hat * (0.5 + 0.5 * grain)
        return value * 1.25
    }

    // Integer hash to 0...1.
    static func hash(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(bitPattern: Int64(a)) &* 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(b)) &* 0xC2B2AE3D27D4EB4F
        h ^= h >> 29; h &*= 0xBF58476D1CE4E5B9; h ^= h >> 32
        return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
    }

    /// Smooth 2D value noise, 0...1.
    static func noise(_ x: Double, _ y: Double) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let xf = x - Double(xi), yf = y - Double(yi)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi), b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
    }

    /// Layered noise, 0...1.
    static func fbm(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var total = 0.0, amplitude = 1.0, frequency = 1.0, norm = 0.0
        for _ in 0..<octaves {
            total += noise(x * frequency, y * frequency) * amplitude
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2.1
        }
        return total / norm
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

    /// Bundle ID of the embedded LiveAudio extension, read from the installed
    /// app rather than hard-coded: sideloading tools often rewrite bundle IDs,
    /// and a stale ID makes iOS fall back to its own Screen Recording.
    static let extensionID: String? = {
        for plugins in pluginFolders {
            guard let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { continue }
            for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "appex" {
                guard let bundle = Bundle(url: url),
                      let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                      info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload" else { continue }
                return bundle.bundleIdentifier
            }
        }
        return nil
    }()

    /// iOS registers app extensions only for apps it installed itself (under
    /// /Containers/Bundle/Application/). Installed normally, that is this app.
    /// Run inside LiveContainer, it is the LiveContainer host, whose own
    /// broadcast extension is then used. Anything else would make the picker
    /// fall back to Screen Recording.
    private static var pluginFolders: [URL] {
        var folders: [URL] = []
        if isNativelyInstalled, let own = Bundle.main.builtInPlugInsURL { folders.append(own) }
        if let host = hostAppURL { folders.append(host.appendingPathComponent("PlugIns")) }
        return folders
    }

    /// The installed app whose executable is running this process, when that
    /// is not this app (LiveContainer and similar hosts).
    private static var hostAppURL: URL? {
        guard let image = _dyld_get_image_name(0) else { return nil }
        let app = URL(fileURLWithPath: String(cString: image)).resolvingSymlinksInPath().deletingLastPathComponent()
        guard app.pathExtension == "app",
              app.path.contains("/Containers/Bundle/Application/"),
              app.standardizedFileURL != Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        return app
    }

    static let isNativelyInstalled = Bundle.main.bundlePath.contains("/Containers/Bundle/Application/")

    func open() {
        let id = Self.extensionID
        // Installed normally without an extension, the sheet could only offer
        // Screen Recording, so explain instead. Inside LiveContainer, its own
        // extension ("LiveContainer" in the sheet) loads ours; if its ID could
        // not be read, show the full list so the user can pick it.
        if id == nil && Self.isNativelyInstalled {
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
