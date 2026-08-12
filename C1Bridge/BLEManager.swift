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
    private var pendingWrites: [(data: Data, name: String)] = []
    private var writeInFlight = false
    private var hasSentQueuedWrites = false
    private var writeGeneration = 0
    private var currentWriteName: String?
    private var manualDisconnectRequested = false
    /// Set when the user deliberately disconnects; auto-heal stays out of the way until they scan again.
    private var userRequestedDisconnect = false
    private let maxPendingWrites = 64
    private let writeTimeoutSeconds = 1.5

    private override init() {
        super.init()
        // Restore identifier lets iOS relaunch the app and hand back the C1
        // connection if the app is ever terminated while connected.
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "C1BridgeCentral"
        ])
    }

    // MARK: - Manual Disconnect
    func disconnect() {
        userRequestedDisconnect = true
        guard let peripheral = connectedPeripheral else {
            AppModel.shared.addLog("Disconnect failed: No peripheral stored")
            return
        }
        manualDisconnectRequested = true
        // This is the official way to drop the Bluetooth link
        central.cancelPeripheralConnection(peripheral)
        AppModel.shared.addLog("Manual disconnect requested")
    }

    // MARK: - Self-heal
    /// Called on launch and whenever the app becomes active. If the link is down
    /// (and the user didn't deliberately drop it), reconnect on our own: re-pend a
    /// connect if we still hold the peripheral, otherwise scan (scan auto-connects
    /// on discovery). Kills the "install restart / guitar sleep silently stranded me" class.
    func ensureConnected() {
        guard !isConnected, !userRequestedDisconnect else { return }
        if let p = connectedPeripheral {
            AppModel.shared.addLog("Auto-reconnect: re-pending connect to \(p.name ?? "C1")")
            central.connect(p, options: nil)
            return
        }
        guard central.state == .poweredOn else {
            shouldScanWhenPoweredOn = true
            return
        }
        if !isScanning {
            AppModel.shared.addLog("Auto-reconnect: scanning for C1")
            startScan()
        }
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            AppModel.shared.addLog("Bluetooth powered on")
            ensureConnected()
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
        resetWriteQueue()
        AppModel.shared.addLog("Connect failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheralName = nil
        writeCharacteristic = nil
        resetWriteQueue()
        if manualDisconnectRequested {
            manualDisconnectRequested = false
            connectedPeripheral = nil
            AppModel.shared.addLog("Disconnected from C1 (manual)")
            return
        }
        // Unplanned drop (guitar sleep, range, interference): keep the reference and
        // pend a reconnect. CoreBluetooth holds this until the C1 advertises again.
        AppModel.shared.addLog("Disconnected from C1 — auto-reconnect pending")
        connectedPeripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    // MARK: - State Restoration
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let peripheral = peripherals.first else { return }
        AppModel.shared.addLog("BLE state restored for \(peripheral.name ?? "C1")")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            isConnected = true
            connectedPeripheralName = peripheral.name
            peripheral.discoverServices([serviceUUID])
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            AppModel.shared.addLog("Service discovery failed: \(error.localizedDescription)")
            return
        }

        let services = peripheral.services ?? []
        AppModel.shared.addLog("Services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")

        // DIAGNOSTIC RECON: enumerate every characteristic on every service,
        // not just 00FF/FF03. We want the full GATT map — notify pipes,
        // readable config strings, OTA/file-transfer services.
        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            AppModel.shared.addLog("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        for c in service.characteristics ?? [] {
            AppModel.shared.addLog("Char \(service.uuid.uuidString)/\(c.uuid.uuidString): \(describeProperties(c.properties))")
            if c.uuid == writeCharUUID && service.uuid == serviceUUID {
                writeCharacteristic = c
                AppModel.shared.addLog("Ready to write: Found FF03")
                drainWriteQueue()
            }
            // Listen to anything the C1 might say back.
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            // Read anything readable (device info, firmware revision, config).
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppModel.shared.addLog("Subscribe failed \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            AppModel.shared.addLog("Subscribed to \(characteristic.uuid.uuidString)")
        }
    }

    /// Inbound data recon: log everything the C1 sends us, raw and XOR-decoded.
    /// Capped per connection so a chatty characteristic can't flood the Activity log.
    private var rxLogCount = 0
    private let rxLogCap = 500

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppModel.shared.addLog("RX error \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        if rxLogCount >= rxLogCap {
            if rxLogCount == rxLogCap {
                AppModel.shared.addLog("RX log cap reached (\(rxLogCap)) — further inbound data suppressed")
                rxLogCount += 1
            }
            return
        }
        rxLogCount += 1
        let rawHex = data.map { String(format: "%02x", $0) }.joined()
        AppModel.shared.addLog("RX \(characteristic.uuid.uuidString) [\(data.count)b]: \(rawHex)")
        // Printable ASCII? (device info strings etc.)
        if data.allSatisfy({ (0x20...0x7e).contains($0) }) {
            AppModel.shared.addLog("RX ascii \(characteristic.uuid.uuidString): \(String(bytes: data, encoding: .ascii) ?? "")")
        } else {
            let decodedHex = data.map { String(format: "%02x", $0 ^ secretKey) }.joined()
            AppModel.shared.addLog("RX xor5A \(characteristic.uuid.uuidString): \(decodedHex)")
        }
    }

    private func describeProperties(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        if p.contains(.extendedProperties) { out.append("ext") }
        return out.isEmpty ? "none" : out.joined(separator: ",")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppModel.shared.addLog("Write failed: \(error.localizedDescription)")
        }

        writeInFlight = false
        currentWriteName = nil
        drainWriteQueue()
        logReadyForNextSongIfIdle()
    }

    // MARK: - Scanning
    func startScan() {
        userRequestedDisconnect = false
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
        guard connectedPeripheral != nil, writeCharacteristic != nil else {
            AppModel.shared.addLog("Write failed: Not connected")
            return
        }

        pendingWrites.append((data, name))
        if pendingWrites.count > maxPendingWrites {
            let dropped = pendingWrites.removeFirst()
            AppModel.shared.addLog("Dropped queued write: \(dropped.name)")
        }
        drainWriteQueue()
    }

    private func drainWriteQueue() {
        guard !writeInFlight else { return }
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        guard !pendingWrites.isEmpty else { return }

        let next = pendingWrites.removeFirst()
        writeInFlight = true
        hasSentQueuedWrites = true
        currentWriteName = next.name
        writeGeneration += 1
        let generation = writeGeneration
        peripheral.writeValue(next.data, for: characteristic, type: .withResponse)
        AppModel.shared.addLog("Sent: \(next.name)")
        scheduleWriteWatchdog(generation: generation, name: next.name)
    }

    private func resetWriteQueue() {
        pendingWrites.removeAll()
        writeInFlight = false
        hasSentQueuedWrites = false
        currentWriteName = nil
        writeGeneration += 1
    }

    private func logReadyForNextSongIfIdle() {
        guard hasSentQueuedWrites, !writeInFlight, pendingWrites.isEmpty else { return }
        hasSentQueuedWrites = false
        AppModel.shared.addLog("Ready for next song")
    }

    private func scheduleWriteWatchdog(generation: Int, name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + writeTimeoutSeconds) { [weak self] in
            guard let self = self else { return }
            guard self.writeInFlight, self.writeGeneration == generation else { return }

            AppModel.shared.addLog("BLE write stalled: \(self.currentWriteName ?? name). Continuing.")
            self.writeInFlight = false
            self.currentWriteName = nil
            self.drainWriteQueue()
            self.logReadyForNextSongIfIdle()
        }
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
