import Foundation
import Security

/// Keychain condiviso app/NSE. Nessuna ACL biometrica: la NSE deve leggere
/// senza utente presente. Face ID protegge l'interfaccia, non queste voci.
public enum Keychain {
    public enum Key: String {
        case sessionToken
        case username
        case userId
        case profileKey
    }

    public enum KeychainError: Error { case status(OSStatus) }

    private static func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HESHConfig.keychainService,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: HESHConfig.appGroup,
        ]
    }

    public static func set(_ data: Data, for key: Key) throws {
        var q = query(key)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func set(_ string: String, for key: Key) throws {
        try set(Data(string.utf8), for: key)
    }

    public static func data(for key: Key) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    public static func string(for key: Key) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func delete(_ key: Key) {
        SecItemDelete(query(key) as CFDictionary)
    }

    public static func wipe() {
        [Key.sessionToken, .username, .userId, .profileKey].forEach(delete)
    }
}
