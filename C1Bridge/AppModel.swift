import Foundation
import Combine

final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date = Date()
        let message: String
    }

    // This was missing! The UI needs this to show/hide the Disconnect button.
    @Published var isConnected: Bool = false
    @Published private(set) var logs: [LogEntry] = []

    private init() {
        addLog("AppModel initialized")
    }

    func startBackgroundServices() {
        BackgroundAudioManager.shared.start()
    }

    func addLog(_ message: String) {
        let finalMessage = message.hasPrefix("[APP]") ? message : "[APP] " + message
        print(finalMessage)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.append(LogEntry(message: finalMessage))
            if self.logs.count > 500 { self.logs.removeFirst() }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll()
        }
    }

    /// Export the last 500 log lines to Documents/c1bridge-log.txt and return the URL for sharing.
    func exportLog() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("c1bridge-log.txt")
        let text = logs.map { $0.date.formatted(date: .abbreviated, time: .shortened) + " " + $0.message }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        print("[APP] Log exported to c1bridge-log.txt (\(logs.count) entries)")
        return url
    }
}
