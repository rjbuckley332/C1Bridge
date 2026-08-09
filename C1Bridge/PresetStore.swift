import Foundation

/// Codable reference to a pattern, stored inside a SongPreset.
struct PatternRef: Codable, Hashable {
    var instrument: String
    var paddle: String
    var name: String
    var channel: Int
    var program: Int

    init(from p: C1Pattern) {
        instrument = p.instrument
        paddle = p.paddle
        name = p.name
        channel = p.channel
        program = p.program
    }

    func toPattern() -> C1Pattern {
        C1Pattern(instrument: instrument, paddle: paddle, name: name, channel: channel, program: program)
    }
}

/// A named, complete song setup: patterns + key + tempo + volumes.
struct SongPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var patterns: [PatternRef]
    var keyProgram: Int?
    var keyLabel: String?
    var tempoBPM: Int?
    var drumVol: Int?
    var bassVol: Int?
}

/// The song database. Presets are triggered from OnSong with a single
/// program change on MIDI channel 16: PC N loads preset N (1-based),
/// applying every stored command to the C1 in sequence.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published private(set) var presets: [SongPreset] = []
    private let defaultsKey = "c1bridge.songPresets.v1"

    private init() { load() }

    // MARK: - CRUD

    func add(_ preset: SongPreset) {
        if let idx = presets.firstIndex(where: { $0.name.lowercased() == preset.name.lowercased() }) {
            var updated = preset
            updated.id = presets[idx].id // keep stable identity/number on re-save
            presets[idx] = updated
        } else {
            presets.append(preset)
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        save()
    }

    func triggerNumber(for preset: SongPreset) -> Int? {
        guard let idx = presets.firstIndex(of: preset) else { return nil }
        return idx + 1
    }

    // MARK: - Triggering

    /// OnSong entry point: Ch 16, PC N.
    func apply(program: Int) {
        guard (1...presets.count).contains(program) else {
            AppModel.shared.addLog("Preset trigger: no preset #\(program)")
            return
        }
        apply(presets[program - 1])
    }

    /// Sends every stored command to the C1 with small gaps so BLE writes land cleanly.
    func apply(_ preset: SongPreset) {
        AppModel.shared.addLog("Applying preset \"\(preset.name)\"")
        Task { @MainActor in
            for p in preset.patterns {
                MIDIHandler.trigger(channel: p.channel, program: p.program)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let key = preset.keyProgram {
                MIDIHandler.trigger(channel: 7, program: key)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let bpm = preset.tempoBPM {
                MIDIHandler.triggerTempo(bpm: bpm)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let dv = preset.drumVol {
                MIDIHandler.trigger(channel: 8, program: dv + 1)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if let bv = preset.bassVol {
                MIDIHandler.trigger(channel: 9, program: bv + 1)
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
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SongPreset].self, from: data) else { return }
        presets = decoded
    }
}
