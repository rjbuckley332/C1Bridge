import SwiftUI

/// Chord-table editor (build 116): list-style learn interface for the 21
/// pad → chord cells (7 fret positions × 3 rows). Build 136: the row IS the
/// chord type (add9 / Major / minor) and each pad's Flat/Natural/Sharp is
/// its root data (Rich 2026-10-07) — no absolute note names anywhere.
struct ChordTablesView: View {
    @ObservedObject private var library = ChordTableLibrary.shared
    @State private var table = ChordTable.starter(name: "(new)")
    @State private var loadedName: String? = nil
    @State private var showSaveAlert = false
    @State private var nameInput = ""
    @State private var editingCell: Int? = nil
    @State private var learnCell: Int? = nil
    @State private var editAccidental: Accidental = .natural
    @State private var editQuality: ChordAssignment.Quality = .major
    @State private var editLocked = false
    @State private var programNumber: Int = 1

    var body: some View {
        Form {
            // MARK: - Table management

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Factory Default is always the first chip (Rich
                        // 2026-10-07) — tap loads the official grid into the
                        // working copy; →C1 writes it to the guitar live.
                        mapChip(name: "Factory Default", isLoaded: loadedName == nil) {
                            table = ChordTable.starter(name: "(new)")
                            loadedName = nil
                        } send: {
                            MIDIHandler.sendChordMapToC1(ChordTable.starter(name: "Factory Default"))
                        }
                        ForEach(library.tables) { t in
                            mapChip(name: t.name, isLoaded: loadedName == t.name) {
                                loadTable(t)
                            } send: {
                                MIDIHandler.sendChordMapToC1(t)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 12) {
                    // Send to C1 = write the working copy (Factory Default or
                    // a loaded map, edits included) to the guitar in real time
                    // (Rich 2026-10-07). Per-chip →C1 buttons send without loading.
                    Button {
                        MIDIHandler.sendChordMapToC1(table)
                    } label: {
                        Label("Send to C1", systemImage: "guitars")
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)

                    Spacer()

                    Button {
                        nameInput = loadedName ?? ""
                        showSaveAlert = true
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Button {
                        library.delete(table)
                        table = ChordTable.starter(name: "(new)")
                        loadedName = nil
                        AppModel.shared.addLog("Chord table deleted")
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .fontWeight(.semibold)
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(loadedName == nil)
                }

                Stepper("MIDI program: PC \(programNumber) · Ch 10", value: Binding(
                    get: { programNumber },
                    set: { newValue in
                        programNumber = newValue
                        if loadedName != nil {
                            table.midiChannel = 10
                            table.midiProgram = newValue
                            persistIfLoaded()
                        }
                    }
                ), in: 1...128)
            } header: {
                Text(loadedName != nil ? "Table — \(loadedName!)\(midiSuffix)" : "Factory Default (unsaved)")
            } footer: {
                Text("Factory Default is the official grid — change anything and Save… names it as a custom map. Tap a map to load it; edits to a loaded map stick automatically. →C1 writes a map straight to the guitar in real time (a banked tempo is re-sent after). Delete removes the current map.")
            }

            // MARK: - 21 cells

            Section {
                ForEach(0..<21, id: \.self) { i in
                    cellRow(displayIndex: i)
                }
            } header: {
                Text("Pad assignments — \(table.cells.filter { $0 != nil }.count)/21 assigned")
            } footer: {
                Text("Rows run in the guitar's physical order, top pad first: Variant, Diatonic, 7th — matching the official app's left-to-right columns. Every pad is editable: root (Flat/Natural/Sharp) and type (7/M/m/m7/maj7/add9). Tap a row to edit; tap Learn to bind a physical pad. →C1 sends key-first (the proven Rock-Key flow).")
            }

            // MARK: - C1 Lab (Rich 2026-10-08: the nibble probe)
            Section {
                Button {
                    MIDIHandler.sendFlagProbe()
                } label: {
                    Label("Send flag probe (all C · flags 1–15)", systemImage: "waveform")
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            } header: {
                Text("C1 Lab")
            } footer: {
                Text("Every pad plays a C — only the flavor changes. Bottom pads = plain C major (your reference). Middle pads frets 1–7 = flags 1–7 (fret 1 should be sad Cm, fret 2 bluesy C7 — known anchors). Top pads frets 1–7 = flags 8–14. Bottom fret 7 = flag 15. Play and describe each flavor in your own words. Restore afterwards with any map's →C1.")
            }
        }
        .navigationTitle("Chords")
        .alert("Save chord table", isPresented: $showSaveAlert) {
            TextField("Table name", text: $nameInput)
            Button("Save", action: saveCurrent)
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: Binding(
            get: { editingCell != nil },
            set: { if !$0 { editingCell = nil } }
        )) {
            chordPickerView
        }
        .onDisappear {
            StrumPlayer.shared.padLearnHandler = nil
            learnCell = nil
        }
    }

    // MARK: - Cell row

    /// Display order (Rich 2026-10-07): on the physical C1 the fret's TOP pad
    /// is the official app's LEFT column (Variant); the bottom pad is the 7th.
    /// The list runs in that physical order — Variant, Diatonic, 7th.
    /// STORAGE stays wire-ordered (byte-row 0 = 7th); only the view flips.
    private static let displayRowLabels = ["Variant", "Diatonic", "7th"]
    /// Display index (0…20, position-major, physical top→bottom) →
    /// wire-ordered cell index (byte-row 0 = 7th).
    private func cellIndex(displayIndex d: Int) -> Int {
        (d / 3) * 3 + (2 - (d % 3))
    }

    @ViewBuilder
    private func cellRow(displayIndex d: Int) -> some View {
        let cellIndex = cellIndex(displayIndex: d)
        let cell = table.cells[cellIndex]
        let pos = d / 3 + 1
        let row = Self.displayRowLabels[d % 3]
        let label = "\(pos) \(row)"

        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .frame(width: 72, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(cell.map { $0.accidentalWord } ?? "—")
                    .font(.system(size: 14))

                if let ca = cell {
                    let sig = ca.signature.map { String(format: "%08X", $0) } ?? "—"
                    let noteName = ca.learnedNotePC.map { ChordAssignment.pcNames[$0] } ?? "—"
                    Text("\(ca.name(position: pos)) · \(noteName) · \(sig)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                learnCell = cellIndex
                StrumPlayer.shared.padLearnHandler = { [cellIndex, pos, row, _table] sig, notePC in
                    let existing = _table.wrappedValue.cells[cellIndex]
                    let newAssignment = ChordAssignment(
                        signature: sig,
                        accidental: existing?.accidental ?? 0,
                        quality: existing?.quality ?? ChordTable.factoryQuality(position: cellIndex / 3 + 1, row: cellIndex % 3),
                        learnedNotePC: notePC < 12 ? Int(notePC) : nil,
                        locked: existing?.locked ?? nil
                    )
                    _table.wrappedValue.cells[cellIndex] = newAssignment
                    if _loadedName.wrappedValue != nil {
                        ChordTableLibrary.shared.add(_table.wrappedValue, log: false)
                    }
                    _learnCell.wrappedValue = nil
                    StrumPlayer.shared.padLearnHandler = nil
                    AppModel.shared.addLog(String(format: "Learned pad → %d %@ (sig %08X)", pos, row, sig))
                    return true
                }
            } label: {
                Text("Learn")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(learnCell == cellIndex ? Color.yellow : Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingCell = cellIndex
        }
        .foregroundColor(learnCell == cellIndex ? .yellow : .primary)
    }

    /// One map chip: tap the name to load, tap →C1 to write it straight
    /// to the guitar in real time (Rich 2026-10-07).
    @ViewBuilder
    private func mapChip(name: String, isLoaded: Bool, load: @escaping () -> Void, send: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: load) {
                Text(name)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isLoaded ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundStyle(isLoaded ? .white : .primary)
                    .cornerRadius(12)
            }
            Button(action: send) {
                Text("→C1")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    /// Flat/Natural/Sharp — the pad's root data. The fret supplies the
    /// degree note; this shifts it one semitone (Rich 2026-10-07).
    private enum Accidental: String, CaseIterable, Identifiable {
        case flat = "♭"
        case natural = "♮"
        case sharp = "♯"
        var id: String { rawValue }
        var offset: Int { self == .flat ? -1 : (self == .sharp ? 1 : 0) }
        init?(offset: Int) {
            switch offset {
            case -1: self = .flat
            case 0:  self = .natural
            case 1:  self = .sharp
            default: return nil
            }
        }
    }

    /// Preview chord name (C-reference) for the sheet's current picks.
    private var previewName: String {
        let pos = (editingCell ?? 0) / 3 + 1
        let root = (ChordTable.degreeRoots[pos - 1] + editAccidental.offset + 12) % 12
        return ChordAssignment.pcNames[root] + editQuality.suffix
    }

    // MARK: - Chord picker (sheet)

    private var chordPickerView: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Flat / Natural / Sharp", selection: $editAccidental) {
                        ForEach(Accidental.allCases) { acc in
                            Text(acc.rawValue).tag(acc)
                        }
                    }
                    .pickerStyle(.wheel)
                } header: {
                    Text("Root — Flat / Natural / Sharp")
                } footer: {
                    Text("This IS the pad's root data: the fret sets the degree note, Flat/Natural/Sharp shifts it one semitone. The result transposes with the song key.")
                }

                Section {
                    Picker("Chord type", selection: $editQuality) {
                        ForEach(ChordAssignment.Quality.allCases, id: \.self) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.wheel)
                } header: {
                    Text("Chord type")
                } footer: {
                    Text("The official six: 7 / M / m / m7 / maj7 / add9. Flags 0/1/2 are proven (M/m/7); m7/maj7/add9 ride guessed flags 3/4/5 — if a pad sounds like a different type than you picked, tell Alfred and the flag gets swapped.")
                }

                // Build 118: key-lock toggle
                Section {
                    Toggle("Key-locked (never transpose)", isOn: $editLocked)
                        .font(.subheadline)
                } header: {
                    Text("Transposition")
                } footer: {
                    Text("Locked chords stay at their authored pitch (pedal tones). Unlocked chords transpose with the song key.")
                }

                Section {
                    HStack {
                        Text("Assigned chord")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(previewName)
                            .fontWeight(.medium)
                    }
                } header: {
                    Text("Preview (key of C)")
                }
            }
            .navigationTitle(editingCell.map { "\($0 / 3 + 1) \(Self.displayRowLabels[2 - ($0 % 3)])" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editingCell = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChord() }
                }
            }
        }
        .onAppear {
            if let cell = editingCell.flatMap({ table.cells[$0] }) {
                editAccidental = Accidental(offset: cell.accidental) ?? .natural
                editQuality = cell.quality
                editLocked = cell.locked == true
            } else {
                editAccidental = .natural
                editQuality = ChordTable.factoryQuality(position: (editingCell ?? 0) / 3 + 1, row: (editingCell ?? 0) % 3)
                editLocked = false
            }
        }
    }

    // MARK: - Actions

    /// " · Ch10 PC5" style suffix for the section header — built outside
    /// the ViewBuilder so bare if-statements don't break the build.
    private var midiSuffix: String {
        var s = ""
        if let ch = table.midiChannel { s += " · Ch\(ch)" }
        if let pc = table.midiProgram { s += " PC\(pc)" }
        return s
    }

    private func loadTable(_ t: ChordTable) {
        table = t
        loadedName = t.name
        programNumber = t.midiProgram ?? 1
    }

    private func saveCurrent() {
        let name = nameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        table.name = name
        table.midiChannel = 10
        table.midiProgram = programNumber
        library.add(table)
        loadedName = name
        nameInput = ""
    }

    private func saveChord() {
        guard let i = editingCell else { return }
        table.cells[i] = ChordAssignment(
            signature: table.cells[i]?.signature,
            accidental: editAccidental.offset,
            quality: editQuality,
            learnedNotePC: table.cells[i]?.learnedNotePC,
            locked: editLocked ? true : nil
        )
        persistIfLoaded()
        editingCell = nil
    }

    /// Auto-persist (Rich 2026-10-06): when a named table is loaded, every
    /// mutation writes straight back to the library so edits stick without an
    /// explicit Save…. Name-is-identity upsert in add() does the update.
    private func persistIfLoaded() {
        guard loadedName != nil else { return }
        library.add(table, log: false)
    }
}
