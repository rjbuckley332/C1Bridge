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

    func toggle(_ p: C1Pattern) {
        isFavorite(p) ? remove(p) : add(p)
    }

    func add(_ p: C1Pattern) {
        guard !isFavorite(p) else { return }
        favorites.append(PatternRef(from: p))
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
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PatternRef].self, from: data) else { return }
        favorites = decoded
    }
}
