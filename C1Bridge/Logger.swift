import Foundation
import os.log

enum AppLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "C1Bridge", category: "APP")

    static func print(_ message: String) {
        Swift.print(message)
        logger.info("\(message, privacy: .public)")
    }
}
