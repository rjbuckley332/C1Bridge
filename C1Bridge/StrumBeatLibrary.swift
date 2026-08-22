import Foundation

/// One strum bar on the Guitar Beats strip (Rich 8/20: "slide big bars
/// back-and-forth to signify time... a bold bar represents the downbeat, and a
/// non-bold bar represents the upbeat").
struct StrumEvent: Codable, Hashable {
    /// Position in 16th-note steps from the measure start. FRACTIONAL on
    /// purpose: the swing/"steal" nudge is stored as a fraction of a 16th, so
    /// the pattern is tempo-independent and performs at the SONG's tempo
    /// (universal tempo rule — same as SavedBeat's grid positions).
    var pos: Double
    /// Bold bar = down strum; light bar = up strum (tap toggles).
    var down: Bool
    /// Rest marker (build 113 — Rich 07:42: "a soundless strum, or rest, so
    /// that I can choose that as the first beat"). Optional for backward-
    /// compatible decoding of pre-113 patterns (absent = not a rest). The
    /// renderer SKIPS rests — they're editor/library markers only; a rest
    /// slot is simply silent.
    var rest: Bool? = nil
    var isRest: Bool { rest == true }
}

/// A named, user-built strum pattern. NO factory strums (Rich 8/20 7:36:
/// "I don't need any factory Strum beats. I will build them and name them.").
/// ONE measure (his 7:26 answer); audition loops it as a two-measure phrase
/// so the seam is audible ("I frequently need to hear two measures").
struct StrumPattern: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// 4 = 4/4, 3 = 3/4, 6 = 6/8 (the three signatures Rich approved 7:32).
    var beatsPerBar: Int
    /// 16th-note steps in the measure: 16 for 4/4; 12 for 3/4 and 6/8.
    var stepsPerBar: Int
    var hits: [StrumEvent]
    /// Optional saved tempo (build 108 — Rich 8/22 06:57: "can I save a
    /// strum now with its own tempo in the Strum builder?"). nil = legacy
    /// tempo-independent strum (seeds from the song tempo). Set = the
    /// strum's own tempo: it seeds the paddle press clock (build 107), then
    /// his presses take over as usual.
    var tempoBPM: Int? = nil
    var createdAt = Date()

    var sigLabel: String {
        switch beatsPerBar {
        case 3: return "3/4"
        case 6: return "6/8"
        default: return "4/4"
        }
    }

    static func steps(for beats: Int) -> Int { beats == 4 ? 16 : 12 }
}

/// The My-Strums library. Name is the identity (same rule as BeatLibrary:
/// re-saving a strum under the same name updates every song recipe that
/// references it).
@MainActor
final class StrumBeatLibrary: ObservableObject {
    static let shared = StrumBeatLibrary()

    @Published private(set) var patterns: [StrumPattern] = []
    private let defaultsKey = "c1bridge.strumPatterns.v1"

    private init() { load() }

    func add(_ pattern: StrumPattern) {
        if let idx = patterns.firstIndex(where: { $0.name.lowercased() == pattern.name.lowercased() }) {
            var updated = pattern
            updated.id = patterns[idx].id
            updated.createdAt = patterns[idx].createdAt
            patterns[idx] = updated
        } else {
            patterns.append(pattern)
        }
        save()
        AppModel.shared.addLog("Strum \"\(pattern.name)\" saved — \(pattern.hits.count) strum(s), \(pattern.sigLabel)")
    }

    func delete(_ pattern: StrumPattern) {
        patterns.removeAll { $0.id == pattern.id }
        save()
        AppModel.shared.addLog("Strum \"\(pattern.name)\" deleted")
    }

    func pattern(named name: String) -> StrumPattern? {
        patterns.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(patterns) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        OnSongSyncManager.shared.noteLocalChange()
    }

    // MARK: - Sync export/import

    func exportForSync() -> [StrumPattern] { patterns }

    func importFromSync(_ incoming: [StrumPattern]) {
        patterns = incoming
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([StrumPattern].self, from: data) else { return }
        patterns = decoded
    }
}
