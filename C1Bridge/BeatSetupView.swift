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
    @ObservedObject private var beatLibrary = BeatLibrary.shared
    @State private var showSaveAlert = false
    @State private var beatNameInput = ""
    @State private var flashPositions = Set<Int>()
    @State private var showRowDeleteAlert = false
    @State private var rowPendingDelete = 0

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
                myBeatsSection
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
            Text("FRET POSITIONS — TAP TO PLAY")
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                ForEach(1...7, id: \.self) { pos in
                    Button {
                        flashPositions.insert(pos)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            flashPositions.remove(pos)
                        }
                        looper.tap(position: pos)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(padLit(pos) ? Color.green : Color(.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(padLit(pos) ? Color.green.opacity(0.9) : Color.gray.opacity(0.25),
                                                lineWidth: padLit(pos) ? 2 : 1)
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: 80)
                            Text("\(pos)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(padLit(pos) ? Color.green : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.easeOut(duration: 0.06), value: ble.fretMask)
        }
    }

    /// Pad lights for EITHER input: the C1's live fret mask, or a brief flash
    /// on screen taps (the tap itself always sounds its voice instantly).
    private func padLit(_ pos: Int) -> Bool {
        isPressed(pos) || flashPositions.contains(pos)
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

            // Mic capture (Rich 08:42: "just one layer with a separate button")
            HStack(spacing: 10) {
                Button { looper.micCapturing ? looper.stopMicCapture() : looper.startMicCapture() } label: {
                    Label(looper.micCapturing ? "Stop Mic" : "Mic Beat",
                          systemImage: looper.micCapturing ? "mic.fill" : "mic")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(looper.micCapturing ? .red : .purple)

                Menu {
                    Button("Auto — each new sound gets its own row") { looper.micAutoRow = true }
                    ForEach(1...7, id: \.self) { pos in
                        Button("Force pos \(pos) — \((looper.voiceForPosition[pos] ?? .kick).rawValue)") { looper.micAutoRow = false; looper.micArmedPosition = pos }
                    }
                } label: {
                    Text(looper.micAutoRow ? "auto rows" : "plays pos \(looper.micArmedPosition)")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.purple.opacity(0.12)).cornerRadius(6)
                }

                Text(looper.micCapturing
                     ? "speaker muted — your sounds become the beat (dot edits stay silent while the mic is on)"
                     : (looper.micAutoRow
                        ? "auto: each new sound claims its own row — purple dots are your recordings"
                        : "forced row: every captured sound lands on the picked position"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Save (stage 4 — beat menu)
            Button { beatNameInput = ""; showSaveAlert = true } label: {
                Label("Save Beat…", systemImage: "square.and.arrow.down")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(looper.hits.isEmpty)

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
                        // Builds 68/70: a MIC row shows 🎤 — and its identity
                        // lives in rowSounds, NOT in its dots, so clearing
                        // every dot no longer evaporates the row (Rich 08:18).
                        // Long-press the label to delete/clear the row on purpose.
                        Group {
                            if looper.rowSounds[pos] != nil {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(Color.purple)
                            } else {
                                Text((looper.voiceForPosition[pos] ?? .kick).abbrev)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .frame(width: 16, alignment: .leading)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            rowPendingDelete = pos
                            showRowDeleteAlert = true
                        }
                        ForEach(0..<LooperEngine.stepsPerBar, id: \.self) { step in
                            Circle()
                                .fill(cellColor(pos, step))
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .contentShape(Rectangle())   // fat-finger slop: whole slot taps
                                .onTapGesture { looper.toggleHit(position: pos, step: step) }
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
                // Build 66: the dots ARE the editor — Rich 05:48 "too fast to
                // press the fret or button". Tap to place/remove; no timing needed.
                Text("tap a dot to place or remove a hit — 🎤 rows stamp their recorded sound")
                Text("long-press a row's label to delete the row")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .alert("Name this beat", isPresented: $showSaveAlert) {
            TextField("e.g. Rock groove", text: $beatNameInput)
            Button("Save") {
                let name = beatNameInput.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                beatLibrary.add(looper.snapshot(name: name), samplePayloads: looper.samplePayloads())
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the loop + voice assignments. Reusing a name overwrites — songs attached to that name get the update.")
        }
        .alert(looper.rowSounds[rowPendingDelete] != nil
               ? "Delete mic row \(rowPendingDelete)?"
               : "Clear row \(rowPendingDelete)?",
               isPresented: $showRowDeleteAlert) {
            Button(looper.rowSounds[rowPendingDelete] != nil ? "Delete" : "Clear", role: .destructive) {
                looper.deleteRow(rowPendingDelete)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(looper.rowSounds[rowPendingDelete] != nil
                 ? "Removes its dots and forgets its recorded sound."
                 : "Removes all dots on this row.")
        }
    }

    // MARK: - My Beats (stage 4 — the beat menu)

    private var myBeatsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("MY BEATS")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("attach: Song Setup → Beat style")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if beatLibrary.beats.isEmpty {
                Text("No saved beats yet — build a loop above, then Save Beat. Saved beats appear in Song Setup's Beat style picker and perform at the song's tempo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(beatLibrary.beats) { beat in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(beat.name)
                                .font(.subheadline).fontWeight(.semibold)
                            Text("\(beat.bpm) BPM · \(beat.hits.count) hit(s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { looper.load(beat) } label: { Text("Load").font(.caption) }
                            .buttonStyle(.bordered)
                        Button { looper.load(beat); looper.start() } label: {
                            Image(systemName: "play.fill").font(.caption)
                        }
                        .buttonStyle(.bordered).tint(.green)
                        Button(role: .destructive) { beatLibrary.delete(beat) } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.bordered).tint(.red)
                    }
                    if beat.id != beatLibrary.beats.last?.id { Divider() }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private var statusText: String {
        if looper.isPerforming { return "Performing \"\(looper.performingName ?? "")\" — frets muted" }
        if !looper.isRunning {
            return looper.hits.isEmpty
                ? "Stopped — tap dots to place hits, or a pad/fret to start (first tap = beat 1)"
                : "Stopped — \(looper.hits.count) hit(s) kept; dots edit, a pad restarts on your downbeat"
        }
        if looper.currentBar < looper.countInBars { return "Count-in…" }
        return "Bar \(looper.currentBar + 1 - looper.countInBars) — recording • \(looper.hits.count) hit(s)"
    }

    private func hasSampleHit(_ position: Int, _ step: Int) -> Bool {
        looper.hits.contains { $0.position == position && $0.step == step && $0.sampleID != nil }
    }

    private func cellColor(_ pos: Int, _ step: Int) -> Color {
        // Build 67: purple = captured mic sound, green = synth voice.
        if hasHit(pos, step) { return hasSampleHit(pos, step) ? .purple : .green }
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
