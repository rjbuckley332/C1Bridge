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
}
