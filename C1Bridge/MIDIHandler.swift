import Foundation
import CoreMIDI

class MIDIHandler {
    private static var client = MIDIClientRef()
    private static var virtualDestination = MIDIEndpointRef()
    private static var currentKeyBase: UInt8 = 0x20

    // MARK: - KEY TABLE
    private static let keyTable: [Int: (name: String, payloadHex: String)] = [
        1:  ("C",  "b11e18010000"), 2:  ("C#", "b11e18010001"),
        3:  ("D",  "b11e18010002"), 4:  ("D#", "b11e18010003"),
        5:  ("E",  "b11e18010004"), 6:  ("F",  "b11e18010005"),
        7:  ("F#", "b11e18010006"), 8:  ("G",  "b11e18010007"),
        9:  ("G#", "b11e18010008"), 10: ("A",  "b11e18010009"),
        11: ("A#", "b11e1801000a"), 12: ("B",  "b11e1801000b")
    ]

    // MARK: - INSTRUMENT MAP (Encrypted payloads)

    /// Maps (MIDI Channel, Program) -> (name, payloadHex)
    ///
    /// The embedded payloads for instruments are typically XOR-encrypted (e.g. `b11e...` becomes `eb44...` when XORed with 0x5A).
    /// We support both formats:
    /// - If payload starts with `b11e` -> treat as *unencrypted* and send via BLEManager.writeSecureHex
    /// - Otherwise -> treat as already encrypted and send as raw hex
    // NOTE: Use concrete type name here (not `Self`) to avoid: “Covariant 'Self' type cannot be referenced from a stored property initializer”.
    private static let instrumentMap: [Int: [Int: (name: String, payloadHex: String)]] = MIDIHandler.buildInstrumentMap()

    private static func buildInstrumentMap() -> [Int: [Int: (name: String, payloadHex: String)]] {
        // CSV columns:
        // instrument,paddle,pattern,liberlive_name,payload_hex,Midi Channel,Midi Program
        let lines = EmbeddedMasterMapping.csv
            .components(separatedBy: .newlines)
            .dropFirst() // header

        var map: [Int: [Int: (name: String, payloadHex: String)]] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 7 else { continue }

            let name = parts[3]
            let payload = parts[4]
            let channel = Int(parts[5]) ?? 0
            let program = Int(parts[6]) ?? 0
            guard channel > 0, program > 0 else { continue }

            var channelMap = map[channel] ?? [:]
            channelMap[program] = (name: name, payloadHex: payload)
            map[channel] = channelMap
        }

        return map
    }

    static func startAdvertising() {
        let s1 = MIDIClientCreateWithBlock("C1BridgeClient" as CFString, &client) { _ in }
        if s1 != noErr {
            AppModel.shared.addLog("MIDI: client create failed (OSStatus=\(s1))")
        } else {
            AppModel.shared.addLog("MIDI: client created")
        }

        let s2 = MIDIDestinationCreateWithBlock(client, "C1 Bridge" as CFString, &virtualDestination) { packetList, _ in
            let packets = packetList.pointee
            var packet = packets.packet
            for _ in 0 ..< packets.numPackets {
                let data = Mirror(reflecting: packet.data).children.prefix(Int(packet.length)).map { $0.value as! UInt8 }
                // This calls the STATIC handler below
                DispatchQueue.main.async { self.handleIncomingMIDI(packet: data) }
                packet = MIDIPacketNext(&packet).pointee
            }
        }
        if s2 != noErr {
            AppModel.shared.addLog("MIDI: destination create failed (OSStatus=\(s2))")
        } else {
            AppModel.shared.addLog("MIDI: destination created (name=\"C1 Bridge\")")
        }
    }

    // MARK: - MAIN PACKET HANDLER
    static func handleIncomingMIDI(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        let status = packet[0]
        let channel = Int(status & 0x0F) + 1
        let program = Int(packet[1]) + 1 // Converts MIDI 0-127 to 1-128
        
        guard (status & 0xF0) == 0xC0 else { return }

        // 1. KEY & CHORD MAPS: Channel 7
        if channel == 7 {
            if program == 128 {
                AppModel.shared.addLog("Trigger: Program 128 - RESET TO DEFAULT")
                resetToDefault()
                return
            }
            
            if program == 13 {
                AppModel.shared.addLog("Trigger: Program 13 - ROCK FLATS")
                applyRockFlats()
                return
            }

            // Standard Key Logic (Programs 1-12)
            if let entry = keyTable[program] {
                currentKeyBase = 0x20 + UInt8(program - 1)
                sendHexWithLog(entry.payloadHex, name: "Key \(entry.name)")
                sendHexWithLog("b11e02010002", name: "Commit Standard")
            }
            // Rock Key Logic (Programs 14-25)
            else if program >= 14 && program <= 25 {
                let basePC = program - 13
                if let entry = keyTable[basePC] {
                    currentKeyBase = 0x20 + UInt8(basePC - 1)
                    sendHexWithLog(entry.payloadHex, name: "Rock Key \(entry.name)")
                    applyRockFlats()
                }
            }
            return
        }

        // 2. INSTRUMENTS: Channels 1-4 (payloads are often encrypted)
        if channel >= 1 && channel <= 4 {
            if let entry = instrumentMap[channel]?[program] {
                AppModel.shared.addLog("TX (Instrument Ch\(channel) P\(program)): \(entry.name) -> \(entry.payloadHex.uppercased())")

                // Instruments in EmbeddedMasterMapping are stored XOR-encrypted (key 0x5A) in many rows (e.g. EB44...).
                // The C1 expects plaintext commands that begin with B11E, so we decode to plaintext before sending.
                let payload = entry.payloadHex.trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.lowercased().hasPrefix("b11e") {
                    BLEManager.shared.writeRawHex(payload, name: "Instrument \(entry.name)")
                } else {
                    let decoded = xorHex(payload, key: 0x5A)
                    AppModel.shared.addLog("TX (Instrument decoded): \(decoded.uppercased())")
                    BLEManager.shared.writeRawHex(decoded, name: "Instrument \(entry.name) (decoded)")
                }
            } else {
                AppModel.shared.addLog("No instrument mapping for Ch\(channel) P\(program)")
            }
            return
        }

        // 3. TEMPO: Channels 5 & 6
        if channel == 5 { sendHexWithLog("b11e1a0200" + String(format: "%02x", program + 39), name: "\(program + 39) BPM") }
        else if channel == 6 { sendHexWithLog("b11e1a0200" + String(format: "%02x", program + 168), name: "\(program + 168) BPM") }
        
        // 4. VOLUME: Channels 8 & 9
        else if (channel == 8 || channel == 9) && program <= 101 {
            let inst = (channel == 8) ? "02" : "03"
            sendHexWithLog("b11e190200" + String(format: "%02x", program - 1) + inst, name: "Vol \(program - 1)%")
        }
        
        // 4. GLOBAL RESET: Channel 10 PC 1
        else if channel == 10 && program == 1 {
            sendHexWithLog("b11e02010002", name: "Global Reset")
        }
    }

    // MARK: - THE MAGIC MAPS
    private static func applyRockFlats() {
        sendHexWithLog("b11e14010002", name: "Unlock")
        sendHexWithLog("b11e02010006", name: "Mode")
        
        let masterMap = "b11e1f1500" +          // Address 15
                        "022242527292b2" +      // Left
                        "002130507080a0" +      // Center (Eb, Ab, Bb)
                        "012040517190b1"        // Right
        
        sendHexWithLog(masterMap, name: "Rock Map Final")
        sendHexWithLog("b11e02010002", name: "Apply All")
    }

    private static func resetToDefault() {
        sendHexWithLog("b11e14010002", name: "Unlock")
        sendHexWithLog("b11e02010006", name: "Mode")
        
        let factoryMap = "b11e1f1500" +
                         "022242527292b2" +
                         "002141507091b0" +
                         "012040517190b1"
        
        sendHexWithLog(factoryMap, name: "Default Map")
        sendHexWithLog("b11e02010002", name: "Apply All")
    }

    private static func xorHex(_ hex: String, key: UInt8) -> String {
        let cleaned = hex
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        guard cleaned.count % 2 == 0 else { return hex }

        var out = ""
        out.reserveCapacity(cleaned.count)

        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let nextIdx = cleaned.index(idx, offsetBy: 2)
            let byteStr = cleaned[idx..<nextIdx]
            guard let byte = UInt8(byteStr, radix: 16) else { return hex }
            out += String(format: "%02x", byte ^ key)
            idx = nextIdx
        }
        return out
    }

    private static func sendHexWithLog(_ hex: String, name: String) {
        AppModel.shared.addLog("TX (\(name)): \(hex.uppercased())")
        BLEManager.shared.writeRawHex(hex, name: name)
    }
}
