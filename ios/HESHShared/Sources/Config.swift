import Foundation

public enum HESHConfig {
    public static let apiBase = URL(string: "https://api.hesh.it")!
    public static let wsBase = URL(string: "wss://api.hesh.it")!
    public static let appGroup = "group.it.hesh"
    public static let keychainService = "it.hesh.app"
    public static let universalLinkHost = "hesh.it"
    public static let urlScheme = "hesh"

    /// Cartella condivisa tra app e Notification Service Extension.
    public static var sharedContainer: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            fatalError("App Group \(appGroup) non configurato: controlla gli entitlements")
        }
        return url
    }

    public static var databaseURL: URL { sharedContainer.appendingPathComponent("hesh.sqlite") }
    public static var attachmentsDir: URL { sharedContainer.appendingPathComponent("attachments", isDirectory: true) }
}
