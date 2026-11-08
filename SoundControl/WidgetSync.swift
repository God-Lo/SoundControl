import Combine
import Foundation
import UIKit
import UserNotifications
import WidgetKit

/// Copies the controller's state to the shared snapshot and reloads widgets
/// and Control Center controls when it changes. With the external-accessory
/// background mode this also runs while the app is in the background, so
/// changes made on the headphones reach the widgets without opening the app.
@MainActor
final class WidgetSync {
    private var cancellables: Set<AnyCancellable> = []
    private var last = HeadphoneSnapshot.load()
    private weak var controller: ANCController?

    init(controller: ANCController) {
        self.controller = controller
        controller.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncNow() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.syncNow() }
            .store(in: &cancellables)
        syncNow()
    }

    func syncNow() {
        guard let controller else { return }
        var snapshot = HeadphoneSnapshot()
        snapshot.isConnected = controller.isConnected
        snapshot.name = controller.isConnected ? controller.displayName : last.name
        snapshot.mode = controller.currentMode.map(WidgetMode.init)
        snapshot.supportsNoiseCancellation = controller.supportsNoiseCancellation
        snapshot.left = controller.battery.left
        snapshot.right = controller.battery.right
        snapshot.single = controller.battery.single
        snapshot.caseLevel = controller.battery.caseLevel
        snapshot.source = controller.multipointDevices
            .first { $0.address == controller.activeSourceAddress }?.displayName
        if let id = controller.equalizer?.presetID {
            snapshot.equalizer = controller.equalizerPresets.first { $0.id == id }?.name
                ?? EqualizerPreset.name(for: id)
        }

        var compare = snapshot
        compare.updated = last.updated
        guard compare != last else { return }
        last = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }
}

/// Runs a widget or Control Center action in the app, then updates the
/// widgets. Failures are reported with a notification, since widgets and
/// controls have no other way to show an error.
@MainActor
enum WidgetActions {
    static func run(_ action: (ANCController) async throws -> Void) async {
        let controller = ANCController.shared
        guard controller.accessoryAvailable else {
            controller.syncWidgets()
            notify("Headphones not connected", "Connect your headphones, then try again.")
            return
        }
        do {
            try await action(controller)
            // Give the headphones a moment to confirm before updating widgets.
            try? await Task.sleep(for: .milliseconds(800))
        } catch ShortcutError.headphonesNotReady {
            notify("Headphones not responding", "Make sure they're connected, then try again.")
        } catch {
            notify("Couldn't change headphones", error.localizedDescription)
        }
        controller.syncWidgets()
    }

    private static func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "widget-action", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Shows action notifications as banners even while the app is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
