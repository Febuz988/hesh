import Foundation
import GRDB

/// Orchestra crittografia, rete e database. Usato da app e NSE.
public actor MessageService {
    public static let shared = MessageService()

    private let crypto = CryptoService.shared
    private let api = APIClient.shared
    private let db = Database.shared.pool

    public var me: String { Keychain.string(for: .username) ?? "" }

    /// Segnalazione chiamate: impostato dall'app (CallKit vive nel target app, non qui).
    /// Nella NSE resta nil e le buste di chiamata vengono ignorate.
    public var callHandler: (@Sendable (Content, String) async -> Void)?
    public func setCallHandler(_ h: (@Sendable (Content, String) async -> Void)?) { callHandler = h }

    // MARK: Invio

    /// Invia un contenuto a una chat. 1:1: una busta. Gruppo: Sender Key fan-out.
    @discardableResult
    public func send(_ content: Content, priority: String? = nil) async throws -> Message {
        var msg = Message(from: content, sender: me, status: "sending")
        let stored = content.isStoredMessage
        if stored { let m = msg; try await db.write { db in try m.save(db) } }
        do {
            try await sendEnvelopes(for: content, priority: priority ?? content.envelopePriority)
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
        let myName = me
        let ids: [String] = (try? await db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM message WHERE chat_id = ? AND sender != ? AND status = 'received'", arguments: [chatId, myName])
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
            envelopes.append(EnvelopeOut(toUsername: m, msgType: type, ciphertext: ct.base64EncodedString(), priority: "silent"))
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
            } catch ServiceError.duplicate {
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
        // Dedup: la stessa busta puo' arrivare da WebSocket e da coda REST.
        let seen = try await db.read { db in try Row.fetchOne(db, sql: "SELECT 1 FROM processed_envelope WHERE id = ?", arguments: [e.id]) != nil }
        if seen { throw ServiceError.duplicate }
        let plain: Data
        do {
            if e.msgType == 7 {
                plain = try await crypto.groupDecrypt(ct, from: e.fromUsername, deviceId: e.fromDeviceId)
            } else {
                plain = try await crypto.decrypt(ct, type: e.msgType, from: e.fromUsername, deviceId: e.fromDeviceId)
            }
        } catch {
            if "\(error)".contains("duplicatedMessage") { throw ServiceError.duplicate }
            throw error
        }
        try await db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO processed_envelope(id, ts) VALUES (?, ?)", arguments: [e.id, Date()])
            try db.execute(sql: "DELETE FROM processed_envelope WHERE ts < ?", arguments: [Date().addingTimeInterval(-7 * 86400)])
        }
        var content = try Content.decode(plain)
        // Una chat 1:1 si chiama "dm:<altro>" da ciascun lato: dal mio lato l'altro e' il mittente.
        if content.chat.hasPrefix("dm:") { content.chat = "dm:\(e.fromUsername)" }
        try await apply(content, from: e.fromUsername, deviceId: e.fromDeviceId)
        return content
    }

    private func apply(_ c: Content, from sender: String, deviceId: UInt32) async throws {
        if await SocialService.shared.isBlocked(sender), c.kind != .contactRequest { return }
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
                if c.kind == .location, c.liveUntilTs == nil || c.event != nil { try await storeIncoming(c, from: sender) }
            } else if c.liveUntilTs == 0 {
                try await db.write { db in
                    try db.execute(sql: "UPDATE member_location SET live_until = NULL WHERE username = ?", arguments: [sender])
                }
                if c.event != nil { try await storeIncoming(c, from: sender) }
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
            try await upsertGroup(c, from: sender)
            if c.kind == .groupCreate || (c.members?.contains(me) == true && c.kind == .groupUpdate) {
                // Il nuovo gruppo ha bisogno della nostra sender key verso gli altri.
                if let chat = try await db.read({ db in try Chat.fetchOne(db, key: c.chat) }) {
                    try? await distributeSenderKey(for: chat)
                }
            }
        case .profile:
            await SocialService.shared.applyIncomingProfile(c, from: sender)
        case .contactRequest, .contactAccept, .contactBlock:
            await SocialService.shared.applyIncomingContact(c, from: sender)
        case .callOffer, .callAnswer, .callIce:
            await callHandler?(c, sender)
        case .callEnd:
            try await storeIncoming(c, from: sender)
            await callHandler?(c, sender)
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

    private func upsertGroup(_ c: Content, from sender: String) async throws {
        let me = self.me
        if let m = c.members, !m.contains(me) {
            // Sono stato rimosso o ho lasciato: la chat sparisce, le chiavi del gruppo pure.
            if let gid = c.groupId.flatMap(UUID.init(uuidString:)) { for u in m { try? await crypto.forgetSenderKey(of: u, groupId: gid) } }
            try await db.write { db in try db.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [c.chat]) }
            return
        }
        let previous = try await db.read { db in try Chat.fetchOne(db, key: c.chat) }
        try await db.write { db in
            var chat = previous ?? Chat(id: c.chat, title: c.name ?? "Gruppo", isGroup: true)
            if let n = c.name { chat.title = n }
            if let m = c.members { chat.members = m }
            chat.ephemeralS = c.ephemeralS
            if c.kind == .groupCreate { chat.owner = sender }
            if let o = c.scope { chat.owner = o }
            if let a = c.ids { chat.admins = a }
            try chat.save(db)
        }
        // Un membro e' uscito: la sua sender key non vale piu'.
        if let prev = previous, let m = c.members, let gid = c.groupId.flatMap(UUID.init(uuidString:)) {
            for gone in Set(prev.members).subtracting(m) { try? await crypto.forgetSenderKey(of: gone, groupId: gid) }
        }
    }

    // MARK: Gruppi

    public func createGroup(name: String, members: [String], family: Bool) async throws -> Chat {
        let gid = UUID()
        var chat = Chat(id: "g:\(gid.uuidString)", title: name, isGroup: true)
        chat.members = Array(Set(members + [me]))
        chat.isFamily = family
        chat.owner = me
        let newChat = chat
        try await db.write { db in try newChat.save(db) }
        var c = Content(kind: .groupCreate, chat: chat.id)
        c.groupId = gid.uuidString
        c.name = name
        c.members = chat.members
        c.scope = me
        let plain = try c.encoded()
        var envelopes: [EnvelopeOut] = []
        for m in chat.members where m != me {
            let (type, ct) = try await crypto.encrypt(plain, for: m)
            envelopes.append(EnvelopeOut(toUsername: m, msgType: type, ciphertext: ct.base64EncodedString()))
        }
        try await api.send(envelopes)
        try await distributeSenderKey(for: chat)
        Task { try? await Recovery.shared.uploadBackup() }
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

    public enum ServiceError: Error { case unknownChat, badEnvelope, duplicate }
}
