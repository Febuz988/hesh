import Foundation
import os

/// Ultimo errore di decifratura/consegna, visibile nell'app. Mai contenuti:
/// solo mittente, tipo busta e descrizione dell'errore.
public enum Diagnostics {
    private static let log = Logger(subsystem: "it.hesh.app", category: "messages")
    private static var defaults: UserDefaults? { UserDefaults(suiteName: HESHConfig.appGroup) }

    public static func record(_ message: String) {
        log.error("\(message, privacy: .public)")
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)"
        defaults?.set(line, forKey: "lastError")
        var h = history
        h.append(line)
        if h.count > 60 { h.removeFirst(h.count - 60) }
        defaults?.set(h, forKey: "diag.history")
    }

    public static var lastError: String? { defaults?.string(forKey: "lastError") }
    public static var history: [String] { defaults?.stringArray(forKey: "diag.history") ?? [] }
    public static func clear() { defaults?.removeObject(forKey: "lastError") }
    public static func clearHistory() { defaults?.removeObject(forKey: "diag.history"); clear() }
}
