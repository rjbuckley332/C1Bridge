import Foundation

/// One pad → chord assignment (build 116 — Rich 09:12: "the two other
/// positions on each fret… 21 different chords… build a chord table and
/// assign it to a song just like we're doing drums and strums").
struct ChordAssignment: Codable, Hashable {
    /// Pad signature: FF01 bytes 2,3,4 (mask) + byte[13] packed as
    /// b2<<24 | b3<<16 | b4<<8 | b13. nil = not learned yet. byte[12]
    /// (note) is key-aware on the wire → display only, NEVER part of the
    /// signature.
    var signature: UInt32?
    var rootPC: Int          // 0=C … 11=B
    var quality: Quality
    /// The note byte[12] showed when the pad was learned — display label
    /// only (it can shift with the key).
    var learnedNotePC: Int?
    /// Transposition mode (Rich 16:58: "follow the key" is the norm;
    /// specials CHOOSE): nil/false = authored in C, transposed by the song's
    /// key at fire time (borrowed chords like ♭III/♭VI/♭VII ride along);
    /// true = key-locked absolute (pedal tone / signature chord). Optional
    /// for backward Codable compatibility with tables saved before 118.
    var locked: Bool?

    /// The sounding root for the current key: transpose unless locked.
    func soundingRoot(keyRootPC: Int) -> Int {
        locked == true ? rootPC : (rootPC + keyRootPC) % 12
    }

    enum Quality: String, Codable, CaseIterable {
        case major, minor, dim, aug, dom7, sus2, sus4, sus6, dim7, maj7, m7, m7b5
        var suffix: String { switch self {
            case .major: return ""; case .minor: return "m"; case .dim: return "°"; case .aug: return "+"
            case .dom7: return "7"; case .sus2: return "sus2"; case .sus4: return "sus4"; case .sus6: return "sus6"
            case .dim7: return "°7"; case .maj7: return "maj7"; case .m7: return "m7"; case .m7b5: return "m7♭5"
        } }
        /// Slot-1 interval (the "third" slot — sus chords put their color here).
        var t3: Int { switch self {
            case .major, .aug, .dom7, .maj7: return 4
            case .minor, .dim, .dim7, .m7, .m7b5: return 3
            case .sus2: return 2
            case .sus4: return 5
            case .sus6: return 7   // open sus6: 3rd out; 5th + 6th remain
        } }
        /// Slot-2 interval for triads (ignored when flat7 is set).
        var t5: Int { switch self {
            case .major, .minor, .dom7, .sus2, .sus4, .maj7, .m7: return 7
            case .dim, .dim7, .m7b5: return 6
            case .aug: return 8
            case .sus6: return 9
        } }
        /// 7th-slot interval (voices root + t3 + this, fifth dropped): dom7
        /// ♭7, maj7 natural 7, dim7 𝄫7 (=9), m7/m7♭5 ♭7 (3-note shell).
        var flat7: Int? { switch self {
            case .dom7, .m7, .m7b5: return 10
            case .maj7: return 11
            case .dim7: return 9
            default: return nil
        } }
    }

    static let pcNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    var name: String { Self.pcNames[rootPC % 12] + quality.suffix }

    static func signature(b2: UInt8, b3: UInt8, b4: UInt8, b13: UInt8) -> UInt32 {
        (UInt32(b2) << 24) | (UInt32(b3) << 16) | (UInt32(b4) << 8) | UInt32(b13)
    }
}

/// A named chord table: 21 cells (7 fret positions × 3 rows) → assignments.
/// Name is the identity (same rule as the beat/strum libraries: re-saving
/// a name updates every song that references it).
struct ChordTable: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Row-major: index = (position-1)*3 + row, row 0=A / 1=B / 2=C.
    var cells: [ChordAssignment?]
    var createdAt = Date()

    static let rowLabels = ["A", "B", "C"]
    static func empty(name: String) -> ChordTable {
        ChordTable(name: name, cells: Array(repeating: nil, count: 21))
    }
    static func index(position: Int, row: Int) -> Int { (position - 1) * 3 + row }

    /// The starter table mirrors the C1's own Advanced chord-pad grid
    /// (from the LiberLive app, key C): per degree — col A = parallel-quality
    /// swap (minor on I/IV/V rows, major on ii/iii/vi/vii rows), col B =
    /// diatonic chord, col C = dominant 7. Signatures nil until learned.
    /// (App shows B major on row 7B where the C1 natively sounds B° —
    /// starter follows the APP; edit to taste.)
    static func starter(name: String) -> ChordTable {
        // (rootPC, colA quality) per position 1...7 — col B is the flip,
        // col C is always dom7.
        let rows: [(Int, ChordAssignment.Quality)] = [
            (0, .minor),  // C:  Cm | C  | C7
            (2, .major),  // D:  D  | Dm | D7
            (4, .major),  // E:  E  | Em | E7
            (5, .minor),  // F:  Fm | F  | F7
            (7, .minor),  // G:  Gm | G  | G7
            (9, .major),  // A:  A  | Am | A7
            (11, .minor), // B:  Bm | B  | B7
        ]
        var t = empty(name: name)
        for pos in 1...7 {
            let (root, colA) = rows[pos - 1]
            let colB: ChordAssignment.Quality = (colA == .minor) ? .major : .minor
            t.cells[index(position: pos, row: 0)] = ChordAssignment(signature: nil, rootPC: root, quality: colA, learnedNotePC: nil)
            t.cells[index(position: pos, row: 1)] = ChordAssignment(signature: nil, rootPC: root, quality: colB, learnedNotePC: nil)
            t.cells[index(position: pos, row: 2)] = ChordAssignment(signature: nil, rootPC: root, quality: .dom7, learnedNotePC: nil)
        }
        return t
    }

    /// Rock Flats grid — the starter but with ♭III / ♭VI / ♭VII in the
    /// center column (positions 3, 6, 7 = E♭ / A♭ / B♭ in C). These
    /// transpose with the song key via soundingRoot.
    static func rockFlats(name: String) -> ChordTable {
        var t = starter(name: name)
        t.cells[index(position: 3, row: 1)] = ChordAssignment(signature: nil, rootPC: 3, quality: .major, learnedNotePC: nil)
        t.cells[index(position: 6, row: 1)] = ChordAssignment(signature: nil, rootPC: 8, quality: .major, learnedNotePC: nil)
        t.cells[index(position: 7, row: 1)] = ChordAssignment(signature: nil, rootPC: 10, quality: .major, learnedNotePC: nil)
        return t
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

    func add(_ table: ChordTable) {
        if let idx = tables.firstIndex(where: { $0.name.lowercased() == table.name.lowercased() }) {
            var updated = table
            updated.id = tables[idx].id
            updated.createdAt = tables[idx].createdAt
            tables[idx] = updated
        } else {
            tables.append(table)
        }
        save()
        let assigned = table.cells.compactMap { $0 }.count
        AppModel.shared.addLog("Chord table \"\(table.name)\" saved — \(assigned)/21 pads assigned")
    }

    func delete(_ table: ChordTable) {
        tables.removeAll { $0.id == table.id }
        save()
        AppModel.shared.addLog("Chord table \"\(table.name)\" deleted")
    }

    func table(named name: String) -> ChordTable? {
        tables.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(tables) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        OnSongSyncManager.shared.noteLocalChange()
    }

    // MARK: - Sync export/import

    func exportForSync() -> [ChordTable] { tables }

    func importFromSync(_ incoming: [ChordTable]) {
        tables = incoming
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ChordTable].self, from: data) else { return }
        tables = decoded
    }
}
