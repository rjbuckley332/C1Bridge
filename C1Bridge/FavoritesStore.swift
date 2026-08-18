import Foundation

/// Rich's curated pattern favorites, persisted across launches.
/// Keyed by channel+program (unique per pattern variant) so separately-built
/// library instances of the same pattern compare stably.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [PatternRef] = [] // in starred order
    private let defaultsKey = "c1bridge.favorites.v1"

    private init() { load() }

    func isFavorite(_ p: C1Pattern) -> Bool {
        favorites.contains { $0.channel == p.channel && $0.program == p.program }
    }

    func toggle(_ p: C1Pattern, tempo: Int? = nil) {
        isFavorite(p) ? remove(p) : add(p, tempo: tempo)
    }

    func add(_ p: C1Pattern, tempo: Int? = nil) {
        guard !isFavorite(p) else { return }
        var ref = PatternRef(from: p)
        ref.tempoBPM = tempo
        favorites.append(ref)
        save()
    }

    /// The tempo locked into this pattern's favorite record, if any.
    func tempo(for p: C1Pattern) -> Int? {
        favorites.first { $0.channel == p.channel && $0.program == p.program }?.tempoBPM
    }

    /// Retunes an existing favorite's locked tempo in place (keeps starred order).
    /// Used when Rich speaks a fresh suggested tempo for a pattern he already
    /// starred — the new explicit tempo should win, not rot behind the old lock.
    func updateTempo(_ bpm: Int, for p: C1Pattern) {
        guard let i = favorites.firstIndex(where: { $0.channel == p.channel && $0.program == p.program }) else { return }
        favorites[i].tempoBPM = bpm
        save()
    }

    func remove(_ p: C1Pattern) {
        favorites.removeAll { $0.channel == p.channel && $0.program == p.program }
        save()
    }

    /// The sampling pool for "sample guitar favorites": starred patterns for one
    /// instrument, in starred order. Favorites are usually starred on the Front
    /// paddle; a Rear sweep maps each to its same-named Rear variant.
    func pool(instrument: String, paddle: String = "Front") -> [C1Pattern] {
        favorites
            .map { $0.toPattern() }
            .filter { $0.instrument == instrument }
            .compactMap { fav in
                if fav.paddle == paddle { return fav }
                return PatternLibrary.all.first {
                    $0.instrument == fav.instrument && $0.paddle == paddle && $0.name == fav.name
                }
            }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        OnSongSyncManager.shared.noteLocalChange()
    }

    // MARK: - Sync export/import (OnSong song backup)

    func exportForSync() -> [PatternRef] { favorites }

    func importFromSync(_ incoming: [PatternRef]) {
        favorites = incoming
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PatternRef].self, from: data) else { return }
        favorites = decoded
    }
}
