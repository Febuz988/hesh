import CommonCrypto
import CryptoKit
import Foundation
import GRDB
import LibSignalClient

/// Frase di recupero (12 parole BIP39, 128 bit di entropia) e backup cifrato.
/// Il backup contiene l'identita' Signal, la profile key e i metadati locali;
/// il server ne vede solo il blob.
public actor Recovery {
    public static let shared = Recovery()

    private let db = Database.shared.pool
    private let store = SignalStore()

    public enum RecoveryError: Error, LocalizedError {
        case wordlist, badPhrase, badBackup, noBackup
        public var errorDescription: String? {
            switch self {
            case .wordlist: "Lista parole non disponibile"
            case .badPhrase: "Frase non valida: controlla le 12 parole"
            case .badBackup: "Backup non decifrabile: parole sbagliate?"
            case .noBackup: "Nessun backup sul server per questo account"
            }
        }
    }

    // MARK: Parole

    private static var words: [String] = {
        guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt") ?? Bundle(for: SignalStore.self).url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
    }()

    /// Genera 12 parole da 128 bit con checksum BIP39 (4 bit).
    public func generatePhrase() throws -> [String] {
        guard Self.words.count == 2048 else { throw RecoveryError.wordlist }
        var entropy = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &entropy)
        return try Self.phrase(from: entropy)
    }

    static func phrase(from entropy: [UInt8]) throws -> [String] {
        let hash = SHA256.hash(data: Data(entropy))
        var bits = entropy.flatMap { b in (0..<8).reversed().map { (b >> $0) & 1 } }
        let first = Array(hash)[0]
        bits += (0..<4).reversed().map { (first >> (4 + $0)) & 1 }   // 4 bit di checksum
        return stride(from: 0, to: 132, by: 11).map { i in
            let idx = bits[i..<i + 11].reduce(0) { $0 << 1 | Int($1) }
            return words[idx]
        }
    }

    /// Valida le parole e restituisce l'entropia (verifica checksum).
    public static func entropy(from phrase: [String]) throws -> [UInt8] {
        guard words.count == 2048, phrase.count == 12 else { throw RecoveryError.badPhrase }
        var bits: [UInt8] = []
        for w in phrase {
            guard let idx = words.firstIndex(of: w.lowercased().trimmingCharacters(in: .whitespaces)) else { throw RecoveryError.badPhrase }
            bits += (0..<11).reversed().map { UInt8((idx >> $0) & 1) }
        }
        let entropy = stride(from: 0, to: 128, by: 8).map { i in bits[i..<i + 8].reduce(0) { $0 << 1 | $1 } }
        let check = Array(bits[128..<132])
        let hash = Array(SHA256.hash(data: Data(entropy)))[0]
        let expected = (0..<4).reversed().map { (hash >> (4 + $0)) & 1 }
        guard check == expected else { throw RecoveryError.badPhrase }
        return entropy
    }

    /// Chiave AES-256 dal segreto: PBKDF2-HMAC-SHA256, 600k iterazioni, sale legato al nome utente.
    static func backupKey(entropy: [UInt8], username: String) -> SymmetricKey {
        let salt = Array("hesh-backup-v1:\(username)".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), entropy.map { Int8(bitPattern: $0) }, entropy.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &out, 32)
        return SymmetricKey(data: Data(out))
    }

    // MARK: Contenuto del backup

    struct Payload: Codable {
        var v = 1
        var username: String
        var identityKeyPair: Data
        var registrationId: UInt32
        var profileKey: Data?
        var chats: [Chat]
        var contacts: [Contact]
        var places: [Place]
        var createdAt: Date
    }

    private var defaults: UserDefaults? { UserDefaults(suiteName: HESHConfig.appGroup) }

    /// La frase e' custodita dall'utente; qui ne teniamo solo l'entropia nel Keychain
    /// per poter aggiornare il backup senza richiederla. Face ID la protegge alla visualizzazione.
    public func savePhraseLocally(_ phrase: [String]) throws {
        let e = try Self.entropy(from: phrase)
        try Keychain.set(Data(e), for: .recoveryEntropy)
    }

    public func localPhrase() -> [String]? {
        guard let e = Keychain.data(for: .recoveryEntropy) else { return nil }
        return try? Self.phrase(from: [UInt8](e))
    }

    public var hasPhrase: Bool { Keychain.data(for: .recoveryEntropy) != nil }

    /// Costruisce, cifra e carica il backup. Chiamare dopo registrazione e dopo
    /// cambi a chat, contatti, luoghi, profilo.
    public func uploadBackup() async throws {
        guard let e = Keychain.data(for: .recoveryEntropy), let username = Keychain.string(for: .username) else { return }
        let pair = try store.identityKeyPair(context: NullContext())
        let regId = try store.localRegistrationId(context: NullContext())
        let (chats, contacts, places) = try await db.read { db in
            (try Chat.fetchAll(db), try Contact.fetchAll(db), try Place.fetchAll(db))
        }
        let payload = Payload(username: username, identityKeyPair: pair.serialize(), registrationId: regId,
                              profileKey: Keychain.data(for: .profileKey), chats: chats, contacts: contacts, places: places, createdAt: Date())
        let plain = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(plain, using: Self.backupKey(entropy: [UInt8](e), username: username))
        try await APIClient.shared.putBackup(sealed.combined!)
        defaults?.set(Date(), forKey: "backup.lastUpload")
    }

    /// Data locale dell'ultimo caricamento riuscito (veloce, puo' mancare dopo una reinstallazione).
    public var lastUpload: Date? { defaults?.object(forKey: "backup.lastUpload") as? Date }

    /// Data dell'ultimo backup secondo il server: la verita'. nil = nessun backup.
    public func serverBackupDate() async -> Date? {
        guard let meta = try? await APIClient.shared.backupMeta() else { return nil }
        defaults?.set(meta.updatedAt, forKey: "backup.lastUpload")
        return meta.updatedAt
    }

    /// Nuovo dispositivo: dopo il login con passkey, scarica e ripristina con le 12 parole,
    /// poi riprovisiona le chiavi sul server.
    public func restore(phrase: [String], username: String) async throws {
        let e = try Self.entropy(from: phrase)
        let blob = try await APIClient.shared.getBackup()
        let key = Self.backupKey(entropy: e, username: username)
        guard let box = try? AES.GCM.SealedBox(combined: blob), let plain = try? AES.GCM.open(box, using: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: plain), payload.username == username else {
            throw RecoveryError.badBackup
        }
        try store.installLocalIdentity(serializedPair: payload.identityKeyPair, registrationId: payload.registrationId)
        if let pk = payload.profileKey { try Keychain.set(pk, for: .profileKey) }
        try Keychain.set(Data(e), for: .recoveryEntropy)
        try await db.write { db in
            for var c in payload.chats { c.unread = 0; try c.save(db) }
            for c in payload.contacts { var cc = c; cc.avatarPath = nil; try cc.save(db) }
            for p in payload.places { try p.save(db) }
        }
        // Prekey nuove, stessa identita'.
        let m = try await CryptoService.shared.prepareRegistration(reuseIdentity: true)
        try await APIClient.shared.reprovision(m)
        try Keychain.set(username, for: .username)
        defaults?.set(payload.createdAt, forKey: "backup.lastUpload")
    }
}
