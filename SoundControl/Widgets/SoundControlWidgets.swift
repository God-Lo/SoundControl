import AppIntents
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
        completion(StatusEntry(date: .now, snapshot: context.isPreview ? .preview : .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads widgets whenever the headphone state changes.
        completion(Timeline(entries: [StatusEntry(date: .now, snapshot: .load())], policy: .never))
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.status, provider: StatusProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Headphones")
        .description("Listening mode and battery.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: HeadphoneSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "headphones")
                Text(snapshot.name).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if snapshot.isConnected {
                if family == .systemMedium {
                    HStack(spacing: 8) {
                        modeButton(.anc)
                        modeButton(.ambient)
                        modeButton(.off)
                    }
                } else {
                    Button(intent: WidgetToggleModeIntent()) {
                        Label(snapshot.mode?.shortTitle ?? "–", systemImage: snapshot.mode?.symbol ?? "headphones")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .tint(tint(snapshot.mode))
                    .foregroundStyle(tint(snapshot.mode))
                }
                Spacer(minLength: 0)
                BatteryRow(snapshot: snapshot)
            } else {
                Spacer(minLength: 0)
                Text("Not connected")
                    .font(.headline)
                Text("Open Sound Control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func modeButton(_ mode: WidgetMode) -> some View {
        let active = snapshot.mode == mode
        let enabled = mode != .anc || snapshot.supportsNoiseCancellation
        return Button(intent: WidgetSetModeIntent(mode: mode)) {
            VStack(spacing: 4) {
                Image(systemName: mode.symbol).font(.title3)
                Text(mode.shortTitle).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? tint(mode) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func tint(_ mode: WidgetMode?) -> Color {
        switch mode {
        case .anc: return .blue
        case .ambient: return .teal
        default: return .gray
        }
    }
}

struct BatteryRow: View {
    let snapshot: HeadphoneSnapshot

    var body: some View {
        HStack(spacing: 10) {
            if snapshot.left != nil || snapshot.right != nil {
                item("L", snapshot.left)
                item("R", snapshot.right)
            } else if snapshot.single != nil {
                item(nil, snapshot.single)
            }
            if snapshot.caseLevel != nil {
                item("Case", snapshot.caseLevel)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func item(_ label: String?, _ level: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol(level))
            if let label { Text(label).foregroundStyle(.secondary) }
            Text(level.map { "\($0)%" } ?? "–")
        }
    }

    private func symbol(_ level: Int?) -> String {
        switch level ?? 0 {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }
}

extension HeadphoneSnapshot {
    static var preview: HeadphoneSnapshot {
        var snapshot = HeadphoneSnapshot()
        snapshot.isConnected = true
        snapshot.mode = .anc
        snapshot.left = 80
        snapshot.right = 80
        snapshot.caseLevel = 60
        return snapshot
    }
}

// MARK: - Control Center

@available(iOS 18.0, *)
struct ModeValueProvider: ControlValueProvider {
    var previewValue: String { WidgetMode.anc.rawValue }

    func currentValue() async throws -> String {
        let snapshot = HeadphoneSnapshot.load()
        return snapshot.isConnected ? (snapshot.mode?.rawValue ?? "") : ""
    }
}

@available(iOS 18.0, *)
struct NoiseControlControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.noiseControl, provider: ModeValueProvider()) { value in
            let mode = WidgetMode(rawValue: value)
            ControlWidgetButton(action: WidgetToggleModeIntent()) {
                Label(mode?.title ?? "Noise Control", systemImage: mode?.symbol ?? "headphones")
            }
        }
        .displayName("Noise Control")
        .description("Switch between Noise Cancelling and Ambient.")
    }
}

@available(iOS 18.0, *)
struct SourceValueProvider: ControlValueProvider {
    var previewValue: String { "iPhone" }

    func currentValue() async throws -> String {
        let snapshot = HeadphoneSnapshot.load()
        return snapshot.isConnected ? (snapshot.source ?? "") : ""
    }
}

@available(iOS 18.0, *)
struct AudioSourceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.audioSource, provider: SourceValueProvider()) { source in
            ControlWidgetButton(action: WidgetSwitchSourceIntent()) {
                Label(source.isEmpty ? "Audio Source" : source, systemImage: "arrow.left.arrow.right")
            }
        }
        .displayName("Switch Audio Source")
        .description("Move playback to the other connected device.")
    }
}
