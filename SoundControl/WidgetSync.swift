import Combine
import Foundation
import WidgetKit

/// Copies the controller's state to the shared snapshot and reloads widgets
/// and Control Center controls when it changes.
@MainActor
final class WidgetSync {
    private var cancellable: AnyCancellable?
    private var last = HeadphoneSnapshot.load()

    init(controller: ANCController) {
        cancellable = controller.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.update(from: controller)
            }
        update(from: controller)
    }

    private func update(from controller: ANCController) {
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
