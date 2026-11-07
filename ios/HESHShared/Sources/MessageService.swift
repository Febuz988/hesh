import Foundation
import GRDB

/// Orchestra crittografia, rete e database. Usato da app e NSE.
public actor MessageService {
    public static let shared = MessageService()

    private let crypto = CryptoService.shared
    private let api = APIClient.shared
    private let db = Database.shared.pool

    public var me: String { Keychain.string(for: .username) ?? "" }

    // MARK: Invio

    /// Invia un contenuto a una chat. 1:1: una busta. Gruppo: Sender Key fan-out.
    @discardableResult
    public func send(_ content: Content, priority: String = "normal") async throws -> Message {
        var msg = Message(from: content, sender: me, status: "sending")
        let stored = content.isStoredMessage
        if stored { let m = msg; try await db.write { db in try m.save(db) } }
        do {
            try await sendEnvelopes(for: content, priority: priority)
            msg.status = "sent"
        } catch {
            msg.status = "failed"
            if stored { let m = msg; try? await db.write { db in try m.update(db) } }
            throw error
        }
        if stored {
            let m = msg
            try await db.write { db in
                try m.update(db)
                try db.execute(sql: "UPDATE chat SET last_activity = ? WHERE id = ?", arguments: [m.ts, m.chatId])
            }
        }
        return msg
    }

    /// Conferme di lettura per i messaggi altrui non ancora confermati nella chat.
    public func sendReadReceipts(chat chatId: String) async {
        let ids: [String] = (try? await db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM message WHERE chat_id = ? AND sender != ? AND status = 'received'", arguments: [chatId, me])
        }) ?? []
        guard !ids.isEmpty else { return }
        var c = Content(kind: .read, chat: chatId)
        c.ids = ids
        guard (try? await send(c)) != nil else { return }
        try? await db.write { db in
            for id in ids { try db.execute(sql: "UPDATE message SET status = 'seen' WHERE id = ?", arguments: [id]) }
            try db.execute(sql: "UPDATE chat SET unread = 0 WHERE id = ?", arguments: [chatId])
        }
    }

    /// Attiva o aggiorna la modalita' segreta e i messaggi effimeri di una chat.
    public func setSecret(chat: Chat, secret: Bool, ephemeralS: Int?, lock: Bool) async throws {
        var updated = chat
        updated.isSecret = secret
        updated.ephemeralS = ephemeralS
        let u = updated
        try await db.write { db in try u.update(db) }
        var c = Content(kind: chat.isSecret ? .secretUpdate : .secretStart, chat: chat.id)
        c.ephemeralS = ephemeralS
        c.lock = lock
        try await send(c)
    }

    public static func label(seconds: Int) -> String {
        switch seconds { case 3600: "1 ora"; case 86400: "24 ore"; case 604800: "7 giorni"; default: "\(seconds) s" }
    }

    private func sendEnvelopes(for content: Content, priority: String) async throws {
        let plain = try content.encoded()
        let chat = try await db.read { db in try Chat.fetchOne(db, key: content.chat) }
        guard let chat else { throw ServiceError.unknownChat }

        if let username = chat.dmUsername {
            let (type, ct) = try await crypto.encrypt(plain, for: username)
            try await api.send([EnvelopeOut(toUsername: username, msgType: type, ciphertext: ct.base64EncodedString(), priority: priority)])
            return
        }
        guard let gid = chat.groupId else { throw ServiceError.unknownChat }
        let ct = try await crypto.groupEncrypt(plain, groupId: gid)
        let others = chat.members.filter { $0 != me }
        let envelopes = others.map { EnvelopeOut(toUsername: $0, msgType: 7, ciphertext: ct.base64EncodedString(), priority: priority) }
        try await api.send(envelopes)
    }

    /// Distribuisce la sender key del gruppo a ogni membro (pairwise).
    public func distributeSenderKey(for chat: Chat) async throws {
        guard let gid = chat.groupId else { return }
        let skdm = try await crypto.senderKeyDistribution(for: gid)
        var c = Content(kind: .senderKey, chat: chat.id)
        c.groupId = gid.uuidString
        c.distribution = skdm.base64EncodedString()
        let plain = try c.encoded()
        var envelopes: [EnvelopeOut] = []
        for m in chat.members where m != me {
            let (type, ct) = try await crypto.encrypt(plain, for: m)
            envelopes.append(EnvelopeOut(toUsername: m, msgType: type, ciphertext: ct.base64EncodedString()))
        }
        try await api.send(envelopes)
    }

    // MARK: Ricezione

    /// Svuota la coda REST e applica tutto. Chiamare all'avvio e dalla NSE.
    public func drainQueue() async throws -> [Content] {
        let envs = try await api.fetchEnvelopes()
        var applied: [Content] = []
        var done: [String] = []
        for e in envs {
            do {
                applied.append(try await handle(e))
                done.append(e.id)
            } catch {
                Diagnostics.record("busta da \(e.fromUsername) tipo \(e.msgType): \(error)")
            }
        }
        try await api.ack(done)
        return applied
    }

    /// Decifra e applica una busta. Restituisce il contenuto (per la notifica).
    public func handle(_ e: EnvelopeIn) async throws -> Content {
        guard let ct = Data(base64Encoded: e.ciphertext) else { throw ServiceError.badEnvelope }
        let plain: Data
        if e.msgType == 7 {
            plain = try await crypto.groupDecrypt(ct, from: e.fromUsername, deviceId: e.fromDeviceId)
        } else {
            plain = try await crypto.decrypt(ct, type: e.msgType, from: e.fromUsername, deviceId: e.fromDeviceId)
        }
        var content = try Content.decode(plain)
        // Una chat 1:1 si chiama "dm:<altro>" da ciascun lato: dal mio lato l'altro e' il mittente.
        if content.chat.hasPrefix("dm:") { content.chat = "dm:\(e.fromUsername)" }
        try await apply(content, from: e.fromUsername, deviceId: e.fromDeviceId)
        return content
    }

    private func apply(_ c: Content, from sender: String, deviceId: UInt32) async throws {
        switch c.kind {
        case .senderKey:
            if let d = c.distribution, let data = Data(base64Encoded: d) {
                try await crypto.processSenderKeyDistribution(data, from: sender, deviceId: deviceId)
            }
        case .delete:
            try await db.write { db in
                try db.execute(sql: "UPDATE message SET deleted = 1, body_json = '{}' WHERE id = ? AND chat_id = ? AND sender = ?",
                               arguments: [c.targetId, c.chat, sender])
            }
        case .read:
            try await db.write { db in
                for id in c.ids ?? [] {
                    try db.execute(sql: "UPDATE message SET status = 'read' WHERE id = ? AND status IN ('sent','delivered')", arguments: [id])
                }
            }
        case .typing:
            break
        case .location, .sos:
            if let lat = c.lat, let lon = c.lon {
                let loc = MemberLocation(username: sender, lat: lat, lon: lon, accM: c.accM,
                                         ts: Date(timeIntervalSince1970: TimeInterval(c.ts) / 1000),
                                         liveUntil: c.liveUntilTs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                                         battery: c.battery)
                try await db.write { db in try loc.save(db) }
                if c.kind == .location, c.liveUntilTs == nil { try await storeIncoming(c, from: sender) }
            } else if c.liveUntilTs == 0 {
                try await db.write { db in
                    try db.execute(sql: "UPDATE member_location SET live_until = NULL WHERE username = ?", arguments: [sender])
                }
            }
            if c.kind == .sos { try await storeIncoming(c, from: sender) }
        case .geofence, .checkin:
            if let lat = c.lat, let lon = c.lon {
                let loc = MemberLocation(username: sender, lat: lat, lon: lon, accM: c.accM,
                                         ts: Date(timeIntervalSince1970: TimeInterval(c.ts) / 1000), liveUntil: nil, battery: nil)
                try await db.write { db in try loc.save(db) }
            }
            try await storeIncoming(c, from: sender)
        case .groupCreate, .groupUpdate:
            try await upsertGroup(c)
            if c.kind == .groupCreate {
                // Il nuovo gruppo ha bisogno della nostra sender key verso gli altri.
                if let chat = try await db.read({ db in try Chat.fetchOne(db, key: c.chat) }) {
                    try? await distributeSenderKey(for: chat)
                }
            }
        case .profile:
            try await db.write { db in
                var contact = try Contact.fetchOne(db, key: sender) ?? Contact(username: sender)
                contact.profileKey = c.profileKey.flatMap { Data(base64Encoded: $0) }
                try contact.save(db)
            }
        case .secretStart, .secretUpdate:
            try await db.write { db in
                var chat = try Chat.fetchOne(db, key: c.chat) ?? Chat.dm(sender)
                chat.isSecret = c.kind == .secretStart || c.ephemeralS != nil || c.lock == true
                chat.ephemeralS = c.ephemeralS
                try chat.save(db)
            }
        default:
            try await storeIncoming(c, from: sender)
        }
    }

    private func storeIncoming(_ c: Content, from sender: String) async throws {
        try await db.write { db in
            if try Chat.fetchOne(db, key: c.chat) == nil, c.chat.hasPrefix("dm:") {
                try Chat.dm(sender).save(db)
            }
            let msg = Message(from: c, sender: sender, status: "received")
            if try Chat.fetchOne(db, key: c.chat) == nil { return }
            try msg.save(db)
            try db.execute(sql: "UPDATE chat SET last_activity = ?, unread = unread + 1 WHERE id = ?", arguments: [msg.ts, c.chat])
        }
    }

    private func upsertGroup(_ c: Content) async throws {
        try await db.write { db in
            var chat = try Chat.fetchOne(db, key: c.chat) ?? Chat(id: c.chat, title: c.name ?? "Gruppo", isGroup: true)
            if let n = c.name { chat.title = n }
            if let m = c.members { chat.members = m }
            if let e = c.ephemeralS { chat.ephemeralS = e }
            try chat.save(db)
        }
    }

    // MARK: Gruppi

    public func createGroup(name: String, members: [String], family: Bool) async throws -> Chat {
        let gid = UUID()
        var chat = Chat(id: "g:\(gid.uuidString)", title: name, isGroup: true)
        chat.members = Array(Set(members + [me]))
        chat.isFamily = family
        let newChat = chat
        try await db.write { db in try newChat.save(db) }
        var c = Content(kind: .groupCreate, chat: chat.id)
        c.groupId = gid.uuidString
        c.name = name
        c.members = chat.members
        let plain = try c.encoded()
        var envelopes: [EnvelopeOut] = []
        for m in chat.members where m != me {
            let (type, ct) = try await crypto.encrypt(plain, for: m)
            envelopes.append(EnvelopeOut(toUsername: m, msgType: type, ciphertext: ct.base64EncodedString()))
        }
        try await api.send(envelopes)
        try await distributeSenderKey(for: chat)
        return chat
    }

    // MARK: Manutenzione

    public func purgeExpired() async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM message WHERE expires_at IS NOT NULL AND expires_at < ?", arguments: [Date()])
        }
    }

    public func replenishPrekeysIfNeeded() async {
        guard let (_, low) = try? await api.prekeyCount(), low else { return }
        if let keys = try? await crypto.generateOneTimePrekeys(count: 100) {
            try? await api.replenish(ReplenishRequest(oneTimePrekeys: keys))
        }
    }

    public enum ServiceError: Error { case unknownChat, badEnvelope }
}
