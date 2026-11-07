import CryptoKit
import Foundation
import GRDB
import LibSignalClient

/// Tutta la crittografia del client passa da qui: generazione chiavi,
/// registrazione, sessioni 1:1 (PQXDH + Double Ratchet), gruppi (Sender Keys),
/// allegati (AES-256-GCM). Nessun altro modulo tocca libsignal.
public actor CryptoService {
    public static let shared = CryptoService()

    private let store: SignalStore
    private let db: DatabasePool
    private let context = NullContext()
    private var prekeyCounter: UInt32 = 0

    public init(store: SignalStore = SignalStore(), db: DatabasePool = Database.shared.pool) {
        self.store = store
        self.db = db
    }

    // MARK: Registrazione

    public struct RegistrationMaterial: Sendable {
        public let identityKey: String
        public let registrationId: UInt32
        public let signedPrekeyId: UInt32
        public let signedPrekey: String
        public let signedPrekeySignature: String
        public let kyberPrekeyId: UInt32
        public let kyberPrekey: String
        public let kyberPrekeySignature: String
        public let oneTimePrekeys: [PreKeyIn]
    }

    /// Genera identita', signed prekey, kyber prekey e 100 one-time prekey.
    public func prepareRegistration(reuseIdentity: Bool = false) throws -> RegistrationMaterial {
        if !reuseIdentity { try store.bootstrapLocalIdentityIfNeeded() }
        let pair = try store.identityKeyPair(context: context)
        let regId = try store.localRegistrationId(context: context)

        let spkId: UInt32 = 1
        let spkPriv = PrivateKey.generate()
        let spkSig = pair.privateKey.generateSignature(message: spkPriv.publicKey.serialize())
        let spk = try SignedPreKeyRecord(id: spkId, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), privateKey: spkPriv, signature: spkSig)
        try store.storeSignedPreKey(spk, id: spkId, context: context)

        let kpkId: UInt32 = 1
        let kem = KEMKeyPair.generate()
        let kpkSig = pair.privateKey.generateSignature(message: kem.publicKey.serialize())
        let kpk = try KyberPreKeyRecord(id: kpkId, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), keyPair: kem, signature: kpkSig)
        try store.storeKyberPreKey(kpk, id: kpkId, context: context)

        let otps = try generateOneTimePrekeys(count: 100)

        return RegistrationMaterial(
            identityKey: pair.identityKey.serialize().base64EncodedString(),
            registrationId: regId,
            signedPrekeyId: spkId,
            signedPrekey: spkPriv.publicKey.serialize().base64EncodedString(),
            signedPrekeySignature: spkSig.base64EncodedString(),
            kyberPrekeyId: kpkId,
            kyberPrekey: kem.publicKey.serialize().base64EncodedString(),
            kyberPrekeySignature: kpkSig.base64EncodedString(),
            oneTimePrekeys: otps)
    }

    public func generateOneTimePrekeys(count: Int) throws -> [PreKeyIn] {
        var out: [PreKeyIn] = []
        let start = try nextPrekeyId()
        for i in 0..<count {
            let id = start + UInt32(i)
            let priv = PrivateKey.generate()
            try store.storePreKey(try PreKeyRecord(id: id, publicKey: priv.publicKey, privateKey: priv), id: id, context: context)
            out.append(PreKeyIn(keyId: id, publicKey: priv.publicKey.serialize().base64EncodedString()))
        }
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signal_local(key, value) VALUES ('prekey_counter', ?)",
                           arguments: [withUnsafeBytes(of: (start + UInt32(count)).littleEndian) { Data($0) }])
        }
        return out
    }

    private func nextPrekeyId() throws -> UInt32 {
        try db.read { db in
            (try Data.fetchOne(db, sql: "SELECT value FROM signal_local WHERE key = 'prekey_counter'"))
                .map { $0.withUnsafeBytes { $0.load(as: UInt32.self) } } ?? 1
        }
    }

    public func localIdentityFingerprint() throws -> String {
        let pair = try store.identityKeyPair(context: context)
        return Self.fingerprint(pair.identityKey.serialize())
    }

    /// Codice di sicurezza a 8 blocchi da 5 cifre (stesso formato per entrambi i lati).
    public static func fingerprint(_ key: Data) -> String {
        let h = SHA256.hash(data: key)
        let digits = h.map { String(format: "%02d", Int($0) % 100) }.joined()
        return stride(from: 0, to: 40, by: 5).map { String(digits.dropFirst($0).prefix(5)) }.joined(separator: " ")
    }

    // MARK: Sessioni 1:1

    public func ensureSession(with username: String, deviceId: UInt32 = 1) async throws {
        let address = try ProtocolAddress(name: username, deviceId: deviceId)
        if try store.loadSession(for: address, context: context)?.hasCurrentState == true { return }
        let b = try await APIClient.shared.bundle(username: username, deviceId: deviceId)

        guard let idk = Data(base64Encoded: b.identityKey), let spkData = Data(base64Encoded: b.signedPrekey),
              let spkSig = Data(base64Encoded: b.signedPrekeySignature),
              let kid = b.kyberPrekeyId, let kpk = b.kyberPrekey.flatMap({ Data(base64Encoded: $0) }),
              let ksig = b.kyberPrekeySignature.flatMap({ Data(base64Encoded: $0) }) else {
            throw StoreFailure.badBundle  // libsignal 0.106 richiede sempre la kyber prekey (PQXDH)
        }
        let identity = try IdentityKey(bytes: idk)
        let spk = try PublicKey(spkData)
        let kem = try KEMPublicKey(kpk)
        let bundle: PreKeyBundle
        if let oid = b.oneTimePrekeyId, let opk = b.oneTimePrekey.flatMap({ Data(base64Encoded: $0) }) {
            bundle = try PreKeyBundle(registrationId: b.registrationId, deviceId: deviceId,
                                      prekeyId: oid, prekey: try PublicKey(opk),
                                      signedPrekeyId: b.signedPrekeyId, signedPrekey: spk, signedPrekeySignature: spkSig,
                                      identity: identity,
                                      kyberPrekeyId: kid, kyberPrekey: kem, kyberPrekeySignature: ksig)
        } else {
            bundle = try PreKeyBundle(registrationId: b.registrationId, deviceId: deviceId,
                                      signedPrekeyId: b.signedPrekeyId, signedPrekey: spk, signedPrekeySignature: spkSig,
                                      identity: identity,
                                      kyberPrekeyId: kid, kyberPrekey: kem, kyberPrekeySignature: ksig)
        }
        try processPreKeyBundle(bundle, for: address, ourAddress: try localAddress(), sessionStore: store, identityStore: store, context: context)
    }

    private func localAddress() throws -> ProtocolAddress {
        try ProtocolAddress(name: Keychain.string(for: .username) ?? "", deviceId: 1)
    }

    /// Cifra per un destinatario. Restituisce (msg_type, ciphertext) pronti per la busta.
    public func encrypt(_ plaintext: Data, for username: String, deviceId: UInt32 = 1) async throws -> (type: Int, ciphertext: Data) {
        try await ensureSession(with: username, deviceId: deviceId)
        let address = try ProtocolAddress(name: username, deviceId: deviceId)
        let msg = try signalEncrypt(message: plaintext, for: address, localAddress: try localAddress(), sessionStore: store, identityStore: store, context: context)
        return (Int(msg.messageType.rawValue), msg.serialize())
    }

    /// Decifra una busta 1:1 (PreKeySignalMessage o SignalMessage).
    public func decrypt(_ ciphertext: Data, type: Int, from username: String, deviceId: UInt32) throws -> Data {
        let address = try ProtocolAddress(name: username, deviceId: deviceId)
        switch type {
        case Int(CiphertextMessage.MessageType.preKey.rawValue):
            let m = try PreKeySignalMessage(bytes: ciphertext)
            return try signalDecryptPreKey(message: m, from: address, localAddress: try localAddress(), sessionStore: store, identityStore: store,
                                           preKeyStore: store, signedPreKeyStore: store, kyberPreKeyStore: store, context: context)
        case Int(CiphertextMessage.MessageType.whisper.rawValue):
            let m = try SignalMessage(bytes: ciphertext)
            return try signalDecrypt(message: m, from: address, to: try localAddress(), sessionStore: store, identityStore: store, context: context)
        default:
            throw StoreFailure.unsupportedType(type)
        }
    }

    // MARK: Gruppi (Sender Keys)

    public func senderKeyDistribution(for groupId: UUID) throws -> Data {
        let me = try localAddress()
        let skdm = try SenderKeyDistributionMessage(from: me, distributionId: groupId, store: store, context: context)
        return skdm.serialize()
    }

    /// Nuova sender key per il gruppo (dopo uscita o rimozione di un membro).
    public func rotateSenderKey(for groupId: UUID) throws {
        try store.deleteSenderKey(from: try localAddress(), distributionId: groupId)
    }

    public func forgetSenderKey(of username: String, deviceId: UInt32 = 1, groupId: UUID) throws {
        try store.deleteSenderKey(from: try ProtocolAddress(name: username, deviceId: deviceId), distributionId: groupId)
    }

    public func processSenderKeyDistribution(_ data: Data, from username: String, deviceId: UInt32) throws {
        let sender = try ProtocolAddress(name: username, deviceId: deviceId)
        let skdm = try SenderKeyDistributionMessage(bytes: data)
        try processSenderKeyDistributionMessage(skdm, from: sender, store: store, context: context)
    }

    public func groupEncrypt(_ plaintext: Data, groupId: UUID) throws -> Data {
        let me = try localAddress()
        let msg = try LibSignalClient.groupEncrypt(plaintext, from: me, distributionId: groupId, store: store, context: context)
        return msg.serialize()
    }

    public func groupDecrypt(_ ciphertext: Data, from username: String, deviceId: UInt32) throws -> Data {
        let sender = try ProtocolAddress(name: username, deviceId: deviceId)
        return try LibSignalClient.groupDecrypt(ciphertext, from: sender, store: store, context: context)
    }

    // MARK: Allegati

    public struct AttachmentKey: Codable, Sendable {
        public let key: Data
        public let digest: Data
    }

    public static func encryptAttachment(_ plain: Data) throws -> (blob: Data, key: AttachmentKey) {
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(plain, using: key)
        let blob = sealed.combined!
        return (blob, AttachmentKey(key: key.withUnsafeBytes { Data($0) }, digest: Data(SHA256.hash(data: blob))))
    }

    public static func decryptAttachment(_ blob: Data, key: AttachmentKey) throws -> Data {
        guard Data(SHA256.hash(data: blob)) == key.digest else { throw StoreFailure.digestMismatch }
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: SymmetricKey(data: key.key))
    }

    public enum StoreFailure: Error { case unsupportedType(Int), digestMismatch, badBundle }
}
