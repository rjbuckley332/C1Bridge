import SwiftUI

/// Chord-table editor (build 116): list-style learn interface for the 21
/// pad → chord cells (7 fret positions × 3 rows A/B/C). No grid — a clean
/// scrollable list matching the StrumBeatsView house style.
struct ChordTablesView: View {
    @ObservedObject private var library = ChordTableLibrary.shared
    @State private var table = ChordTable.starter(name: "(new)")
    @State private var loadedName: String? = nil
    @State private var showSaveAlert = false
    @State private var nameInput = ""
    @State private var editingCell: Int? = nil
    @State private var learnCell: Int? = nil
    @State private var editRoot = 0
    @State private var editQuality: ChordAssignment.Quality = .major
    @State private var editLocked = false
    @State private var programNumber: Int = 1

    var body: some View {
        Form {
            // MARK: - Table management

            Section {
                if !library.tables.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(library.tables) { t in
                                Button {
                                    loadTable(t)
                                } label: {
                                    Text(t.name)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(loadedName == t.name ? Color.accentColor : Color(.secondarySystemBackground))
                                        .foregroundStyle(loadedName == t.name ? .white : .primary)
                                        .cornerRadius(12)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack(spacing: 12) {
                    Menu {
                        Button("Factory grid") {
                            table = ChordTable.starter(name: "(new)")
                            loadedName = nil
                        }
                        Button("Rock Flats grid") {
                            table = ChordTable.rockFlats(name: "(new)")
                            loadedName = nil
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

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
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(loadedName == nil)
                }

                Stepper("MIDI program: PC \(programNumber) · Ch 10", value: $programNumber, in: 1...128)
            } header: {
                Text(loadedName != nil ? "Table — \(loadedName!)\(midiSuffix)" : "No table loaded")
            } footer: {
                Text("Tap a saved table to load it, New for a blank slate, Save… to write to the library, Delete to remove the current table. (Re-saving a name updates every song that references it.)")
            }

            // MARK: - 21 cells

            Section {
                ForEach(0..<21, id: \.self) { i in
                    cellRow(index: i)
                }
            } header: {
                Text("Pad assignments — \(table.cells.filter { $0 != nil }.count)/21 assigned")
            } footer: {
                Text("Tap a row to edit its chord assignment. Tap Learn to bind a physical pad. The learned note (byte[12]) shifts with key but the pad signature (bytes 2,3,4,13) is stable.")
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

    @ViewBuilder
    private func cellRow(index cellIndex: Int) -> some View {
        let cell = table.cells[cellIndex]
        let pos = cellIndex / 3 + 1
        let row = ChordTable.rowLabels[cellIndex % 3]
        let label = "\(pos)\(row)"

        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .frame(width: 40, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(cell.map { $0.name } ?? "—")
                    .font(.system(size: 14))

                if let ca = cell {
                    let sig = ca.signature.map { String(format: "%08X", $0) } ?? "—"
                    let noteName = ca.learnedNotePC.map { ChordAssignment.pcNames[$0] } ?? "—"
                    Text("\(noteName) · \(sig)")
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
                        rootPC: existing != nil ? existing!.rootPC : (notePC < 12 ? Int(notePC) : 0),
                        quality: existing != nil ? existing!.quality : .major,
                        learnedNotePC: notePC < 12 ? Int(notePC) : nil
                    )
                    _table.wrappedValue.cells[cellIndex] = newAssignment
                    _learnCell.wrappedValue = nil
                    StrumPlayer.shared.padLearnHandler = nil
                    AppModel.shared.addLog(String(format: "Learned pad → %d%@ (sig %08X)", pos, row, sig))
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

    // MARK: - Chord picker (sheet)

    private var chordPickerView: some View {
        NavigationView {
            Form {
                Section("Root") {
                    Picker("Root", selection: $editRoot) {
                        ForEach(0..<12, id: \.self) { i in
                            Text(ChordAssignment.pcNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.wheel)
                }

                Section("Quality") {
                    Picker("Quality", selection: $editQuality) {
                        ForEach(ChordAssignment.Quality.allCases, id: \.self) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .pickerStyle(.wheel)
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
                        Text(ChordAssignment(rootPC: editRoot, quality: editQuality).name)
                            .fontWeight(.medium)
                    }
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle(editingCell.map { "\(ChordTable.rowLabels[$0 % 3])" } ?? "")
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
                editRoot = cell.rootPC
                editQuality = cell.quality
                editLocked = cell.locked == true
            } else {
                editRoot = 0
                editQuality = .major
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
            rootPC: editRoot,
            quality: editQuality,
            learnedNotePC: table.cells[i]?.learnedNotePC,
            locked: editLocked ? true : nil
        )
        editingCell = nil
    }
}
