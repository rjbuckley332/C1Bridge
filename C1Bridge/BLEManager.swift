import Foundation
import CoreBluetooth
import Combine

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEManager()

    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectedPeripheralName: String? = nil

    /// FRETBOARD TELEMETRY (build 55, decoded from recon 2026-08-16): live
    /// FF01 status bytes for the Beat Setup tab.
    ///   byte[4]  = 7-bit fret-position mask — pos N = value 1<<N
    ///              (pos1=0x02 … pos7=0x80; 0x00 = nothing pressed). Bits can
    ///              combine if the C1 reports multiple positions at once.
    ///   byte[5]  = paddle/velocity — 0x0c while the front paddle is held
    ///              against a fret; 0x40 = mute pad / hard hit.
    ///   byte[12] = note step — key-aware. Key C: pos1–7 read 0,2,4,5,7,9,11
    ///              (C D E F G A B). 0xff = idle.
    ///   byte[13] = note flag — 0/1 per position (meaning TBD). 0xff = idle.
    @Published var fretMask: UInt8 = 0
    @Published var paddleByte: UInt8 = 0
    @Published var noteStepByte: UInt8 = 0xff
    @Published var noteFlagByte: UInt8 = 0xff

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
        rxLogCount = 0
        lastRxKey = nil
        lastRxRepeat = 0
        lastStatusMask = nil
        lastStatusBytes = nil
        beatFlagRiseAt = nil
        lastBeatFlagChangeAt = nil
        lastByte5RiseAt = nil
        pendingMuteTapAt = nil
        paddleStartThisHold = false
        guitarDrumsPlaying = false
        lastTempoByteChangeAt = nil
        pendingTempoFollowAt = nil
        byte5_40RiseAt = nil
        AppModel.shared.addLog("Connected to \(peripheral.name ?? "C1") — RX recon armed")
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
    /// Resets on every connect so recon can't go deaf mid-session. Consecutive
    /// identical packets are collapsed into a "repeated ×N" line — a NEW packet
    /// (like a guitar button press) stands out instead of drowning in keepalives.
    private var rxLogCount = 0
    private let rxLogCap = 3000
    private var lastRxKey: String?
    private var lastRxRepeat = 0
    /// FF01 status-stream diff-watch state (see didUpdateValueFor).
    private var lastStatusMask: [UInt8]?
    private var lastStatusBytes: [UInt8]?
    /// Beat-flag rise timestamp (the beat pad is momentary).
    private var beatFlagRiseAt: Date?
    /// Tap-tempo follow state (build 44): byte[7] change time + debounce mark.
    private var lastTempoByteChangeAt: Date?
    private var pendingTempoFollowAt: Date?
    /// Pulse-width experiment state (build 46): rise time of the current byte[5]
    /// 0x40 pulse, so the fall can log the hold duration in ms — a SLIDE drags
    /// across the pad (long hold) vs a quick TAP, per Rich 14:42 (tap mid-song
    /// = drum transition between the two stored variations; slide = stop with
    /// a closing lick — but the wire sends one identical pulse for each).
    private var byte5_40RiseAt: Date?
    /// Last time the byte[1] beat-alive flag changed. Used to suppress drum-
    /// button false triggers: paddle-starting drums pulses byte[5] (hit
    /// velocities) in the same instant the byte[1] flag flips (recon 2026-08-13).
    private var lastBeatFlagChangeAt: Date?
    /// Last time byte[5] rose to ANY nonzero value. Strum-paddle/drum hits are
    /// velocity pulses (0x0c…), the mute-pad tap is a fixed 0x40 — but a hard
    /// paddle hit CAN also read exactly 0x40 (Rich 2026-08-15: hold beat pad +
    /// paddle killed the beat it just started). Burst detection: a 0x40 that
    /// lands amid other byte[5] pulses, or seconds after a beat-flag rise, is a
    /// paddle hit — NOT a mute tap.
    private var lastByte5RiseAt: Date?
    /// True once a paddle hit / drum-start event has fired during the current
    /// beat-pad hold — i.e. the drums latched this gesture (build 42).
    private var paddleStartThisHold = false
    /// True while we believe the guitar's drums are playing (set on paddle/5b
    /// starts, cleared on slide-stop + connect). Build 47: gates the mute-press
    /// verdict window — a tap (transition) and a slide (stop) send the same
    /// 0x40 pulse, but only a slide is followed by drum-stop EVENT packets
    /// ([2b] 08XX + byte[6] increments, ~2s later after the closing lick).
    private var guitarDrumsPlaying = false
    /// Build 40 forward-guard: a byte[5] 0x40 pulse only stops our beat after
    /// surviving a 0.35s confirmation window with no further flag/pulse
    /// activity (Rich's 5:21 capture showed a 0x40 arriving COLD inside a
    /// start gesture — backward guards can't see a burst that hasn't happened
    /// yet). Newest candidate supersedes any pending one.
    private var pendingMuteTapAt: Date?

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppModel.shared.addLog("RX error \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let rawHex = data.map { String(format: "%02x", $0) }.joined()

        // FF01 14-byte live-status stream: bytes 9-11 are a ticking ASCII
        // counter ("302"→"312"→"322") that floods the log. Suppress the
        // chatter; emit a diff line only when a REAL byte changes — byte 7
        // is tempo (proved: 0x50=80 → 0x82=130), byte 8 (dc↔db) is the
        // suspected beat-state/gesture byte we're hunting.
        if characteristic.uuid.uuidString == "FF01", data.count == 14 {
            let bytes = [UInt8](data)
            // Publish fretboard telemetry on EVERY FF01 frame (guarded assigns
            // make no-change frames free) so the Beat tab never misses state —
            // including the baseline frame that returns early below.
            if fretMask != bytes[4] { fretMask = bytes[4] }
            if paddleByte != bytes[5] { paddleByte = bytes[5] }
            if noteStepByte != bytes[12] { noteStepByte = bytes[12] }
            if noteFlagByte != bytes[13] { noteFlagByte = bytes[13] }
            var masked = bytes
            masked[9] = 0; masked[10] = 0; masked[11] = 0
            let prevMask = lastStatusMask, prevBytes = lastStatusBytes
            lastStatusMask = masked
            lastStatusBytes = bytes
            guard let lastMask = prevMask, let last = prevBytes else {
                AppModel.shared.addLog("FF01 status baseline: \(rawHex)")
                return
            }
            guard masked != lastMask else { return }
            for i in 0..<14 where last[i] != bytes[i] && !(9...11).contains(i) {
                AppModel.shared.addLog("FF01 byte[\(i)]: \(String(format: "%02x", last[i]))→\(String(format: "%02x", bytes[i])) (\(last[i])→\(bytes[i]))")
            }
            // Build 40: full-frame context at every real change — bytes 4/12/13
            // (beat-flash) etc. at each event, for definitive gesture mapping.
            AppModel.shared.addLog("FF01 frame: \(rawHex)")
            // TAP-TEMPO SOURCE (build 44): byte[7] moves when Rich taps the
            // beat pad to retempo the guitar — ride it (debounced inside).
            if last[7] != bytes[7] {
                lastTempoByteChangeAt = Date()
                scheduleTempoFollow(candidate: Int(bytes[7]))
            }
            // TRANSPORT FLASH (build 49): bytes 4/12/13 blip together at some
            // drum transport moments — crucially at the 15:22 drums-STOP inside
            // a mute window (the 08XX packets never came that time), but also
            // at the 15:01 start (no window armed). Inside an armed verdict
            // window it means the slide's stop landed → stop ours. Observed
            // transitions flash nothing (3 samples), so in practice this is
            // slide-specific. Verified: BeatPlayer.stop() sends no BLE, so the
            // 15:01 08XX packets were genuinely guitar-originated.
            if pendingMuteTapAt != nil,
               last[4] != bytes[4] || last[12] != bytes[12] || last[13] != bytes[13] {
                pendingMuteTapAt = nil
                guitarDrumsPlaying = false
                AppModel.shared.addLog("Slide stop — transport flash — stopping DUUDU")
                BeatPlayer.shared.stop()
                StrumPlayer.shared.stop()
            }
            // GUITAR BEAT SYNC (recon 2026-08-13…15): byte[1] bit 0x10 tracks
            // the BEAT PAD being HELD — not the drums' latch state (it falls on
            // pad release even after a paddle start, 5:21 capture). Control
            // model per Rich: START = hold beat pad + hit the strum paddle (the
            // hit assigns/starts the beat); STOP = slide the MUTE PAD (and ONLY
            // that, 12:23); beat-pad TAPS are his TEMPO input (tap-tempo, 12:35)
            // — never a start/stop for ours. Build 44:
            //   rise → arm only (start immediately ONLY if a hit pulse fired in
            //          the last 0.5s — coalesced-frame insurance)
            //   byte[5] hit pulse or 5-byte 02f0000000 drum-start event while
            //          the pad is held → START ours (tempo rules below)
            //   fall → no action for ours (release after a hit-start just logs)
            //   byte[7] change while ours plays → 1s-debounced tap-tempo follow
            //   Tempo on start: a byte[7] that moved WITHIN the gesture window
            //   (<2s) is contamination → banked song tempo wins + reassert; a
            //   stable byte[7] is a deliberate tap → honor + bank it.
            let beatWasSet = (last[1] & 0x10) != 0
            let beatNowSet = (bytes[1] & 0x10) != 0
            if !beatWasSet && beatNowSet {
                lastBeatFlagChangeAt = Date()
                beatFlagRiseAt = Date()
                paddleStartThisHold = false
                // A hit pulse in the last 0.5s means the paddle landed just
                // before the flag registered (coalesced frames) — start now.
                if let lastHit = lastByte5RiseAt, Date().timeIntervalSince(lastHit) < 0.5 {
                    paddleStartThisHold = true
                    guitarDrumsPlaying = true
                    startBeatFromGuitar(guitarBpm: Int(bytes[7]), reason: "paddle start")
                }
            } else if beatWasSet && !beatNowSet {
                lastBeatFlagChangeAt = Date()
                if paddleStartThisHold, BeatPlayer.shared.isPlaying {
                    AppModel.shared.addLog("Beat pad released after paddle start — drums latched, DUUDU stays on")
                }
                // Build 44: taps/holds are TEMPO input only — never a stop or
                // start for ours (Rich 12:35: the tap-stop killed ours when he
                // tapped to bump tempo — "8 bars and it stops").
                paddleStartThisHold = false
            }
            // MUTE PAD TAP 0x40 (Rich 2026-08-15 05:29 correction: "It stopped
            // with the mute button" — the 0x40 source IS the mute pad; build
            // 40's beat-pad attribution was wrong). Strum-paddle hits ride the
            // same byte but are velocity-sensitive (e.g. 0x0c — though a hard
            // hit can read exactly 0x40). A 0x40 rise stops our beat only as
            // an ISOLATED, CONFIRMED press — backward guards:
            //   1. ≥1s since any byte[1] beat-flag change
            //   2. ≥1.5s since the previous byte[5] pulse of ANY value
            //   3. ≥3s since the last beat-flag RISE (hold-then-hit window)
            // …then a forward guard: wait 0.35s; if a flag change or another
            // byte[5] pulse lands in the window it was a gesture burst → abort.
            if last[5] == 0 && bytes[5] != 0 {
                let v = bytes[5]
                let now = Date()
                if beatNowSet {
                    // PADDLE HIT while the beat pad is held = the manual's
                    // "hold beat pad + hit paddle" START (Rich 06:08: the beat
                    // starts when the paddle assigns it, not at pad touch).
                    // First hit per hold starts ours; later hits in the same
                    // hold are just strumming. Also cancels any pending
                    // mute-tap candidate — a 0x40 here is a hard hit, never a
                    // mute tap.
                    pendingMuteTapAt = nil
                    if !paddleStartThisHold {
                        paddleStartThisHold = true
                        guitarDrumsPlaying = true
                        startBeatFromGuitar(guitarBpm: Int(bytes[7]), reason: "paddle start")
                    }
                } else if v == 0x40 {
                    byte5_40RiseAt = now
                    if guitarDrumsPlaying {
                        // MUTE PRESS WITH DRUMS PLAYING (build 51). Rich 15:39:
                        // the mute pad ONLY stops the drums (with a ~1-bar
                        // closing lick). Rich 16:27: OUR side plays a closing
                        // diddy with it — playEndingThenStop() renders a 1-bar
                        // ending figure (starts immediately) and stops the beat
                        // when it completes, riding the guitar's lick. If the
                        // drums' own stop signal (08XX / transport flash) lands
                        // first, those hooks cut straight to the stop. The
                        // cleanup timer just disarms the window afterwards so a
                        // stray late event can't stop some future beat.
                        pendingTempoFollowAt = nil
                        pendingMuteTapAt = now
                        guitarDrumsPlaying = false
                        AppModel.shared.addLog("Mute pad — closing diddy…")
                        BeatPlayer.shared.playEndingThenStop()
                        StrumPlayer.shared.stop()
                        // Backstop: if the diddy's completion ever goes missing,
                        // guarantee the stop ~1 bar + 1s after the press. Silent
                        // when the diddy already stopped us (isPlaying false).
                        let bpm = max(40, BeatPlayer.shared.currentBPM)
                        let bar = 60.0 / Double(bpm) * 4.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + bar + 1.0) { [weak self] in
                            guard let self, self.pendingMuteTapAt == now else { return }
                            self.pendingMuteTapAt = nil
                            if BeatPlayer.shared.isPlaying {
                                AppModel.shared.addLog("Diddy backstop — stopping DUUDU")
                                BeatPlayer.shared.stop()
                            }
                        }
                    } else {
                        // MUTE PRESS WITH DRUMS OFF (13:07-validated): a direct
                        // stop intent for ours. Guards + 0.35s forward-confirm
                        // protect against hard paddle hits reading exactly 0x40.
                        let sinceFlagChange = lastBeatFlagChangeAt.map { now.timeIntervalSince($0) } ?? .infinity
                        let sincePrevPulse = lastByte5RiseAt.map { now.timeIntervalSince($0) } ?? .infinity
                        let sinceRise = beatFlagRiseAt.map { now.timeIntervalSince($0) } ?? .infinity
                        if sinceFlagChange < 1.0 {
                            AppModel.shared.addLog("byte[5] 0x40 ignored — beat flag just changed (paddle-start burst)")
                        } else if sincePrevPulse < 1.5 {
                            AppModel.shared.addLog("byte[5] 0x40 ignored — paddle-hit burst, not a pad press")
                        } else if sinceRise < 3.0 {
                            AppModel.shared.addLog("byte[5] 0x40 ignored — inside hold+paddle start window")
                        } else {
                            pendingMuteTapAt = now
                            AppModel.shared.addLog("byte[5] 0x40 — mute pad press, confirming (0.35s)…")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                                guard let self, self.pendingMuteTapAt == now else { return }
                                self.pendingMuteTapAt = nil
                                let newFlagActivity = self.lastBeatFlagChangeAt.map { $0 > now } ?? false
                                let newPulse = self.lastByte5RiseAt.map { $0 > now } ?? false
                                if newFlagActivity || newPulse {
                                    AppModel.shared.addLog("byte[5] 0x40 stop cancelled — gesture burst followed")
                                } else {
                                    AppModel.shared.addLog("Mute pad confirmed — stopping DUUDU")
                                    BeatPlayer.shared.stop()
                                    StrumPlayer.shared.stop()
                                }
                            }
                        }
                    }
                } else {
                    // STRUM PADDLE HIT (build 76 — Rich: "wire it in so the
                    // front paddle actuates it"): beat pad NOT held and the
                    // pulse isn't a mute-pad 0x40 → the front paddle starts
                    // the strum layer. Hits while it plays are Rich strumming
                    // the C1 — the layer rides (StrumPlayer guards internally).
                    StrumPlayer.shared.paddleHit(guitarBpm: Int(bytes[7]))
                }
                lastByte5RiseAt = now
            }
            // PULSE-WIDTH PROBE (build 46): log how long a 0x40 was held.
            // Hypothesis: slide = long drag, tap = short press. If the widths
            // cluster, build 47 can wire tap=transition (keep playing) vs
            // slide=stop — the two intents the C1 assigns to the mute pad.
            if last[5] == 0x40 && bytes[5] == 0, let riseAt = byte5_40RiseAt {
                let ms = Int(Date().timeIntervalSince(riseAt) * 1000)
                AppModel.shared.addLog("byte[5] 0x40 held for \(ms)ms")
                byte5_40RiseAt = nil
            }
            return
        }

        // DRUM-STOP EVENT (build 47/48): unsolicited FF01 2-byte packets with
        // first byte 0x08 (0846, 0847 — second byte mirrors the byte[6] event
        // counter) follow a mute-pad SLIDE while drums play — never on a
        // transition tap, never when drums are off (15:01 vs 14:49/13:07
        // captures). Build 48: trust the packet whenever drums are believed
        // playing — the 3s verdict window can expire before the closing lick
        // ends at slow tempos, and a late packet must still stop ours.
        if characteristic.uuid.uuidString == "FF01", data.count == 2 {
            let pkt2 = [UInt8](data)
            if pkt2[0] == 0x08 {
                if pendingMuteTapAt != nil || guitarDrumsPlaying {
                    pendingMuteTapAt = nil
                    guitarDrumsPlaying = false
                    AppModel.shared.addLog("Slide stop — drums ended — stopping DUUDU")
                    BeatPlayer.shared.stop()
                    StrumPlayer.shared.stop()
                } else {
                    AppModel.shared.addLog("Drum-stop event 08\(String(format: "%02x", pkt2[1])) — ignored")
                }
            }
        }

        // DRUM-START EVENT (build 42): the discrete 5-byte FF01 packet
        // 02f0000000 fired exactly at the paddle-start moment in the 5:21
        // capture — never at pad-touch alone, never at preset fires. Treat it
        // as a drum start when it lands during/just after a beat-pad hold.
        if characteristic.uuid.uuidString == "FF01", data.count == 5 {
            let pkt = [UInt8](data)
            if pkt == [0x02, 0xf0, 0x00, 0x00, 0x00] {
                let flagActive = (lastStatusBytes?[1] ?? 0) & 0x10 != 0
                let recentFlag = lastBeatFlagChangeAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
                AppModel.shared.addLog("FF01 drum-start event 02f0000000\(flagActive || recentFlag ? "" : " — idle, ignored")")
                if flagActive || recentFlag, !paddleStartThisHold {
                    paddleStartThisHold = true
                    guitarDrumsPlaying = true
                    startBeatFromGuitar(guitarBpm: Int(lastStatusBytes?[7] ?? 0), reason: "drum-start event")
                }
            }
        }

        let key = characteristic.uuid.uuidString + ":" + rawHex
        if key == lastRxKey {
            lastRxRepeat += 1
            return
        }
        if lastRxRepeat > 0 {
            AppModel.shared.addLog("RX \(lastRxKey?.components(separatedBy: ":").first ?? "?") repeated ×\(lastRxRepeat)")
            lastRxRepeat = 0
        }
        lastRxKey = key
        if rxLogCount >= rxLogCap {
            if rxLogCount == rxLogCap {
                AppModel.shared.addLog("RX log cap reached (\(rxLogCap)) — further inbound data suppressed")
                rxLogCount += 1
            }
            return
        }
        rxLogCount += 1
        AppModel.shared.addLog("RX \(characteristic.uuid.uuidString) [\(data.count)b]: \(rawHex)")
        // Printable ASCII? (device info strings etc.)
        if data.allSatisfy({ (0x20...0x7e).contains($0) }) {
            AppModel.shared.addLog("RX ascii \(characteristic.uuid.uuidString): \(String(bytes: data, encoding: .ascii) ?? "")")
        } else {
            let decodedHex = data.map { String(format: "%02x", $0 ^ secretKey) }.joined()
            AppModel.shared.addLog("RX xor5A \(characteristic.uuid.uuidString): \(decodedHex)")
        }
    }

    /// Start our beat from a guitar gesture. Tempo rule (builds 41+44): a
    /// byte[7] that moved WITHIN the gesture window (<2s) is contamination from
    /// the gesture's own pad presses (the beat pad doubles as tap-tempo —
    /// 5:21's 130→51) → the banked song tempo wins and is reasserted on the C1
    /// 0.3s later. A STABLE byte[7] that differs from the bank is a deliberate
    /// tap-tempo Rich set before starting — honor it and bank it as truth.
    private func startBeatFromGuitar(guitarBpm: Int, reason: String) {
        let contaminated = lastTempoByteChangeAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
        var target = guitarBpm
        if MIDIHandler.hasSongTempo, contaminated, MIDIHandler.lastSentTempoBPM != guitarBpm {
            target = MIDIHandler.lastSentTempoBPM
            AppModel.shared.addLog("Guitar \(reason) — song tempo \(target) wins over guitar's tapped \(guitarBpm); reasserting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MIDIHandler.triggerTempo(bpm: target)
            }
        } else if MIDIHandler.lastSentTempoBPM != guitarBpm {
            MIDIHandler.bankExternalTempo(bpm: guitarBpm)
        }
        if BeatPlayer.shared.isPlaying, BeatPlayer.shared.currentBPM == target {
            // Same gesture at the same tempo while already playing = TRANSITION
            // (Rich 15:39: the variation change is beat pad + paddle mid-song —
            // wire-identical to a start). One-bar fill, bar-synced; the loop
            // resumes right after it (Rich 16:27).
            AppModel.shared.addLog("Guitar transition — one-bar fill")
            BeatPlayer.shared.playTransitionFill()
        } else {
            AppModel.shared.addLog("Guitar \(reason) — DUUDU @ \(target) BPM")
            BeatPlayer.shared.start(bpm: target)
        }
    }

    /// Tap-tempo follow (build 44): the beat pad is Rich's tempo input — tapping
    /// it retempos the guitar (byte[7]), and ours rides along. Debounced 1s:
    /// tap-tempo values flutter per tap, preset fires flap the byte before
    /// settling, and our own reassert echoes back in. No-ops when the settled
    /// value is already our current BPM (covers echoes and flaps).
    private func scheduleTempoFollow(candidate: Int) {
        let markedAt = Date()
        pendingTempoFollowAt = markedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.pendingTempoFollowAt == markedAt else { return }
            guard BeatPlayer.shared.isPlaying else { return }
            guard candidate != BeatPlayer.shared.currentBPM else { return }
            AppModel.shared.addLog("Guitar tap-tempo — DUUDU follows @ \(candidate) BPM")
            BeatPlayer.shared.start(bpm: candidate)
            MIDIHandler.bankExternalTempo(bpm: candidate)
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
