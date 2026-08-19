import Foundation

/// Codable reference to a pattern, stored inside a SongPreset.
struct PatternRef: Codable, Hashable {
    var instrument: String
    var paddle: String
    var name: String
    var channel: Int
    var program: Int
    /// Tempo locked to this pattern when it was favorited — nil for legacy records.
    /// Optional, so synthesized Codable decodes pre-tempo JSON cleanly.
    var tempoBPM: Int? = nil

    init(from p: C1Pattern) {
        instrument = p.instrument
        paddle = p.paddle
        name = p.name
        channel = p.channel
        program = p.program
        tempoBPM = nil
    }

    func toPattern() -> C1Pattern {
        C1Pattern(instrument: instrument, paddle: paddle, name: name, channel: channel, program: program)
    }
}

/// A named, complete song setup: patterns + key + tempo + volumes.
/// `triggerNumber` is PERMANENT: assigned once at first save, kept across
/// re-saves, never shifted or reused when other songs are deleted. This is
/// the number OnSong references (Ch 16 PC), so it must never move.
struct SongPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var patterns: [PatternRef]
    var keyProgram: Int?
    var keyLabel: String?
    var tempoBPM: Int?
    var drumVol: Int?
    var bassVol: Int?
    /// Start the DUUDU beat automatically when this preset loads.
    /// Optional-with-default so pre-beat JSON decodes as false.
    var beatEnabled: Bool = false
    /// Which beat pattern to start (nil = whatever is currently selected).
    var beatPattern: String? = nil
    /// A saved custom loop from the Beat tab's "My beats" to perform on load.
    /// Takes precedence over beatPattern. Name is the identity in BeatLibrary
    /// (re-saving a beat under the same name updates every referencing preset).
    var customBeatName: String? = nil
    /// Start the paddle strum layer ("332 Strum", build 76) when this preset
    /// loads. Independent of beatEnabled — drums and strums LAYER (the "332
    /// Railtree Hill Rd" arrangement). Optional-with-default so pre-strum
    /// JSON decodes as false.
    var strumEnabled: Bool = false
    var triggerNumber: Int = 0 // 0 = legacy/unassigned; migration fills it

    init(id: UUID = UUID(), name: String, patterns: [PatternRef], keyProgram: Int? = nil, keyLabel: String? = nil, tempoBPM: Int? = nil, drumVol: Int? = nil, bassVol: Int? = nil, beatEnabled: Bool = false, beatPattern: String? = nil, customBeatName: String? = nil, strumEnabled: Bool = false, triggerNumber: Int = 0) {
        self.id = id
        self.name = name
        self.patterns = patterns
        self.keyProgram = keyProgram
        self.keyLabel = keyLabel
        self.tempoBPM = tempoBPM
        self.drumVol = drumVol
        self.bassVol = bassVol
        self.beatEnabled = beatEnabled
        self.beatPattern = beatPattern
        self.customBeatName = customBeatName
        self.strumEnabled = strumEnabled
        self.triggerNumber = triggerNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        patterns = try c.decode([PatternRef].self, forKey: .patterns)
        keyProgram = try c.decodeIfPresent(Int.self, forKey: .keyProgram)
        keyLabel = try c.decodeIfPresent(String.self, forKey: .keyLabel)
        tempoBPM = try c.decodeIfPresent(Int.self, forKey: .tempoBPM)
        drumVol = try c.decodeIfPresent(Int.self, forKey: .drumVol)
        bassVol = try c.decodeIfPresent(Int.self, forKey: .bassVol)
        beatEnabled = try c.decodeIfPresent(Bool.self, forKey: .beatEnabled) ?? false
        beatPattern = try c.decodeIfPresent(String.self, forKey: .beatPattern)
        customBeatName = try c.decodeIfPresent(String.self, forKey: .customBeatName)
        strumEnabled = try c.decodeIfPresent(Bool.self, forKey: .strumEnabled) ?? false
        triggerNumber = try c.decodeIfPresent(Int.self, forKey: .triggerNumber) ?? 0
    }
}

/// The song database. Presets are triggered from OnSong with a single
/// program change on MIDI channel 16: PC N loads the preset whose permanent
/// triggerNumber is N, applying every stored command to the C1 in sequence.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published private(set) var presets: [SongPreset] = []
    private let defaultsKey = "c1bridge.songPresets.v1"

    private init() { load() }

    // MARK: - CRUD

    /// Saves a preset and returns its permanent trigger number.
    /// Re-saving an existing name keeps that song's number; a brand-new name
    /// gets the next unused number (max + 1). Numbers are never reused after
    /// a delete, so an OnSong trigger can never silently point at the wrong song.
    @discardableResult
    func add(_ preset: SongPreset) -> Int {
        if let idx = presets.firstIndex(where: { $0.name.lowercased() == preset.name.lowercased() }) {
            var updated = preset
            updated.id = presets[idx].id
            updated.triggerNumber = presets[idx].triggerNumber // permanent
            presets[idx] = updated
            save()
            return updated.triggerNumber
        } else {
            var newPreset = preset
            newPreset.triggerNumber = (presets.map(\.triggerNumber).max() ?? 0) + 1
            presets.append(newPreset)
            save()
            return newPreset.triggerNumber
        }
    }

    func delete(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets) // numbers of remaining songs never shift
        save()
    }

    // MARK: - Triggering

    /// OnSong entry point: Ch 16, PC N. Looks up by permanent trigger number.
    func apply(program: Int) {
        guard let preset = presets.first(where: { $0.triggerNumber == program }) else {
            AppModel.shared.addLog("Preset trigger: no preset #\(program)")
            return
        }
        apply(preset)
    }

    /// Sends every stored command to the C1. TWO tempo rules apply here:
    /// (1) the universal tempo rule — each pattern select is answered with the
    /// preset's tempo after the C1 settles from loading the pattern's own
    /// default; (2) TEMPO GOES LAST (Rich, build 75 — learned the hard way):
    /// the key select's Commit payload reloads C1 state and wipes any tempo
    /// sent before it, so the preset's tempo closes the recipe and nothing
    /// follows it on the wire. The tempo field follows so the UI stays truthful.
    func apply(_ preset: SongPreset) {
        AppModel.shared.addLog("Applying preset \"\(preset.name)\"")
        if let bpm = preset.tempoBPM { VoiceCommandManager.shared.notePresetTempo(bpm) }
        Task { @MainActor in
            for p in preset.patterns {
                MIDIHandler.trigger(channel: p.channel, program: p.program)
                if let bpm = preset.tempoBPM {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    MIDIHandler.triggerTempo(bpm: bpm)
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let key = preset.keyProgram {
                MIDIHandler.trigger(channel: 7, program: key)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let dv = preset.drumVol {
                MIDIHandler.trigger(channel: 8, program: dv + 1)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let bv = preset.bassVol {
                MIDIHandler.trigger(channel: 9, program: bv + 1)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            // Tempo is the LAST thing sent to the C1. The key commit gets the
            // same 250ms settle window a pattern select does, then the tempo
            // lands and nothing after it can wipe it. Covers the no-patterns
            // case too (the old standalone tempo send folded into this one).
            if let bpm = preset.tempoBPM {
                try? await Task.sleep(nanoseconds: 250_000_000)
                MIDIHandler.triggerTempo(bpm: bpm)
            }
            // Beat rides the recipe: starts after every send so the preset's
            // tempo is already banked; a playing beat was already retempo'd by
            // the live-follow hook, and start() no-ops if the tempo matches.
            // beatEnabled == false leaves the beat untouched (no surprise stop).
            if preset.beatEnabled {
                if let cbName = preset.customBeatName, let savedBeat = BeatLibrary.shared.beat(named: cbName) {
                    // Custom loop performs at the SONG's tempo (universal tempo rule).
                    LooperEngine.shared.perform(savedBeat, bpm: preset.tempoBPM ?? MIDIHandler.lastSentTempoBPM)
                } else {
                    if let raw = preset.beatPattern, let p = BeatPattern(rawValue: raw) {
                        BeatPlayer.shared.currentPattern = p
                    }
                    BeatPlayer.shared.start(bpm: preset.tempoBPM ?? MIDIHandler.lastSentTempoBPM)
                }
            }
            // Strum layer rides the recipe too (build 77): starts after the
            // closing tempo landed so it's banked; layers with whatever beat
            // started — drums + strums = the arrangement.
            if preset.strumEnabled {
                StrumPlayer.shared.start(bpm: preset.tempoBPM ?? MIDIHandler.lastSentTempoBPM)
            }
        }
    }

    // MARK: - Voice lookup

    func bestMatch(for spokenName: String) -> SongPreset? {
        let q = spokenName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let exact = presets.first(where: { $0.name.lowercased() == q }) { return exact }
        if let contains = presets.first(where: {
            $0.name.lowercased().contains(q) || q.contains($0.name.lowercased())
        }) { return contains }
        let qWords = Set(q.split(separator: " ").map(String.init))
        return presets.first(where: { p in
            let pWords = Set(p.name.lowercased().split(separator: " ").map(String.init))
            return !qWords.isDisjoint(with: pWords)
        })
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        OnSongSyncManager.shared.noteLocalChange()
    }

    // MARK: - Sync export/import (OnSong song backup)

    func exportForSync() -> [SongPreset] { presets }

    /// Full-replace import from a backup payload. Trigger numbers carry over
    /// unchanged — they are the permanent OnSong-facing identity of each song
    /// and must match on every device. Zero-numbered legacy records get the
    /// same migration as load().
    func importFromSync(_ incoming: [SongPreset]) {
        var decoded = incoming
        var next = (decoded.map(\.triggerNumber).max() ?? 0) + 1
        for i in decoded.indices where decoded[i].triggerNumber == 0 {
            decoded[i].triggerNumber = next
            next += 1
        }
        presets = decoded
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode([SongPreset].self, from: data) else { return }
        // Migration: legacy presets saved before permanent numbers existed
        // arrive with triggerNumber 0 — assign 1...N in their current order.
        var next = (decoded.map(\.triggerNumber).max() ?? 0) + 1
        var migrated = false
        for i in decoded.indices where decoded[i].triggerNumber == 0 {
            decoded[i].triggerNumber = next
            next += 1
            migrated = true
        }
        presets = decoded
        if migrated { save() }
    }
}
