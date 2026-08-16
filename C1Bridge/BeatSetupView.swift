import SwiftUI

/// Beat Setup — STAGE 2+3 (builds 55/56).
///
/// Stage 2 (build 55): fretboard-on-screen validation — live FF01 decode:
///   byte[4]  = 7-bit fret-position mask (pos N = value 1<<N: 0x02…0x80)
///   byte[5]  = paddle/velocity (0x0c while front paddle held against a fret)
///   byte[12] = note step — key-aware (Key C: pos1-7 → 0,2,4,5,7,9,11 = C…B)
///   byte[13] = note flag (0/1 per position; meaning TBD)
/// Rich validated 04:38: latency quick, sensitive, no false triggers.
///
/// Stage 3 (build 56): TEST MODE looper (Rich 04:17 — tap a beat, hear it
/// back, nothing saved). One-bar 16th-note grid, count-in click, overdub
/// per pass, undo-last-pass, clear. Voices user-assignable per position.
struct BeatSetupView: View {
    @ObservedObject private var ble = BLEManager.shared
    @ObservedObject private var looper = LooperEngine.shared

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

    private func hasHit(_ position: Int, _ step: Int) -> Bool {
        looper.hits.contains { $0.position == position && $0.step == step }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !ble.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("C1 not connected — connect from the Scan button to play.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }

                fretboardSection
                telemetrySection
                testModeSection
            }
            .padding()
        }
        .onChange(of: ble.fretMask) { _, new in
            looper.fretMaskChanged(new)
        }
        .onChange(of: looper.bpm) { _, _ in
            // Tempo change mid-run: restart the transport, keep the hits.
            if looper.isRunning { looper.start() }
        }
    }

    // MARK: - Fretboard (stage 2 validation)

    private var fretboardSection: some View {
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
                            .frame(height: 80)
                        Text("\(pos)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(isPressed(pos) ? Color.green : Color.secondary)
                    }
                }
            }
            .animation(.easeOut(duration: 0.06), value: ble.fretMask)
        }
    }

    // MARK: - Telemetry readouts (stage 2 validation)

    private var telemetrySection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Pressed").foregroundStyle(.secondary)
                Spacer()
                Text(pressedPositions.isEmpty
                     ? "—"
                     : pressedPositions.map(String.init).joined(separator: ", "))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            }
            Divider()
            HStack {
                Text("Note (from guitar)").foregroundStyle(.secondary)
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
                Text("Paddle").foregroundStyle(.secondary)
                Spacer()
                Text(ble.paddleByte != 0 ? "ACTIVE" : "—")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(ble.paddleByte != 0 ? Color.green : Color.primary)
                Text("b5=\(hex(ble.paddleByte))  b4=\(hex(ble.fretMask))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - Test mode looper (stage 3)

    private var testModeSection: some View {
        VStack(spacing: 14) {
            HStack {
                Text("TEST MODE")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("nothing is saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Tempo
            HStack {
                Text("Tempo").foregroundStyle(.secondary)
                Spacer()
                Button { looper.bpm = max(50, looper.bpm - 5) } label: {
                    Image(systemName: "minus.circle.fill").font(.title3)
                }
                Text("\(looper.bpm) BPM")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .frame(width: 86)
                Button { looper.bpm = min(200, looper.bpm + 5) } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
            }

            // Voice assignment (one picker per position, aligned with the pads)
            VStack(spacing: 6) {
                Text("VOICES (tap to assign)")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    ForEach(1...7, id: \.self) { pos in
                        Menu {
                            ForEach(LooperEngine.Voice.allCases) { voice in
                                Button(voice.rawValue) { looper.voiceForPosition[pos] = voice }
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(pos)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text((looper.voiceForPosition[pos] ?? .kick).abbrev)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.12))
                                    .cornerRadius(6)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            // Transport
            HStack(spacing: 12) {
                Button { looper.isRunning ? looper.stop() : looper.start() } label: {
                    Label(looper.isRunning ? "Stop" : "Start",
                          systemImage: looper.isRunning ? "stop.fill" : "play.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(looper.isRunning ? .red : .green)

                Button { looper.undoLastPass() } label: { Text("Undo") }
                    .buttonStyle(.bordered)
                    .disabled(looper.hits.isEmpty)

                Button { looper.clear() } label: { Text("Clear") }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(looper.hits.isEmpty)

                Toggle("Click", isOn: $looper.clickOn)
                    .font(.caption)
                    .frame(width: 92)
            }

            // Status line
            HStack {
                Circle()
                    .fill(looper.recordingArmed ? Color.red : (looper.isRunning ? Color.orange : Color.gray))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Loop grid: 7 positions × 16 steps, playhead column highlighted
            VStack(spacing: 4) {
                ForEach(1...7, id: \.self) { pos in
                    HStack(spacing: 4) {
                        Text((looper.voiceForPosition[pos] ?? .kick).abbrev)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .leading)
                        ForEach(0..<LooperEngine.stepsPerBar, id: \.self) { step in
                            Circle()
                                .fill(cellColor(pos, step))
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text("").frame(width: 16)
                    ForEach(0..<LooperEngine.stepsPerBar, id: \.self) { step in
                        Text(step % 4 == 0 ? "\(step / 4 + 1)" : "·")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private var statusText: String {
        if !looper.isRunning {
            return looper.hits.isEmpty ? "Stopped — press Start, tap frets on the click"
                                       : "Stopped — \(looper.hits.count) hit(s) in loop"
        }
        if looper.currentBar == 0 { return "Count-in…" }
        return "Bar \(looper.currentBar) — recording • \(looper.hits.count) hit(s)"
    }

    private func cellColor(_ pos: Int, _ step: Int) -> Color {
        if hasHit(pos, step) { return .green }
        if looper.isRunning, step == looper.currentStep, looper.currentBar >= 0 {
            return step % 4 == 0 ? Color.blue.opacity(0.45) : Color.blue.opacity(0.2)
        }
        return step % 4 == 0 ? Color.gray.opacity(0.28) : Color.gray.opacity(0.15)
    }

    private func hex(_ v: UInt8) -> String {
        String(format: "0x%02x", v)
    }
}

#Preview {
    BeatSetupView()
}
