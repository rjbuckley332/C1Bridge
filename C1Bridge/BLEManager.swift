import Foundation
import CoreBluetooth
import Combine

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEManager()

    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectedPeripheralName: String? = nil

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private let serviceUUID = CBUUID(string: "00FF")
    private let writeCharUUID = CBUUID(string: "FF03")
    private var writeCharacteristic: CBCharacteristic?
    private var shouldScanWhenPoweredOn = false
    private let secretKey: UInt8 = 0x5A

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Manual Disconnect
    func disconnect() {
        guard let peripheral = connectedPeripheral else {
            AppModel.shared.addLog("Disconnect failed: No peripheral stored")
            return
        }
        // This is the official way to drop the Bluetooth link
        central.cancelPeripheralConnection(peripheral)
        AppModel.shared.addLog("Manual disconnect requested")
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            AppModel.shared.addLog("Bluetooth powered on")
            if shouldScanWhenPoweredOn {
                startScan()
            }
        case .poweredOff:
            isConnected = false
            isScanning = false
            AppModel.shared.addLog("Bluetooth powered off")
        case .unauthorized:
            isConnected = false
            isScanning = false
            AppModel.shared.addLog("Bluetooth permission denied")
        case .unsupported:
            isConnected = false
            isScanning = false
            AppModel.shared.addLog("Bluetooth unsupported on this device")
        default:
            isConnected = false
            isScanning = false
            AppModel.shared.addLog("Bluetooth unavailable: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let displayName = advertisedName ?? peripheral.name ?? "Unknown"
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasC1Name = isLikelyC1Name(displayName)
        let advertisesC1Service = advertisedServices.contains(serviceUUID)

        if hasC1Name || advertisesC1Service {
            AppModel.shared.addLog("Found BLE device: \(displayName), RSSI \(RSSI)")
            connectedPeripheral = peripheral
            peripheral.delegate = self
            stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedPeripheralName = peripheral.name
        AppModel.shared.addLog("Connected to \(peripheral.name ?? "C1")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        isConnected = false
        AppModel.shared.addLog("Connect failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheralName = nil
        writeCharacteristic = nil
        // We clear the reference so we can connect fresh next time
        connectedPeripheral = nil
        AppModel.shared.addLog("Disconnected from C1")
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            AppModel.shared.addLog("Service discovery failed: \(error.localizedDescription)")
            return
        }

        let services = peripheral.services ?? []
        AppModel.shared.addLog("Services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")

        if let services = peripheral.services {
            for service in services where service.uuid == serviceUUID {
                peripheral.discoverCharacteristics([writeCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            AppModel.shared.addLog("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        AppModel.shared.addLog("Characteristics for \(service.uuid.uuidString): \((service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")

        for c in service.characteristics ?? [] {
            if c.uuid == writeCharUUID {
                writeCharacteristic = c
                AppModel.shared.addLog("Ready to write: Found FF03")
            }
        }
    }

    // MARK: - Scanning
    func startScan() {
        shouldScanWhenPoweredOn = true
        guard central.state == .poweredOn else {
            AppModel.shared.addLog("Scan waiting for Bluetooth: \(central.state.rawValue)")
            return
        }
        isScanning = true
        AppModel.shared.addLog("Scanning for C1 BLE devices")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        shouldScanWhenPoweredOn = false
        central.stopScan()
        isScanning = false
        AppModel.shared.addLog("Scan stopped")
    }

    // MARK: - MIDI Writing
    func writeSecureHex(_ hexString: String, name: String) {
        guard let rawData = hexStringToData(hexString) else { return }
        let secureData = Data(rawData.map { $0 ^ secretKey })
        writeToHardware(secureData, name: "Secure \(name)")
    }

    func writeRawHex(_ hexString: String, name: String) {
        guard let rawData = hexStringToData(hexString) else { return }
        writeToHardware(rawData, name: "Raw \(name)")
    }

    private func writeToHardware(_ data: Data, name: String) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else {
            AppModel.shared.addLog("Write failed: Not connected")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        AppModel.shared.addLog("Sent: \(name)")
    }

    private func hexStringToData(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").lowercased()
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        for _ in 0..<(cleaned.count / 2) {
            let nextIdx = cleaned.index(idx, offsetBy: 2)
            if let byte = UInt8(cleaned[idx..<nextIdx], radix: 16) {
                data.append(byte)
            }
            idx = nextIdx
        }
        return data
    }

    private func isLikelyC1Name(_ name: String) -> Bool {
        let candidates = ["liberlive", "c1", "c1 guitar", "midi"]
        return candidates.contains { name.localizedCaseInsensitiveContains($0) }
    }
}
