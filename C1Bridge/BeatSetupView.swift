import SwiftUI

/// Beat Setup — STAGE 2 (build 55): fretboard-on-screen validation.
///
/// Live decode of the C1's FF01 14-byte status stream (recon 2026-08-16):
///   byte[4]  = 7-bit fret-position mask (pos N = value 1<<N: 0x02…0x80)
///   byte[5]  = paddle/velocity (0x0c while front paddle held against a fret)
///   byte[12] = note step — key-aware (Key C: pos1-7 → 0,2,4,5,7,9,11 = C…B)
///   byte[13] = note flag (0/1 per position; meaning TBD)
///
/// No audio, no looper yet — Rich validates fret detection + latency by FEEL
/// here before any Beat engine gets built (stage 3). If detection proves too
/// insensitive, fallback is a Bluetooth drum pad (Rich 04:20).
struct BeatSetupView: View {
    @ObservedObject private var ble = BLEManager.shared

    private static let pitchNames = ["C", "C#", "D", "D#", "E", "F",
                                     "F#", "G", "G#", "A", "A#", "B"]

    private func isPressed(_ position: Int) -> Bool {
        ble.fretMask & UInt8(1 << position) != 0
    }

    private var pressedPositions: [Int] {
        (1...7).filter { isPressed($0) }
    }

    private var noteGuess: String {
        ble.noteStepByte <= 11 ? Self.pitchNames[Int(ble.noteStepByte)] : "—"
    }

    var body: some View {
        VStack(spacing: 24) {
            if !ble.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("C1 not connected — connect from the Scan button to see live frets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }

            VStack(spacing: 10) {
                Text("FRET POSITIONS")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    ForEach(1...7, id: \.self) { pos in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isPressed(pos) ? Color.green : Color(.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isPressed(pos) ? Color.green.opacity(0.9) : Color.gray.opacity(0.25),
                                                lineWidth: isPressed(pos) ? 2 : 1)
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: 110)
                            Text("\(pos)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(isPressed(pos) ? Color.green : Color.secondary)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.06), value: ble.fretMask)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("Pressed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(pressedPositions.isEmpty
                         ? "—"
                         : pressedPositions.map(String.init).joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                }

                Divider()

                HStack {
                    Text("Note (from guitar)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(noteGuess)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    Text("b12=\(hex(ble.noteStepByte)) b13=\(hex(ble.noteFlagByte))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text("Paddle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ble.paddleByte != 0 ? "ACTIVE" : "—")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundStyle(ble.paddleByte != 0 ? Color.green : Color.primary)
                    Text("b5=\(hex(ble.paddleByte))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text("Raw mask")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("b4=\(hex(ble.fretMask))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)

            Text("Stage 2 validation: press fret positions 1–7 — pads light as the C1 reports them. Detection feel + latency check only; no audio yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding()
    }

    private func hex(_ v: UInt8) -> String {
        String(format: "0x%02x", v)
    }
}

#Preview {
    BeatSetupView()
}
