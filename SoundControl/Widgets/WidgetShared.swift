import AppIntents
import Foundation
import WidgetKit

/// Shared by the app and the widget extension.

/// Last known headphone state, written by the app for widgets and controls.
struct HeadphoneSnapshot: Codable, Equatable {
    var name = "Headphones"
    var isConnected = false
    var mode: WidgetMode?
    var supportsNoiseCancellation = true
    var left: Int?
    var right: Int?
    var single: Int?
    var caseLevel: Int?
    var source: String?
    var equalizer: String?
    var equalizerID: Int?
    /// Connected multipoint devices, in the order the headphones report them.
    var devices: [Device] = []
    /// EQ presets the headphones offer.
    var presets: [Preset] = []
    var updated = Date()

    struct Device: Codable, Equatable, Hashable {
        var address: String
        var name: String
        var isActive: Bool
    }

    struct Preset: Codable, Equatable, Hashable {
        var id: Int
        var name: String
    }

    var canSwitchSource: Bool { isConnected && devices.count >= 2 }

    static let appGroup = "group.com.example.SoundControl"
    private static let key = "headphoneSnapshot"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func load() -> HeadphoneSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(HeadphoneSnapshot.self, from: data) else {
            return HeadphoneSnapshot()
        }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: Self.key)
    }
}

enum WidgetMode: String, Codable, AppEnum {
    case anc
    case ambient
    case off

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening Mode")
    static var caseDisplayRepresentations: [WidgetMode: DisplayRepresentation] = [
        .anc: "Noise Cancelling",
        .ambient: "Ambient",
        .off: "Off"
    ]

    var title: String {
        switch self {
        case .anc: return "Noise Cancelling"
        case .ambient: return "Ambient"
        case .off: return "Off"
        }
    }

    var shortTitle: String {
        switch self {
        case .anc: return "ANC"
        case .ambient: return "Ambient"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .anc: return "person.wave.2.fill"
        case .ambient: return "ear.fill"
        case .off: return "circle.slash"
        }
    }
}

enum WidgetKinds {
    static let status = "HeadphoneStatus"
    static let noiseControl = "NoiseControlButton"
    static let audioSource = "AudioSourceButton"
}

// Widget and control actions. `AudioPlaybackIntent` makes the system run them
// in the app's process (launching it in the background if needed), which owns
// the accessory session. The extension copy only lets widgets reference them.

struct WidgetSetModeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Listening Mode"
    static var isDiscoverable = false

    @Parameter(title: "Mode") var mode: WidgetMode

    init() {}
    init(mode: WidgetMode) { self.mode = mode }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActions.run { try await $0.performShortcutMode(mode.controllerMode) }
        #endif
        return .result()
    }
}

struct WidgetToggleModeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Toggle ANC and Ambient"
    static var isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActions.run { _ = try await $0.performShortcutToggle() }
        #endif
        return .result()
    }
}

struct WidgetSwitchSourceIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Switch Audio Source"
    static var isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActions.run { _ = try await $0.performShortcutSwitchAudioSource() }
        #endif
        return .result()
    }
}

struct WidgetSwitchToDeviceIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Switch to Device"
    static var isDiscoverable = false

    @Parameter(title: "Address") var address: String

    init() {}
    init(address: String) { self.address = address }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActions.run { try await $0.performWidgetSwitch(to: address) }
        #endif
        return .result()
    }
}

struct WidgetSetEqualizerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Equalizer"
    static var isDiscoverable = false

    @Parameter(title: "Preset") var presetID: Int

    init() {}
    init(presetID: Int) { self.presetID = presetID }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActions.run { try await $0.performWidgetEqualizer(UInt8(clamping: presetID)) }
        #endif
        return .result()
    }
}

struct WidgetNextEqualizerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Equalizer Preset"
    static var isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetActions.run { try await $0.performWidgetNextEqualizer() }
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
extension WidgetMode {
    init(_ mode: ANCMode) {
        switch mode {
        case .anc: self = .anc
        case .ambient: self = .ambient
        case .off: self = .off
        }
    }

    var controllerMode: ANCMode {
        switch self {
        case .anc: return .anc
        case .ambient: return .ambient
        case .off: return .off
        }
    }
}
#endif
