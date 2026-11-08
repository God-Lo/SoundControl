import AppIntents
import AVFAudio
import SwiftUI
import WidgetKit

@main
struct SoundControlWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        if #available(iOS 18.0, *) {
            NoiseControlControl()
            AudioSourceControl()
        }
    }
}

// MARK: - Shared state as seen by the extension

extension HeadphoneSnapshot {
    /// The app's last snapshot, corrected for a disconnect the app may have
    /// missed (for example if iOS ended it): when audio is no longer routed
    /// to any Bluetooth output, the headphones are treated as disconnected.
    static func current() -> HeadphoneSnapshot {
        var snapshot = load()
        if snapshot.isConnected, !Self.bluetoothRouteActive { snapshot.isConnected = false }
        return snapshot
    }

    private static var bluetoothRouteActive: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // An empty route means it could not be read; trust the app then.
        guard !outputs.isEmpty else { return true }
        return outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
    }

    static var preview: HeadphoneSnapshot {
        var snapshot = HeadphoneSnapshot()
        snapshot.name = "WF-1000XM5"
        snapshot.isConnected = true
        snapshot.mode = .anc
        snapshot.left = 80
        snapshot.right = 80
        snapshot.caseLevel = 60
        snapshot.source = "iPhone"
        snapshot.equalizer = "Bass Boost"
        snapshot.equalizerID = 0x16
        snapshot.devices = [
            .init(address: "A", name: "iPhone", isActive: true),
            .init(address: "B", name: "MacBook", isActive: false)
        ]
        snapshot.presets = [
            (0x00, "Off"), (0x10, "Bright"), (0x11, "Excited"), (0x12, "Mellow"),
            (0x13, "Relaxed"), (0x14, "Vocal"), (0x15, "Treble Boost"), (0x16, "Bass Boost"),
            (0x17, "Speech"), (0xA0, "Manual"), (0xA1, "Custom 1"), (0xA2, "Custom 2")
        ].map { .init(id: $0.0, name: $0.1) }
        return snapshot
    }
}

// MARK: - Home screen widget

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: HeadphoneSnapshot
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: context.isPreview ? .preview : .current()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads widgets on every change; the periodic refresh only
        // catches a disconnect the app missed.
        let entry = StatusEntry(date: .now, snapshot: .current())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.status, provider: StatusProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) {
                    Color(uiColor: .secondarySystemGroupedBackground)
                }
        }
        .configurationDisplayName("Headphones")
        .description("Listening mode, audio source, EQ and battery.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let snapshot: HeadphoneSnapshot

    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        Group {
            if !snapshot.isConnected {
                disconnected
            } else {
                switch family {
                case .systemLarge: large
                case .systemMedium: medium
                default: small
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Layouts

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Button(intent: WidgetToggleModeIntent()) {
                HStack(spacing: 6) {
                    Image(systemName: snapshot.mode?.symbol ?? "headphones")
                        .widgetAccentable()
                    Text(snapshot.mode?.shortTitle ?? "–")
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(fullColor ? tint(snapshot.mode) : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 3) {
                detailRow("arrow.left.arrow.right", snapshot.source)
                detailRow("slider.vertical.3", equalizerText)
            }
            Spacer(minLength: 4)
            batteryLine(compact: true)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            modeButtons
                .frame(height: 50)
            HStack(spacing: 6) {
                sourceChip
                equalizerChip
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            modeButtons
                .frame(height: 56)
            sectionTitle("Audio Source")
            if snapshot.devices.isEmpty {
                Text("No devices reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(snapshot.devices.prefix(3), id: \.self) { device in
                        Button(intent: WidgetSwitchToDeviceIntent(address: device.address)) {
                            listRow(device.name, symbol: "arrow.left.arrow.right", selected: device.isActive)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            sectionTitle("Equalizer")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(largePresets, id: \.self) { preset in
                    Button(intent: WidgetSetEqualizerIntent(presetID: preset.id)) {
                        Text(preset.name == "Off" ? "EQ Off" : preset.name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selectedForeground(preset.id == snapshot.equalizerID))
                            .background(chipBackground(selected: preset.id == snapshot.equalizerID))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text("Not Connected")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Connect your headphones")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "headphones")
            Text(snapshot.name)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// The name never truncates; battery takes the space left and switches
    /// to its short form (then shrinks) when needed.
    private var topRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            header.fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                batteryLine(compact: false).fixedSize()
                batteryLine(compact: true)
            }
        }
    }

    private var modeButtons: some View {
        HStack(spacing: 6) {
            modeButton(.anc)
            modeButton(.ambient)
            modeButton(.off)
        }
    }

    /// Up to 12 presets: the current one is always included.
    private var largePresets: [HeadphoneSnapshot.Preset] {
        var list = Array(snapshot.presets.prefix(12))
        if let id = snapshot.equalizerID, !list.contains(where: { $0.id == id }),
           let current = snapshot.presets.first(where: { $0.id == id }) {
            list[list.count - 1] = current
        }
        return list
    }

    private var sourceChip: some View {
        Button(intent: WidgetSwitchSourceIntent()) {
            chipLabel("arrow.left.arrow.right", snapshot.source ?? "–")
                .opacity(snapshot.canSwitchSource ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }

    private var equalizerChip: some View {
        Button(intent: WidgetNextEqualizerIntent()) {
            chipLabel("slider.vertical.3", equalizerText ?? "–")
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: .infinity)
        .background(chipBackground(selected: false))
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func listRow(_ text: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "checkmark" : symbol)
                .frame(width: 16)
                .widgetAccentable(selected)
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if selected { Text("Playing").font(.caption2).opacity(0.8) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .foregroundStyle(selectedForeground(selected))
        .background(chipBackground(selected: selected))
        .contentShape(Rectangle())
    }

    private func chipBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected && fullColor ? Color.blue : Color.primary.opacity(selected ? 0.28 : 0.08))
    }

    private func selectedForeground(_ selected: Bool) -> Color {
        selected && fullColor ? .white : .primary
    }

    private var equalizerText: String? {
        guard let name = snapshot.equalizer else { return nil }
        return name == "Off" ? "EQ Off" : name
    }

    private func detailRow(_ symbol: String, _ text: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text ?? "–")
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// Battery as a single text line, so it shrinks as a whole to fit,
    /// e.g. "L 100  R 95  C 62" or "L 100%  R 95%  Case 62%".
    private func batteryLine(compact: Bool) -> some View {
        var parts: [(String, Int?)] = []
        if snapshot.left != nil || snapshot.right != nil {
            parts = [("L", snapshot.left), ("R", snapshot.right)]
        } else if snapshot.single != nil {
            parts = [("", snapshot.single)]
        }
        if snapshot.caseLevel != nil { parts.append((compact ? "C" : "Case", snapshot.caseLevel)) }

        var text = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 { text = text + Text(compact ? "  " : "   ") }
            if !part.0.isEmpty { text = text + Text(part.0 + " ").foregroundStyle(.secondary) }
            text = text + Text(part.1.map { compact ? "\($0)" : "\($0)%" } ?? "–")
        }
        return HStack(spacing: 4) {
            Image(systemName: "battery.75").foregroundStyle(.secondary)
            text
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private func modeButton(_ mode: WidgetMode) -> some View {
        let active = snapshot.mode == mode
        let enabled = mode != .anc || snapshot.supportsNoiseCancellation
        return Button(intent: WidgetSetModeIntent(mode: mode)) {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol)
                    .font(.body.weight(.semibold))
                    .widgetAccentable(active)
                Text(mode.shortTitle)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 46, maxHeight: .infinity)
            .foregroundStyle(active && fullColor ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(buttonFill(mode, active: active))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// In tinted and clear (glass) modes colors are flattened, so a solid
    /// fill would hide the label; use a light translucent fill instead.
    private func buttonFill(_ mode: WidgetMode, active: Bool) -> Color {
        if fullColor { return active ? tint(mode) : Color.primary.opacity(0.07) }
        return Color.primary.opacity(active ? 0.28 : 0.08)
    }

    private func tint(_ mode: WidgetMode?) -> Color {
        switch mode {
        case .anc: return .blue
        case .ambient: return .teal
        default: return .gray
        }
    }
}

// MARK: - Control Center

/// "disconnected", a `WidgetMode` raw value, or "" when the mode is unknown.
@available(iOS 18.0, *)
struct ModeValueProvider: ControlValueProvider {
    var previewValue: String { WidgetMode.anc.rawValue }

    func currentValue() async throws -> String {
        let snapshot = HeadphoneSnapshot.current()
        guard snapshot.isConnected else { return "disconnected" }
        return snapshot.mode?.rawValue ?? ""
    }
}

@available(iOS 18.0, *)
struct NoiseControlControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.noiseControl, provider: ModeValueProvider()) { value in
            ControlWidgetButton(action: WidgetToggleModeIntent()) {
                if value == "disconnected" {
                    Label("Not Connected", systemImage: "headphones")
                } else if let mode = WidgetMode(rawValue: value) {
                    Label(mode.title, systemImage: mode.symbol)
                } else {
                    Label("Noise Control", systemImage: "headphones")
                }
            }
        }
        .displayName("Noise Control")
        .description("Switch between Noise Cancelling and Ambient.")
    }
}

@available(iOS 18.0, *)
struct SourceValueProvider: ControlValueProvider {
    var previewValue: String { "iPhone" }

    /// "unavailable", or the name of the playing device ("" if unknown).
    func currentValue() async throws -> String {
        let snapshot = HeadphoneSnapshot.current()
        guard snapshot.canSwitchSource else { return "unavailable" }
        return snapshot.source ?? ""
    }
}

@available(iOS 18.0, *)
struct AudioSourceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.audioSource, provider: SourceValueProvider()) { source in
            ControlWidgetButton(action: WidgetSwitchSourceIntent()) {
                if source == "unavailable" {
                    Label("Unavailable", systemImage: "nosign")
                } else {
                    Label(source.isEmpty ? "Audio Source" : source, systemImage: "arrow.left.arrow.right")
                }
            }
        }
        .displayName("Switch Audio Source")
        .description("Move playback to the other connected device.")
    }
}

#Preview("Small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Medium", as: .systemMedium) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Large", as: .systemLarge) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}
