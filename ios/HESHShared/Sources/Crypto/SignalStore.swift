import Foundation
import GRDB
import LibSignalClient

/// Implementazione dei protocolli *Store di libsignal su GRDB.
/// NOTA: le firme dei protocolli variano tra versioni di libsignal; questa
/// implementazione segue la 0.8x. Se il compilatore segnala differenze,
/// adattare le firme qui, non altrove.
public final class SignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore, SenderKeyStore, @unchecked Sendable {
    private let db: DatabasePool

    public init(db: DatabasePool = Database.shared.pool) {
        self.db = db
    }

    public enum StoreError: Error { case missingIdentity, missingRecord(String) }

    private static func key(_ a: ProtocolAddress) -> String { "\(a.name).\(a.deviceId)" }

    // MARK: Identita' locale

    public func bootstrapLocalIdentityIfNeeded() throws {
        try db.write { db in
            if try Row.fetchOne(db, sql: "SELECT 1 FROM signal_local WHERE key = 'identity_key_pair'") == nil {
                let pair = IdentityKeyPair.generate()
                let regId = UInt32.random(in: 1...16380)
                try db.execute(sql: "INSERT INTO signal_local(key, value) VALUES ('identity_key_pair', ?)", arguments: [pair.serialize()])
                try db.execute(sql: "INSERT INTO signal_local(key, value) VALUES ('registration_id', ?)", arguments: [withUnsafeBytes(of: regId.littleEndian) { Data($0) }])
            }
        }
    }

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM signal_local WHERE key = 'identity_key_pair'") else {
                throw StoreError.missingIdentity
            }
            return try IdentityKeyPair(bytes: data)
        }
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM signal_local WHERE key = 'registration_id'") else {
                throw StoreError.missingIdentity
            }
            return data.withUnsafeBytes { $0.load(as: UInt32.self) }
        }
    }

    // MARK: IdentityKeyStore

    public func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        try db.write { db in
            let k = Self.key(address)
            let existing = try Data.fetchOne(db, sql: "SELECT identity_key FROM signal_identity WHERE address = ?", arguments: [k])
            let new = identity.serialize()
            if let existing {
                if existing == new { return .newOrUnchanged }
                try db.execute(sql: "UPDATE signal_identity SET identity_key = ? WHERE address = ?", arguments: [new, k])
                try db.execute(sql: "UPDATE contact SET key_changed = 1, verified = 0 WHERE username = ?", arguments: [address.name])
                return .replacedExisting
            }
            try db.execute(sql: "INSERT INTO signal_identity(address, identity_key, first_seen) VALUES (?, ?, ?)", arguments: [k, new, Date()])
            return .newOrUnchanged
        }
    }

    public func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        // Trust on first use; dopo un cambio di chiave la UI chiede verifica ma non blocca la ricezione.
        try db.read { db in
            guard let existing = try Data.fetchOne(db, sql: "SELECT identity_key FROM signal_identity WHERE address = ?", arguments: [Self.key(address)]) else {
                return true
            }
            return existing == identity.serialize() || direction == .receiving
        }
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT identity_key FROM signal_identity WHERE address = ?", arguments: [Self.key(address)])
                .map { try IdentityKey(bytes: $0) }
        }
    }

    // MARK: PreKeyStore

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try db.read { db in
            guard let d = try Data.fetchOne(db, sql: "SELECT record FROM signal_prekey WHERE id = ?", arguments: [id]) else {
                throw StoreError.missingRecord("prekey \(id)")
            }
            return try PreKeyRecord(bytes: d)
        }
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signal_prekey(id, record) VALUES (?, ?)", arguments: [id, record.serialize()])
        }
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM signal_prekey WHERE id = ?", arguments: [id]) }
    }

    // MARK: SignedPreKeyStore

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try db.read { db in
            guard let d = try Data.fetchOne(db, sql: "SELECT record FROM signal_signed_prekey WHERE id = ?", arguments: [id]) else {
                throw StoreError.missingRecord("signed prekey \(id)")
            }
            return try SignedPreKeyRecord(bytes: d)
        }
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signal_signed_prekey(id, record) VALUES (?, ?)", arguments: [id, record.serialize()])
        }
    }

    // MARK: KyberPreKeyStore

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try db.read { db in
            guard let d = try Data.fetchOne(db, sql: "SELECT record FROM signal_kyber_prekey WHERE id = ?", arguments: [id]) else {
                throw StoreError.missingRecord("kyber prekey \(id)")
            }
            return try KyberPreKeyRecord(bytes: d)
        }
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signal_kyber_prekey(id, record, used) VALUES (?, ?, 0)", arguments: [id, record.serialize()])
        }
    }

    public func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        try db.write { db in try db.execute(sql: "UPDATE signal_kyber_prekey SET used = 1 WHERE id = ?", arguments: [id]) }
    }

    // MARK: SessionStore

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT record FROM signal_session WHERE address = ?", arguments: [Self.key(address)])
                .map { try SessionRecord(bytes: $0) }
        }
    }

    public func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.compactMap { try loadSession(for: $0, context: context) }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signal_session(address, record) VALUES (?, ?)", arguments: [Self.key(address), record.serialize()])
        }
    }

    // MARK: SenderKeyStore

    public func storeSenderKey(from sender: ProtocolAddress, distributionId: UUID, record: SenderKeyRecord, context: StoreContext) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO signal_sender_key(key, record) VALUES (?, ?)",
                           arguments: ["\(Self.key(sender))/\(distributionId.uuidString)", record.serialize()])
        }
    }

    public func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID, context: StoreContext) throws -> SenderKeyRecord? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT record FROM signal_sender_key WHERE key = ?", arguments: ["\(Self.key(sender))/\(distributionId.uuidString)"])
                .map { try SenderKeyRecord(bytes: $0) }
        }
    }
}
