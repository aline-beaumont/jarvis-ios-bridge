import Foundation
import CoreBluetooth

protocol BluetoothServiceDelegate: AnyObject {
    func bluetoothDidConnect(deviceName: String)
    func bluetoothDidDisconnect()
    func bluetoothDidFail(error: Error)
    func bluetoothStateChanged(available: Bool)
}

class BluetoothService: NSObject {
    weak var delegate: BluetoothServiceDelegate?

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var discoveredPeripherals: [CBPeripheral] = []
    private var isScanning = false

    var connectedDeviceName: String? {
        connectedPeripheral?.name
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        isScanning = true
        discoveredPeripherals.removeAll()
        // Scan for audio devices (A2DP/HFP profiles)
        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // Stop scanning after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.stopScanning()
        }
    }

    func stopScanning() {
        centralManager?.stopScan()
        isScanning = false
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        centralManager?.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    func getDiscoveredDevices() -> [(name: String, peripheral: CBPeripheral)] {
        return discoveredPeripherals.compactMap { peripheral in
            guard let name = peripheral.name, !name.isEmpty else { return nil }
            return (name: name, peripheral: peripheral)
        }
    }
}

extension BluetoothService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let available = central.state == .poweredOn
        delegate?.bluetoothStateChanged(available: available)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        delegate?.bluetoothDidConnect(deviceName: peripheral.name ?? "Unknown")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        delegate?.bluetoothDidDisconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let err = error ?? NSError(domain: "Bluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect"])
        delegate?.bluetoothDidFail(error: err)
    }
}
