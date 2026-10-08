import Foundation

/// One pad → chord assignment (build 116 — Rich 09:12: "the two other
/// positions on each fret… 21 different chords… build a chord table and
/// assign it to a song just like we're doing drums and strums").
///
/// Build 136 model (Rich 2026-10-07): each pad is TWO data points —
///   1. accidental: Flat / Natural / Sharp  (the ROOT — real data, not a label)
///   2. quality:    add9 / Major / minor    (the CHORD TYPE — the row is this)
/// The fret position supplies the degree root (1…7, key-relative); the
/// accidental shifts it one semitone; the song key transposes the result.
/// Pads have no absolute note identity ("I don't see the need to see
/// F, G, F#, A").
struct ChordAssignment: Codable, Hashable {
    /// Pad signature: FF01 bytes 2,3,4 (mask) + byte[13] packed as
    /// b2<<24 | b3<<16 | b4<<8 | b13. nil = not learned yet. byte[12]
    /// (note) is key-aware on the wire → display only, NEVER part of the
    /// signature.
    var signature: UInt32?
    /// The root data: −1 = Flat, 0 = Natural, +1 = Sharp, relative to the
    /// fret's degree root.
    var accidental: Int
    var quality: Quality
    /// The note byte[12] showed when the pad was learned — display label
    /// only (it can shift with the key).
    var learnedNotePC: Int?
    /// Transposition mode (Rich 16:58: "follow the key" is the norm;
    /// specials CHOOSE). Kept for backward compatibility — currently ignored
    /// by soundingRoot (all custom maps always track the key).
    var locked: Bool?
    /// LEGACY (pre-build-136): absolute key-relative rootPC. Decode-only;
    /// migrated to `accidental` by ChordTableLibrary (needs the fret
    /// position), never re-encoded.
    var legacyRootPC: Int?

    /// C-reference root pitch class for fret position (1…7).
    func rootPC(position: Int) -> Int {
        (ChordTable.degreeRoots[position - 1] + accidental + 12) % 12
    }

    /// The sounding root for the current key: degree root + accidental,
    /// transposed by the key. (`locked` still ignored — always-track-key.)
    func soundingRoot(position: Int, keyRootPC: Int) -> Int {
        (rootPC(position: position) + keyRootPC) % 12
    }

    var accidentalWord: String {
        switch accidental {
        case -1: return "Flat"
        case 1:  return "Sharp"
        default: return "Natural"
        }
    }

    /// C-reference display name for fret position (e.g. "C#add9").
    func name(position: Int) -> String {
        Self.pcNames[rootPC(position: position)] + quality.suffix
    }

    /// The official pad editor's six chord types (Rich 2026-10-07). The
    /// type lives in the LOW NIBBLE of each pad's map byte — 4 bits, 16
    /// slots. VERIFIED: major=0, minor=1, dom7=2 (the all-₇ column proof).
    /// GUESSED, sequential: m7=3, maj7=4, add9=5 — Rich ear-tests each and
    /// any wrong guess is a one-line swap here.
    enum Quality: String, Codable, CaseIterable {
        case dom7, major, minor, m7, maj7
        /// Storage name dodges a collision: "add9" strings saved during the
        /// 136–142 era meant the flag-2 dom7 slot and must keep decoding to
        /// dom7 via legacyName; 145+ saves write "add9v2".
        case add9 = "add9v2"
        var suffix: String { switch self {
            case .dom7:  return "7"
            case .major: return ""
            case .minor: return "m"
            case .m7:    return "m7"
            case .maj7:  return "maj7"
            case .add9:  return "add9"
        } }
        /// Picker display name — matches the LiberLive app's own type labels
        /// (Rich 2026-10-07: their list is 7 / M / m / m7 / maj7 / add9;
        /// "dom7" is textbook jargon — the official app just says "7").
        /// rawValue stays for storage.
        var displayName: String { switch self {
            case .dom7:  return "7"
            case .major: return "M"
            case .minor: return "m"
            case .m7:    return "m7"
            case .maj7:  return "maj7"
            case .add9:  return "add9"
        } }
        /// Slot-1 interval (the "third").
        var t3: Int { switch self {
            case .minor, .m7: return 3
            default:          return 4
        } }
        /// Slot-2 interval for triads (ignored when flat7 is set).
        var t5: Int { 7 }
        /// 7th-slot interval (root+3+shell, fifth dropped).
        var flat7: Int? { switch self {
            case .dom7, .m7: return 10
            case .maj7:      return 11
            case .add9:      return 2
            default:         return nil
        } }
        /// C1 hardware map flag nibble (BLE address 0x15). 0/1/2 PROVEN;
        /// 3/4/5 are the ear-test candidates.
        var hwFlag: Int { switch self {
            case .major: return 0
            case .minor: return 1
            case .dom7:  return 2
            case .m7:    return 3   // GUESS
            case .maj7:  return 4   // GUESS
            case .add9:  return 5   // GUESS
        } }
        /// Migration from earlier lists. Note: "add9" (136–142 era) decodes
        /// to dom7 — that era's add9 was really the flag-2 slot.
        init(legacyName: String) {
            switch legacyName {
            case "dom7":                               self = .dom7
            case "m7":                                 self = .m7
            case "maj7":                               self = .maj7
            case "add9":                               self = .dom7
            case "minor", "dim", "dim7", "m7b5":       self = .minor
            default:                                   self = .major
            // major, sus2, sus4, sus6, aug → major
            }
        }
    }

    static let pcNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func signature(b2: UInt8, b3: UInt8, b4: UInt8, b13: UInt8) -> UInt32 {
        (UInt32(b2) << 24) | (UInt32(b3) << 16) | (UInt32(b4) << 8) | UInt32(b13)
    }

    // MARK: - Init / Codable (tolerant of the pre-136 format)

    init(signature: UInt32? = nil, accidental: Int, quality: Quality, learnedNotePC: Int? = nil, locked: Bool? = nil) {
        self.signature = signature
        self.accidental = accidental
        self.quality = quality
        self.learnedNotePC = learnedNotePC
        self.locked = locked
        self.legacyRootPC = nil
    }

    private enum CodingKeys: String, CodingKey {
        case signature, accidental, quality, learnedNotePC, locked
        case rootPC   // legacy decode only
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signature = try c.decodeIfPresent(UInt32.self, forKey: .signature)
        learnedNotePC = try c.decodeIfPresent(Int.self, forKey: .learnedNotePC)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        let q = try c.decodeIfPresent(String.self, forKey: .quality) ?? "major"
        quality = Quality(rawValue: q) ?? Quality(legacyName: q)
        accidental = try c.decodeIfPresent(Int.self, forKey: .accidental) ?? 0
        legacyRootPC = try c.decodeIfPresent(Int.self, forKey: .rootPC)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(signature, forKey: .signature)
        try c.encode(accidental, forKey: .accidental)
        try c.encode(quality.rawValue, forKey: .quality)
        try c.encodeIfPresent(learnedNotePC, forKey: .learnedNotePC)
        try c.encodeIfPresent(locked, forKey: .locked)
    }
}

/// A named chord table: 21 cells (7 fret positions × 3 rows) → assignments.
/// Name is the identity (same rule as the beat/strum libraries: re-saving
/// a name updates every song that references it).
struct ChordTable: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Row-major: index = (position-1)*3 + row. Real LiberLive grid
    /// (Rich 2026-10-07): the ROW is the chord type — add9 (top), Major
    /// (middle), minor (bottom); each pad's accidental (Flat/Natural/Sharp)
    /// is its root data relative to the fret's degree note.
    var cells: [ChordAssignment?]
    var createdAt = Date()
    /// Optional MIDI trigger: a Program Change on this channel/program arms
    /// this table (Rich 2026-10-06). nil = selectable by name only.
    var midiChannel: Int?
    var midiProgram: Int?

    /// Byte-row ↔ official-UI column mapping (proven by the official app's
    /// Chord-pad screens 2026-10-07): byte-row 0 = the all-₇ column, row 1 =
    /// diatonic, row 2 = the variant column (standard = parallel swap; the
    /// official Rock grid swaps in ♭3/♯4m/♯5m/♭6 there).
    static let rowLabels = ["7th", "Diatonic", "Variant"]
    /// The standard grid's per-position qualities (captured factory map +
    /// official-app screen): diatonic = I IV V major · ii iii vi minor ·
    /// vii major; variant = the parallel swap.
    static let diatonicQualities: [ChordAssignment.Quality] = [.major, .minor, .minor, .major, .major, .minor, .major]
    static let variantQualities: [ChordAssignment.Quality] = [.minor, .major, .major, .minor, .minor, .major, .minor]
    /// Default quality for a blank pad = the standard grid's content there.
    static func factoryQuality(position: Int, row: Int) -> ChordAssignment.Quality {
        switch row {
        case 0:  return .dom7
        case 1:  return diatonicQualities[position - 1]
        default: return variantQualities[position - 1]
        }
    }
    /// Diatonic root pitch class per fret position 1...7 (major scale, key-relative).
    static let degreeRoots = [0, 2, 4, 5, 7, 9, 11]
    static func empty(name: String) -> ChordTable {
        ChordTable(name: name, cells: Array(repeating: nil, count: 21))
    }
    static func index(position: Int, row: Int) -> Int { (position - 1) * 3 + row }

    /// Factory Default = the OFFICIAL standard grid (captured factory map
    /// …022242527292b2 · 002141507091b0 · 012040517190b1, confirmed by the
    /// official app's Chord-pad screen):
    ///   row 0 = 7th      — every degree, dom7
    ///   row 1 = Diatonic — I IV V major · ii iii vi minor · vii major
    ///   row 2 = Variant  — the parallel swap (i iv v minor · II III VI major)
    /// All Natural roots. Signatures nil until learned.
    static func starter(name: String) -> ChordTable {
        var t = empty(name: name)
        for pos in 1...7 {
            t.cells[index(position: pos, row: 0)] = ChordAssignment(
                signature: nil, accidental: 0, quality: .dom7, learnedNotePC: nil)
            t.cells[index(position: pos, row: 1)] = ChordAssignment(
                signature: nil, accidental: 0, quality: diatonicQualities[pos - 1], learnedNotePC: nil)
            t.cells[index(position: pos, row: 2)] = ChordAssignment(
                signature: nil, accidental: 0, quality: variantQualities[pos - 1], learnedNotePC: nil)
        }
        return t
    }

    /// Encode as the C1 hardware chord-map payload (address 0x15), matching
    /// the captured official-app writes: row-major BY ROW (all 7 positions
    /// of the add9 row, then Major, then minor); each byte =
    /// root nibble << 4 | quality flag. The root nibble is KEY-RELATIVE
    /// (degree root + accidental) — the C1's own key select transposes.
    /// nil cells fall back to the factory content (degree root, Natural,
    /// the row's type). Sanity: starter() encodes bit-for-bit to the
    /// captured factory map (…022242527292b2 002141507091b0 012040517190b1).
    func hardwareMapHex() -> String {
        var hex = "b11e1f1500"
        for row in 0...2 {
            for pos in 1...7 {
                let cell = cells[Self.index(position: pos, row: row)]
                let root = cell?.rootPC(position: pos) ?? Self.degreeRoots[pos - 1]
                // Per-pad flags — the official grids mix major/minor pad by
                // pad, and the 7/21-pad mystery turned out to be the missing
                // KEY FRAME, not the flags (Rock C key-first landed a mixed
                // grid pad-for-pad, official-app verified 2026-10-07).
                let flag = (cell?.quality ?? Self.factoryQuality(position: pos, row: row)).hwFlag
                hex += String(format: "%02x", (root << 4) | flag)
            }
        }
        return hex
    }

}

/// The chord-table library. Mirrors StrumBeatLibrary: UserDefaults +
/// OnSongSync export/import, name is the identity.
@MainActor
final class ChordTableLibrary: ObservableObject {
    static let shared = ChordTableLibrary()

    @Published private(set) var tables: [ChordTable] = []
    private let defaultsKey = "c1bridge.chordTables.v1"

    private init() { load() }

    func add(_ table: ChordTable, log: Bool = true) {
        if let idx = tables.firstIndex(where: { $0.name.lowercased() == table.name.lowercased() }) {
            var updated = table
            updated.id = tables[idx].id
            updated.createdAt = tables[idx].createdAt
            tables[idx] = updated
        } else {
            tables.append(table)
        }
        save()
        if log {
            let assigned = table.cells.compactMap { $0 }.count
            AppModel.shared.addLog("Chord table \"\(table.name)\" saved — \(assigned)/21 pads assigned")
        }
    }

    func delete(_ table: ChordTable) {
        tables.removeAll { $0.id == table.id }
        save()
        AppModel.shared.addLog("Chord table \"\(table.name)\" deleted")
    }

    /// Wipes every saved table on this device (Rich 2026-10-06 — clean-slate
    /// after the grid-model change). save() persists the empty array and
    /// notifies sync like any other local change.
    func removeAll() {
        tables = []
        save()
        AppModel.shared.addLog("All chord tables deleted")
    }

    func table(named name: String) -> ChordTable? {
        tables.first { $0.name.lowercased() == name.lowercased() }
    }

    /// First table armed on the given MIDI channel/program pair (build 129).
    func table(forMidiChannel channel: Int, program: Int) -> ChordTable? {
        tables.first { $0.midiChannel == channel && $0.midiProgram == program }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(tables) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        OnSongSyncManager.shared.noteLocalChange()
    }

    // MARK: - Legacy migration (pre-build-136 rootPC cells → accidental)

    /// Converts cells saved in the absolute-rootPC format to the accidental
    /// model: accidental = clamp(rootPC − degreeRoot, −1…+1). Roots wider
    /// than one semitone from the degree clamp to the nearest accidental —
    /// the real grid has no wider reach. Returns (table, didMigrate).
    private func migrateLegacyCells(_ table: ChordTable) -> (ChordTable, Bool) {
        var t = table
        var changed = false
        var clamps: [String] = []
        for i in t.cells.indices {
            guard var cell = t.cells[i], let legacy = cell.legacyRootPC else { continue }
            let degreeRoot = ChordTable.degreeRoots[i / 3]
            let offset = legacy - degreeRoot
            cell.accidental = max(-1, min(1, offset))
            if offset < -1 || offset > 1 {
                clamps.append("\(i / 3 + 1) \(ChordTable.rowLabels[i % 3])")
            }
            cell.legacyRootPC = nil
            t.cells[i] = cell
            changed = true
        }
        if !clamps.isEmpty {
            let clampCount = clamps.count
            let clampList = clamps.prefix(6).joined(separator: ", ")
            DispatchQueue.main.async {
                AppModel.shared.addLog("Table \"\(table.name)\": \(clampCount) pad(s) sat wider than ♭/♯ from their fret and were clamped — \(clampList)")
            }
        }
        return (t, changed)
    }

    // MARK: - Sync export/import

    func exportForSync() -> [ChordTable] { tables }

    func importFromSync(_ incoming: [ChordTable]) {
        tables = incoming.map { migrateLegacyCells($0).0 }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ChordTable].self, from: data) else { return }
        var didMigrate = false
        tables = decoded.map { t in
            let (m, changed) = migrateLegacyCells(t)
            didMigrate = didMigrate || changed
            return m
        }
        if didMigrate {
            save()
            DispatchQueue.main.async {
                AppModel.shared.addLog("Chord tables updated to the Flat/Natural/Sharp model")
            }
        }
    }
}
