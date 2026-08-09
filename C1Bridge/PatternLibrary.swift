import Foundation

/// One selectable pattern on the C1, as listed in the LiberLive app.
/// `channel`/`program` are exactly what OnSong needs in its MIDI event editor.
struct C1Pattern: Identifiable, Hashable {
    let id = UUID()
    let instrument: String   // Guitar / Piano / Bass / Drums
    let paddle: String       // Front / Rear
    let name: String         // LiberLive display name, e.g. "Hotel"
    let channel: Int
    let program: Int

    var midiLabel: String { "Ch \(channel) · PC \(program)" }
    var subtitle: String { "\(instrument) · \(paddle)" }
}

enum PatternLibrary {
    static let all: [C1Pattern] = {
        EmbeddedMasterMapping.csv
            .components(separatedBy: .newlines)
            .dropFirst() // header
            .compactMap { rawLine in
                let parts = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: ",")
                guard parts.count >= 7,
                      let channel = Int(parts[5]),
                      let program = Int(parts[6]),
                      channel > 0, program > 0 else { return nil }
                return C1Pattern(instrument: parts[0],
                                 paddle: parts[1],
                                 name: parts[3],
                                 channel: channel,
                                 program: program)
            }
    }()

    /// Simple contains-based filter for the manual search field.
    static func search(_ query: String) -> [C1Pattern] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return all.filter {
            $0.name.lowercased().contains(q) ||
            "\($0.instrument) \($0.paddle) \($0.name)".lowercased().contains(q)
        }
    }
}
