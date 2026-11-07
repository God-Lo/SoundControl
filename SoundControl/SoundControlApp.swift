import SwiftUI

@main
struct SoundControlApp: App {
    @StateObject private var controller = ANCController.shared

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onOpenURL { url in
                    Task { await handleShortcutURL(url) }
                }
        }
    }

    @MainActor
    private func handleShortcutURL(_ url: URL) async {
        guard url.scheme == "soundcontrol" else { return }
        let action = url.host ?? url.pathComponents.dropFirst().first
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = (components?.queryItems ?? []).reduce(into: [String: String]()) { values, item in
            if let value = item.value { values[item.name] = value }
        }

        do {
            switch action {
            case "set-mode":
                guard let mode = query["mode"]?.lowercased() else { return }
                let value: ANCMode
                switch mode {
                case "anc": value = .anc
                case "ambient": value = .ambient
                case "off": value = .off
                default: return
                }
                try await controller.performShortcutMode(value)
            case "set-ambient-level":
                guard let level = query["level"].flatMap(Int.init), (1...20).contains(level) else { return }
                try await controller.performShortcutAmbientLevel(level)
            case "toggle":
                _ = try await controller.performShortcutToggle()
            case "get-mode", "get-level":
                _ = try await controller.performShortcutGetStatus()
            default:
                return
            }
        } catch {
            // The app opens to its normal connection screen if the accessory is unavailable.
        }
    }
}
