import Foundation

/// User-set suggested tempos for patterns — the writable "suggested tempo column".
/// Rich discovers a pattern's ideal tempo by ear while sampling, says
/// "suggested tempo 92", and it's banked here (persisted), keyed by
/// channel+program so it survives library rebuilds.
/// Resolution order: this store first, then the pattern's CSV suggestedTempo.
@MainActor
final class SuggestedTempoStore: ObservableObject {
    static let shared = SuggestedTempoStore()

    @Published private(set) var tempos: [String: Int] = [:] // "channel:program" -> bpm
    private let defaultsKey = "c1bridge.suggestedTempos.v1"

    private init() { load() }

    private func key(_ p: C1Pattern) -> String { "\(p.channel):\(p.program)" }

    /// The effective suggested tempo for a pattern (user override, else CSV value).
    func tempo(for p: C1Pattern) -> Int? {
        tempos[key(p)] ?? p.suggestedTempo
    }

    func set(_ bpm: Int, for p: C1Pattern) {
        tempos[key(p)] = bpm
        save()
    }

    private func save() {
        UserDefaults.standard.set(tempos, forKey: defaultsKey)
    }

    private func load() {
        tempos = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
    }
}
