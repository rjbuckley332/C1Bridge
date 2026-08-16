import Foundation

/// A single recorded drum hit on the looper grid (stage 4).
struct SavedHit: Codable, Hashable {
    var position: Int   // fret position 1-7
    var step: Int       // 16th-note step 0-15
}

/// A saved looper beat (Rich 03:55: "once the loop/beat sounds right, we save
/// it and it shows in the beat menu to add to a song in the song setup tab").
///
/// Hits are GRID positions (position + 16th step), not timestamps — so a saved
/// beat is tempo-independent and performs at the SONG's tempo on fire
/// (universal tempo rule). `bpm` is just the creation-time default for
/// standalone playback in the Beat tab.
struct SavedBeat: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var bpm: Int
    var hits: [SavedHit]
    var voices: [Int: LooperEngine.Voice]   // fret position -> assigned voice
    var createdAt = Date()
}

/// The beat menu's store. UserDefaults-JSON, same pattern as PresetStore.
/// Name is the identity: re-saving under an existing name overwrites it, and
/// every SongPreset referencing that name gets the update on next fire.
@MainActor
final class BeatLibrary: ObservableObject {
    static let shared = BeatLibrary()

    @Published private(set) var beats: [SavedBeat] = []
    private let defaultsKey = "c1bridge.savedBeats.v1"

    private init() { load() }

    /// Upsert by name (case-insensitive) — mirrors PresetStore.add.
    func add(_ beat: SavedBeat) {
        if let idx = beats.firstIndex(where: { $0.name.lowercased() == beat.name.lowercased() }) {
            var updated = beat
            updated.id = beats[idx].id
            updated.createdAt = beats[idx].createdAt
            beats[idx] = updated
        } else {
            beats.append(beat)
        }
        save()
        AppModel.shared.addLog("Beat \"\(beat.name)\" saved — \(beat.hits.count) hit(s) @ \(beat.bpm) BPM")
    }

    func delete(_ beat: SavedBeat) {
        beats.removeAll { $0.id == beat.id }
        save()
        AppModel.shared.addLog("Beat \"\(beat.name)\" deleted")
    }

    func beat(named name: String) -> SavedBeat? {
        beats.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(beats) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedBeat].self, from: data) else { return }
        beats = decoded
    }
}
