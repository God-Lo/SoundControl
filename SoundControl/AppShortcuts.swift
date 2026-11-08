import AppIntents

@available(iOS 17.0, *)
enum ListeningModeOption: String, AppEnum {
    case noiseCancellation
    case ambientSound
    case off

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening Mode")
    static var caseDisplayRepresentations: [ListeningModeOption: DisplayRepresentation] = [
        .noiseCancellation: "ANC",
        .ambientSound: "Ambient",
        .off: "Off"
    ]

    var controllerMode: ANCMode {
        switch self {
        case .noiseCancellation: return .anc
        case .ambientSound: return .ambient
        case .off: return .off
        }
    }

    var displayName: String {
        switch self {
        case .noiseCancellation: return "Noise Cancellation"
        case .ambientSound: return "Ambient Sound"
        case .off: return "Off"
        }
    }

    var shortcutValue: String {
        switch self {
        case .noiseCancellation: return "ANC"
        case .ambientSound: return "Ambient"
        case .off: return "Off"
        }
    }
}

@available(iOS 17.0, *)
struct SetListeningModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Listening Mode"
    static var description = IntentDescription("Set compatible headphones to noise cancellation, ambient sound, or off.")
    static var openAppWhenRun = false

    @Parameter(title: "Mode") var mode: ListeningModeOption

    init() {}

    init(mode: ListeningModeOption) {
        self.mode = mode
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ANCController.shared.performShortcutMode(mode.controllerMode)
        return .result()
    }
}

@available(iOS 17.0, *)
struct SetAmbientLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Ambient Level"
    static var description = IntentDescription("Set the ambient sound level from 1 to 20. It changes the headphones only when Ambient Sound is active.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Set Ambient Level to \(\.$level)")
    }

    @Parameter(
        title: "Level",
        default: 1.0,
        controlStyle: .slider,
        inclusiveRange: (lowerBound: 0.0, upperBound: 1.0)
    ) var level: Double

    init() {}

    init(level: Double) {
        self.level = level
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let boundedLevel = 1 + Int((max(0, min(level, 1)) * 19).rounded())
        try await ANCController.shared.performShortcutAmbientLevel(boundedLevel)
        return .result()
    }
}

@available(iOS 17.0, *)
struct ToggleNoiseControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle ANC and Ambient"
    static var description = IntentDescription("Switch compatible headphones between Noise Cancellation and Ambient Sound.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await ANCController.shared.performShortcutToggle()
        return .result()
    }
}

@available(iOS 17.0, *)
struct GetNoiseControlStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Listening Mode"
    static var description = IntentDescription("Return ANC, Ambient, or Off for the current listening mode.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Get Listening Mode")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let state = try await ANCController.shared.performShortcutGetStatus()
        return .result(value: state.mode.shortcutValue)
    }
}

@available(iOS 17.0, *)
struct GetAmbientLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Ambient Level"
    static var description = IntentDescription("Return the current ambient sound level as a number from 1 to 20.")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Get Ambient Level")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let state = try await ANCController.shared.performShortcutGetStatus()
        return .result(value: state.ambientLevel)
    }
}

@available(iOS 17.0, *)
struct SwitchAudioSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Audio Source"
    static var description = IntentDescription("Move audio playback from the headphones' current multipoint device to the other connected device.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let deviceName = try await ANCController.shared.performShortcutSwitchAudioSource()
        return .result(value: deviceName)
    }
}

@available(iOS 17.0, *)
struct GetAudioSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Audio Source"
    static var description = IntentDescription("Return the name of the device the headphones are currently playing audio from.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let deviceName = try await ANCController.shared.performShortcutGetAudioSource()
        return .result(value: deviceName)
    }
}

@available(iOS 17.0, *)
struct UpdateHeadphoneInfoIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Headphone Info"
    static var description = IntentDescription("Re-read the headphones and update widgets and Control Center. Returns whether they are connected.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: await ANCController.shared.performShortcutUpdateInfo())
    }
}

@available(iOS 17.0, *)
struct SoundControlShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetListeningModeIntent(),
            phrases: ["Set \(\.$mode) with \(.applicationName)"],
            shortTitle: "Listening Mode",
            systemImageName: "ear"
        )
        AppShortcut(
            intent: SetAmbientLevelIntent(),
            phrases: ["Set ambient level with \(.applicationName)"],
            shortTitle: "Ambient Level",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: ToggleNoiseControlIntent(),
            phrases: ["Toggle ANC and ambient with \(.applicationName)"],
            shortTitle: "Toggle ANC/Ambient",
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: GetNoiseControlStatusIntent(),
            phrases: ["Get headphone mode with \(.applicationName)"],
            shortTitle: "Headphone Status",
            systemImageName: "waveform.badge.mic"
        )
        AppShortcut(
            intent: GetAmbientLevelIntent(),
            phrases: ["Get ambient level with \(.applicationName)"],
            shortTitle: "Get Ambient Level",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SwitchAudioSourceIntent(),
            phrases: ["Switch audio source with \(.applicationName)"],
            shortTitle: "Switch Audio Source",
            systemImageName: "hifispeaker.2"
        )
        AppShortcut(
            intent: GetAudioSourceIntent(),
            phrases: ["Get audio source with \(.applicationName)"],
            shortTitle: "Audio Source",
            systemImageName: "hifispeaker"
        )
        AppShortcut(
            intent: UpdateHeadphoneInfoIntent(),
            phrases: ["Update headphone info with \(.applicationName)"],
            shortTitle: "Update Info",
            systemImageName: "arrow.clockwise"
        )
    }
}
