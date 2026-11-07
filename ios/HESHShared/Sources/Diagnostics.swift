import Foundation
import os

/// Ultimo errore di decifratura/consegna, visibile nell'app. Mai contenuti:
/// solo mittente, tipo busta e descrizione dell'errore.
public enum Diagnostics {
    private static let log = Logger(subsystem: "it.hesh.app", category: "messages")
    private static let defaults = UserDefaults(suiteName: HESHConfig.appGroup)

    public static func record(_ message: String) {
        log.error("\(message, privacy: .public)")
        defaults?.set("\(Date().formatted(date: .omitted, time: .standard)) \(message)", forKey: "lastError")
    }

    public static var lastError: String? { defaults?.string(forKey: "lastError") }
    public static func clear() { defaults?.removeObject(forKey: "lastError") }
}
