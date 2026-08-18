import Foundation

/// A single recorded drum hit on the looper grid (stage 4).
struct SavedHit: Codable, Hashable {
    var position: Int   // fret position 1-7
    var step: Int       // 16th-note step 0-15
    /// "<sampleID>.f32" inside the beat's sample dir when this hit plays a
    /// captured mic sound (build 65); nil = synthesized position voice.
    var sampleFile: String? = nil
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
    /// samplePayloads (filename → raw float32 data) are written into the
    /// beat's sample dir; re-saving wipes and rewrites it.
    func add(_ beat: SavedBeat, samplePayloads: [String: Data] = [:]) {
        let finalID: UUID
        if let idx = beats.firstIndex(where: { $0.name.lowercased() == beat.name.lowercased() }) {
            var updated = beat
            updated.id = beats[idx].id
            updated.createdAt = beats[idx].createdAt
            beats[idx] = updated
            finalID = updated.id
        } else {
            beats.append(beat)
            finalID = beat.id
        }
        save()
        let dir = samplesDir(for: finalID)
        try? FileManager.default.removeItem(at: dir)
        if !samplePayloads.isEmpty {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in samplePayloads {
                try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
        }
        let clipNote = samplePayloads.isEmpty ? "" : ", \(samplePayloads.count) sound clip(s)"
        AppModel.shared.addLog("Beat \"\(beat.name)\" saved — \(beat.hits.count) hit(s) @ \(beat.bpm) BPM\(clipNote)")
    }

    func delete(_ beat: SavedBeat) {
        beats.removeAll { $0.id == beat.id }
        save()
        try? FileManager.default.removeItem(at: samplesDir(for: beat.id))
        AppModel.shared.addLog("Beat \"\(beat.name)\" deleted")
    }

    // MARK: - Sample storage (build 65 — mic-as-instrument)

    /// Pure path computation — no actor state, safe to call from anywhere.
    nonisolated private func samplesDir(for id: UUID) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeatSamples").appendingPathComponent(id.uuidString)
    }

    /// Load every sample referenced by the beat's hits: sampleID → frames.
    /// Pure file I/O — nonisolated so LooperEngine.load can call it.
    nonisolated func loadSamples(for beat: SavedBeat) -> [UUID: [Float]] {
        var out: [UUID: [Float]] = [:]
        let dir = samplesDir(for: beat.id)
        for hit in beat.hits {
            guard let file = hit.sampleFile,
                  let sid = UUID(uuidString: String(file.dropLast(4))),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { continue }
            out[sid] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return out
    }

    func beat(named name: String) -> SavedBeat? {
        beats.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(beats) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        OnSongSyncManager.shared.noteLocalChange()
    }

    // MARK: - Sync export/import (OnSong song backup)

    func exportForSync() -> [SavedBeat] { beats }

    /// Full-replace import from a backup payload. Beat STRUCTURE (grid hits,
    /// voices, bpm) syncs; recorded mic-sound audio does NOT ride the payload
    /// (too big for song text). Beats whose clips are missing on this device
    /// stay intact but render those hits silently until re-recorded.
    func importFromSync(_ incoming: [SavedBeat]) {
        beats = incoming
        save()
        var missing: [String] = []
        for b in beats where b.hits.contains(where: { $0.sampleFile != nil }) {
            let dir = samplesDir(for: b.id)
            let complete = b.hits.allSatisfy { hit in
                guard let f = hit.sampleFile else { return true }
                return FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path)
            }
            if !complete { missing.append(b.name) }
        }
        if !missing.isEmpty {
            AppModel.shared.addLog("Sync: beat(s) missing their recorded sounds on this device: \(missing.joined(separator: ", ")) — those hits stay silent until re-recorded")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedBeat].self, from: data) else { return }
        beats = decoded
    }
}
