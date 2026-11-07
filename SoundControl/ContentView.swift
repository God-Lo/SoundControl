import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: ANCController
    @StateObject private var nowPlaying = NowPlayingModel()
    @ObservedObject private var liveSpectrum = LiveSpectrumReceiver.shared
    @StateObject private var broadcastPicker = BroadcastPicker()
    @State private var showingProfiles = false
    @State private var showingMusicWarning = false
    @State private var exportingEQ = false
    @State private var namingExport = false
    @State private var exportName = ""
    @State private var importingEQ = false
    @State private var eqFileMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if controller.isConnected {
                        headerCard
                        noiseControlCard
                        if connectedDevices.count >= 2 {
                            audioSourceCard
                        }
                        equalizerCard
                    } else {
                        disconnectedCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .animation(.snappy(duration: 0.25), value: controller.isConnected)
                .animation(.snappy(duration: 0.25), value: connectedDevices.count)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Sound Control")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        feedback()
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .refreshable { refresh() }
            .sheet(isPresented: $showingProfiles) {
                ProfilePickerSheet(controller: controller)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // Kept apart from the exporter: two file pickers on one view
            // don't reliably present.
            .fileImporter(isPresented: $importingEQ, allowedContentTypes: [.json, .data, .plainText]) { result in
                importEQ(result)
            }
            .alert("Equalizer", isPresented: Binding(get: { eqFileMessage != nil }, set: { if !$0 { eqFileMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(eqFileMessage ?? "")
            }
        }
        .onAppear {
            controller.loadCurves()
            nowPlaying.start()
            liveSpectrum.start()
        }
    }

    private func refresh() {
        if controller.isConnected {
            controller.refreshDeviceState()
        } else {
            controller.refreshAccessories()
        }
    }

    // MARK: Disconnected

    private var disconnectedCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color(.tertiarySystemFill)).frame(width: 96, height: 96)
                Image(systemName: "headphones")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                Text("No headphones connected")
                    .font(.title3.weight(.bold))
                Text("Connect your headphones in Bluetooth settings, then refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                feedback()
                controller.refreshAccessories()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(card)
        .padding(.top, 24)
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue.opacity(0.45), .cyan.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 60, height: 60)
                    Image(systemName: headerSymbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.displayName)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(controller.isReady ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(controller.isReady ? "Connected" : controller.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            if !batteryItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(batteryItems, id: \.label) { item in
                        BatteryGauge(label: item.label, symbol: item.symbol, level: item.level, charging: item.charging)
                    }
                }
            }
        }
        .padding(16)
        .background(card)
    }

    private struct BatteryItem {
        let label: String
        let symbol: String
        let level: Int
        let charging: Bool
    }

    /// Left/Right/Case for earbuds; a single level only when no per-bud levels exist.
    private var batteryItems: [BatteryItem] {
        let battery = controller.battery
        var items: [BatteryItem] = []
        if let left = battery.left {
            items.append(BatteryItem(label: "Left", symbol: "l.circle.fill", level: left, charging: battery.leftCharging))
        }
        if let right = battery.right {
            items.append(BatteryItem(label: "Right", symbol: "r.circle.fill", level: right, charging: battery.rightCharging))
        }
        if items.isEmpty, let single = battery.single {
            items.append(BatteryItem(label: "Battery", symbol: headerSymbol, level: single, charging: battery.singleCharging))
        }
        if let caseLevel = battery.caseLevel {
            items.append(BatteryItem(label: "Case", symbol: "earbuds.case.fill", level: caseLevel, charging: battery.caseCharging))
        }
        return items
    }

    private var headerSymbol: String {
        let name = controller.displayName.uppercased()
        if name.contains("WF-") || name.contains("LINKBUDS") { return "earbuds" }
        return "headphones"
    }

    // MARK: Noise control

    private var noiseControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                "Noise Control",
                symbol: "waveform",
                switchAction: controller.supportsNoiseCancellation ? { controller.toggleANCAndAmbient() } : nil,
                switchLabel: "Switch between ANC and Ambient"
            )
            HStack(spacing: 4) {
                if controller.supportsNoiseCancellation {
                    modeSegment(.anc, title: "Noise Cancelling", short: "ANC", symbol: "person.wave.2.fill")
                }
                modeSegment(.ambient, title: "Ambient", short: "Ambient", symbol: "ear.fill")
                modeSegment(.off, title: "Off", short: "Off", symbol: "circle.slash")
            }
            .padding(4)
            .background(segmentBackground)
            .disabled(!controller.isReady)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { value in
                    guard controller.isReady, abs(value.translation.width) > 40 else { return }
                    feedback()
                    controller.switchToAdjacentMode(forward: value.translation.width < 0)
                }
            )

            let ambientActive = controller.currentMode == .ambient
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ambient level")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(controller.ambientLevel)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(ambientActive ? Color.teal : Color.secondary)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.1.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(controller.ambientLevel) },
                            set: { controller.setAmbientLevel(Int($0.rounded())) }
                        ),
                        in: 1...20,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing { controller.setAmbientLevel(controller.ambientLevel, applyIfAmbient: true) }
                        }
                    )
                    .tint(.teal)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!controller.isReady)
                if !ambientActive {
                    Text("Applied when Ambient is on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(card)
    }

    // MARK: Audio source

    private var audioSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Audio Source",
                symbol: "dot.radiowaves.left.and.right",
                switchAction: { controller.switchToAdjacentSource(forward: true) },
                switchLabel: "Switch audio source"
            )
            VStack(spacing: 8) {
                ForEach(connectedDevices) { device in
                    sourceRow(device)
                }
            }
            .disabled(!controller.isReady)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { value in
                    guard controller.isReady, abs(value.translation.width) > 40,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    feedback()
                    controller.switchToAdjacentSource(forward: value.translation.width < 0)
                }
            )
            if controller.sourceSwitchFailed {
                Label(controller.sourceSwitchMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .background(card)
        .animation(.snappy(duration: 0.25), value: controller.activeSourceAddress)
        .animation(.snappy(duration: 0.25), value: controller.pendingSourceAddress)
        .animation(.snappy(duration: 0.25), value: controller.sourceSwitchFailed)
    }

    private func sourceRow(_ device: MultipointDevice) -> some View {
        let isActive = controller.activeSourceAddress == device.address
        let isPending = controller.pendingSourceAddress == device.address
        return Button {
            feedback()
            controller.switchAudioSource(to: device)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.blue : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: deviceSymbol(device.displayName))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : Color.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(isPending ? "Switching…" : (isActive ? "Playing" : "Connected"))
                        .font(.caption)
                        .foregroundStyle(isActive ? Color.blue : Color.secondary)
                }
                Spacer(minLength: 8)
                if isPending {
                    ProgressView()
                } else if isActive {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.blue)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: nowPlaying.isPlaying)
                } else {
                    Text("Switch")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? Color.blue.opacity(0.14) : Color(.tertiarySystemFill).opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityHint(isActive ? "" : "Moves playback to this device")
    }

    private func deviceSymbol(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("macbook") || lower.contains("laptop") || lower.contains("notebook") { return "laptopcomputer" }
        if lower.contains("imac") || lower.contains("mac") || lower.contains("pc") || lower.contains("desktop") { return "desktopcomputer" }
        if lower.contains("ipad") || lower.contains("tab") { return "ipad" }
        if lower.contains("tv") { return "tv" }
        if lower.contains("watch") { return "applewatch" }
        return "iphone"
    }

    // MARK: Equalizer

    private var equalizerCard: some View {
        let state = controller.equalizer
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                sectionTitle("Equalizer", symbol: "slider.vertical.3")
                Spacer()
                eqFileMenu
            }

            if let state {
                profileRow(state)
            }

            EqualizerVisualizer(
                bands: state?.bands ?? [],
                live: liveSpectrum,
                isLive: liveSpectrum.isLive,
                editable: controller.isReady,
                onChange: { controller.previewEqualizerBand($0, value: $1) },
                onCommit: { controller.commitEqualizerBands() }
            )

            liveSoundRow

            if let state, state.bands.count == 6 {
                clearBassRow(state)
            }

            if let state, !state.bands.isEmpty {
                HStack {
                    Label("Drag the points to adjust", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        feedback()
                        controller.resetEqualizerBands()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(!controller.isReady || state.bands.allSatisfy { $0 == 0 })
                }
            } else {
                Text("The headphones haven't reported an equalizer yet. Pull down to refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if broadcastPicker.extensionMissing {
                Label("The live audio extension isn't installed. Re-sign the app with its app extensions included.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(card)
    }

    /// Starts or stops the screen broadcast that feeds real sound to the
    /// waveform. Without it, the plot shows only the EQ curve.
    private var liveSoundRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if liveSpectrum.isLive {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Showing live sound")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Stop") { feedback(); broadcastPicker.open() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.red)
                } else {
                    Button {
                        feedback()
                        if nowPlaying.isMusicAppPlaying {
                            showingMusicWarning = true
                        } else {
                            broadcastPicker.open()
                        }
                    } label: {
                        Label("Show live sound", systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .background(BroadcastPickerHost(picker: broadcastPicker).frame(width: 1, height: 1))
            Text(liveSpectrum.isLive && liveSpectrum.isSilent
                 ? "No sound is coming through. Apple Music is muted in screen broadcasts; Spotify, YouTube and most other apps work."
                 : "Draws the sound that's playing, using a screen broadcast. Doesn't work with Apple Music.")
                .font(.caption)
                .foregroundStyle(liveSpectrum.isLive && liveSpectrum.isSilent ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Apple Music can't be shown", isPresented: $showingMusicWarning) {
            Button("Start Anyway") { broadcastPicker.open() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iOS mutes Apple Music in screen broadcasts, so the waveform will stay flat. Spotify, YouTube and most other apps work.")
        }
    }

    private var eqFileMenu: some View {
        Menu {
            Button {
                exportName = controller.equalizer.map { EqualizerPreset.name(for: $0.presetID) } ?? "My EQ"
                namingExport = true
            } label: { Label("Export EQ", systemImage: "square.and.arrow.up") }
                .disabled(controller.equalizer?.bands.isEmpty ?? true)
            Button { importingEQ = true } label: { Label("Import EQ", systemImage: "square.and.arrow.down") }
                .disabled(!controller.isReady || controller.equalizer == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(.tertiarySystemFill)))
        }
        .accessibilityLabel("Equalizer options")
        .alert("Name this EQ", isPresented: $namingExport) {
            TextField("Name", text: $exportName)
            Button("Save") {
                // Let the alert finish closing before the save sheet opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exportingEQ = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used as the file name.")
        }
        .fileExporter(isPresented: $exportingEQ, document: EQDocument(file: currentEQFile), contentType: .json, defaultFilename: exportFileName) { result in
            if case .failure = result { eqFileMessage = "The EQ couldn't be saved." }
        }
    }

    /// The typed name, without characters that aren't allowed in file names.
    private var exportFileName: String {
        let cleaned = exportName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "My EQ" : cleaned
    }

    private var currentEQFile: EQFile {
        let state = controller.equalizer
        let bands = state?.bands ?? []
        let hasClearBass = bands.count == 6
        return EQFile(
            clearBass: hasClearBass ? bands[0] : nil,
            bands: hasClearBass ? Array(bands.dropFirst()) : bands
        )
    }

    private func importEQ(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure = result { eqFileMessage = "The file couldn't be opened." }
            return
        }
        guard let data = Self.readFile(at: url) else {
            eqFileMessage = "The file couldn't be read. If it's in iCloud Drive, download it first."
            return
        }
        guard let file = try? JSONDecoder().decode(EQFile.self, from: data),
              file.bands.allSatisfy({ (-10...10).contains($0) }),
              (file.clearBass ?? 0) >= -10, (file.clearBass ?? 0) <= 10 else {
            eqFileMessage = "That file isn't a Sound Control EQ."
            return
        }
        guard controller.isReady, let current = controller.equalizer else {
            eqFileMessage = "Connect the headphones, then import again."
            return
        }
        if controller.importEqualizer(bands: file.bands, clearBass: file.clearBass) {
            feedback()
        } else {
            let expected = current.bands.count == 6 ? 5 : current.bands.count
            eqFileMessage = "That EQ has \(file.bands.count) bands; these headphones use \(expected)."
        }
    }

    /// Reads a picked file, including iCloud files that aren't downloaded yet.
    private static func readFile(at url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return data ?? (try? Data(contentsOf: url))
    }

    private func profileRow(_ state: EqualizerState) -> some View {
        Button {
            feedback()
            showingProfiles = true
        } label: {
            HStack(spacing: 12) {
                MiniCurve(bands: state.bands)
                    .frame(width: 56, height: 30)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemFill)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(EqualizerPreset.name(for: state.presetID))
                        .font(.headline)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill).opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.isReady)
        .accessibilityLabel("Equalizer profile, \(EqualizerPreset.name(for: state.presetID))")
    }

    private func clearBassRow(_ state: EqualizerState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Clear Bass", systemImage: "speaker.wave.3.fill")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(signed(state.bands[0]))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(state.bands[0] == 0 ? Color.secondary : Color.cyan)
                    .contentTransition(.numericText())
            }
            Slider(
                value: Binding(
                    get: { Double(controller.equalizer?.bands.first ?? 0) },
                    set: { controller.previewEqualizerBand(0, value: Int($0.rounded())) }
                ),
                in: -10...10,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { controller.commitEqualizerBands() }
                }
            )
            .tint(.cyan)
            .disabled(!controller.isReady)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill).opacity(0.5)))
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    // MARK: Shared pieces

    private var card: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    private func sectionHeader(
        _ title: String,
        symbol: String,
        switchAction: (() -> Void)? = nil,
        switchLabel: String = ""
    ) -> some View {
        HStack(spacing: 8) {
            sectionTitle(title, symbol: symbol)
            Spacer()
            if let switchAction {
                Button {
                    feedback()
                    switchAction()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(controller.isReady ? Color.primary : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .disabled(!controller.isReady)
                .accessibilityLabel(switchLabel)
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
        }
    }

    private var segmentBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }

    private func modeSegment(_ mode: ANCMode, title: String, short: String, symbol: String) -> some View {
        let isActive = controller.currentMode == mode
        return Button {
            feedback()
            controller.setMode(mode)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3)
                ViewThatFits {
                    Text(title)
                    Text(short)
                }
                .font(.caption.weight(.semibold))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? modeTint(mode) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isActive)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func modeTint(_ mode: ANCMode) -> Color {
        switch mode {
        case .anc: return .blue
        case .ambient: return .teal
        case .off: return Color(.systemGray)
        }
    }

    private func feedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var connectedDevices: [MultipointDevice] {
        controller.multipointDevices.filter { $0.isConnected }
    }
}

// MARK: - Battery gauge

private struct BatteryGauge: View {
    let label: String
    let symbol: String
    let level: Int
    let charging: Bool

    private var tint: Color {
        if charging { return .green }
        if level <= 10 { return .red }
        if level <= 20 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Text("\(level)%")
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.quaternarySystemFill))
                    Capsule().fill(tint).frame(width: max(6, geo.size.width * CGFloat(level) / 100))
                }
            }
            .frame(height: 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill).opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) battery")
        .accessibilityValue("\(level) percent\(charging ? ", charging" : "")")
    }
}

// MARK: - Profile picker

/// Small EQ curve preview. Flat dashed line when the curve is unknown.
struct MiniCurve: View {
    let bands: [Int]?

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            guard let bands, !bands.isEmpty else {
                var flat = Path()
                flat.move(to: CGPoint(x: 0, y: mid))
                flat.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(flat, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
                return
            }
            let curve = EqualizerCurve(reported: bands)
            var path = Path()
            for s in 0...40 {
                let x = Double(s) / 40
                let y = mid - CGFloat(curve.gain(at: x) / 10) * (size.height / 2 - 2)
                let point = CGPoint(x: size.width * x, y: y)
                if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            // Same color scale as the main curve: +10 at the top, -10 at the bottom.
            context.stroke(
                path,
                with: .linearGradient(
                    EqualizerVisualizer.gainGradient,
                    startPoint: CGPoint(x: 0, y: 2), endPoint: CGPoint(x: 0, y: size.height - 2)
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

private struct ProfilePickerSheet: View {
    @ObservedObject var controller: ANCController
    @Environment(\.dismiss) private var dismiss

    private var presets: [EqualizerPreset] { controller.equalizerPresets }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets.filter { $0.id == 0x00 }) { row($0) }
                }
                Section("Sound Presets") {
                    ForEach(presets.filter { $0.id != 0x00 && !$0.isCustomSlot }) { row($0) }
                }
                Section {
                    ForEach(presets.filter(\.isCustomSlot)) { row($0) }
                } header: {
                    Text("Your Profiles")
                } footer: {
                    Text("Dragging the curve saves to the selected custom profile, or to Manual when a sound preset is selected. Curves appear here after a profile has been used once.")
                }
            }
            .navigationTitle("Equalizer Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ preset: EqualizerPreset) -> some View {
        let selected = controller.equalizer?.presetID == preset.id
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            controller.selectEqualizerPreset(preset)
        } label: {
            HStack(spacing: 14) {
                MiniCurve(bands: preset.id == 0x00 ? [0, 0, 0, 0, 0, 0] : controller.presetCurves[preset.id])
                    .frame(width: 52, height: 26)
                Text(preset.name)
                    .foregroundStyle(Color.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - EQ file

/// Exported equalizer: Clear Bass and the five curve bands (-10...+10).
struct EQFile: Codable {
    var app = "Sound Control"
    var clearBass: Int?
    var bands: [Int]

    init(clearBass: Int?, bands: [Int]) {
        self.clearBass = clearBass
        self.bands = bands
    }

    /// Other keys (such as `name` or `version` in older exports) are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? c.decode(String.self, forKey: .app)) ?? "Sound Control"
        clearBass = try? c.decode(Int.self, forKey: .clearBass)
        bands = try c.decode([Int].self, forKey: .bands)
    }
}

struct EQDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let file: EQFile

    init(file: EQFile) { self.file = file }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        file = try JSONDecoder().decode(EQFile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(file))
    }
}
