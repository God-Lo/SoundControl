import CoreBluetooth
import Foundation
import os

let backgroundLog = Logger(subsystem: "SoundControl", category: "background")

/// Asks iOS to tell the app when a Bluetooth audio device connects or
/// disconnects, even while the app is in the background or not running
/// (with state restoration iOS relaunches it). Each event re-checks the
/// accessory session, which updates the widgets and controls.
final class ConnectionWatcher: NSObject, CBCentralManagerDelegate {
    static let shared = ConnectionWatcher()

    private var central: CBCentralManager?

    /// Audio sink (A2DP), headset (HSP) and hands-free (HFP) services.
    private let audioServices = ["110B", "1108", "111E"].map(CBUUID.init(string:))

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "SoundControlConnections"]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        backgroundLog.notice("Bluetooth state \(central.state.rawValue, privacy: .public)")
        guard central.state == .poweredOn else { return }
        central.registerForConnectionEvents(options: [.serviceUUIDs: audioServices])
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        backgroundLog.notice("Bluetooth state restored")
    }

    func centralManager(
        _ central: CBCentralManager,
        connectionEventDidOccur event: CBConnectionEvent,
        for peripheral: CBPeripheral
    ) {
        backgroundLog.notice("Connection event \(event.rawValue, privacy: .public) for \(peripheral.name ?? "?", privacy: .public)")
        Task { @MainActor in
            let controller = ANCController.shared
            // The accessory list can lag the Bluetooth event slightly.
            for delay in [0.0, 1.5, 4.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                controller.refreshAccessories()
                controller.syncWidgets()
            }
        }
    }
}
