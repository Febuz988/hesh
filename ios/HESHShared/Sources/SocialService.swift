import CryptoKit
import Foundation
import GRDB

/// Contatti, profilo (avatar cifrato con profile key, compleanno) e gestione gruppi.
public actor SocialService {
    public static let shared = SocialService()

    private let db = Database.shared.pool
    private let messages = MessageService.shared
    private let crypto = CryptoService.shared

    private var me: String { Keychain.string(for: .username) ?? "" }

    // MARK: Profile key

    public func profileKey() throws -> Data {
        if let k = Keychain.data(for: .profileKey) { return k }
        let k = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try Keychain.set(k, for: .profileKey)
        return k
    }

    public struct MyProfile: Sendable {
        public var birthday: String?
        public var birthdayVisibility: String   // circle | contacts | nobody
        public var avatarPath: String?
    }

    private var defaults: UserDefaults? { UserDefaults(suiteName: HESHConfig.appGroup) }

    public func myProfile() -> MyProfile {
        MyProfile(birthday: defaults?.string(forKey: "profile.birthday"),
                  birthdayVisibility: defaults?.string(forKey: "profile.birthdayVisibility") ?? "circle",
                  avatarPath: defaults?.string(forKey: "profile.avatarPath"))
    }

    /// Salva avatar/compleanno e li propaga a tutti i contatti e membri di gruppo.
    public func updateProfile(avatarJPEG: Data?, birthday: String?, birthdayVisibility: String) async throws {
        let key = try profileKey()
        var avatarAttId: String?
        if let avatarJPEG {
            let sealed = try AES.GCM.seal(avatarJPEG, using: SymmetricKey(data: key)).combined!
            let res = try await APIClient.shared.upload(encryptedBlob: sealed)
            avatarAttId = res.id
            let path = HESHConfig.attachmentsDir.appendingPathComponent("avatar-me.jpg")
            try FileManager.default.createDirectory(at: HESHConfig.attachmentsDir, withIntermediateDirectories: true)
            try avatarJPEG.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defaults?.set(path.path, forKey: "profile.avatarPath")
            defaults?.set(avatarAttId, forKey: "profile.avatarAtt")
        }
        defaults?.set(birthday, forKey: "profile.birthday")
        defaults?.set(birthdayVisibility, forKey: "profile.birthdayVisibility")
        try await broadcastProfile()
        Task { try? await Recovery.shared.uploadBackup() }
    }

    public func broadcastProfile() async throws {
        let key = try profileKey()
        let avatarAtt = defaults?.string(forKey: "profile.avatarAtt")
        let birthday = defaults?.string(forKey: "profile.birthday")
        let visibility = defaults?.string(forKey: "profile.birthdayVisibility") ?? "circle"
        for user in try await recipients() {
            var c = Content(kind: .profile, chat: "dm:\(user)")
            c.profileKey = key.base64EncodedString()
            c.avatarAtt = avatarAtt
            c.birthday = visibility == "nobody" ? nil : birthday
            try? await sendDM(c, to: user)
        }
    }

    /// Tutti gli utenti con cui abbiamo una chat o un gruppo.
    private func recipients() async throws -> [String] {
        let chats = try await db.read { db in try Chat.fetchAll(db) }
        var set = Set<String>()
        for c in chats { if let u = c.dmUsername { set.insert(u) } else { c.members.forEach { set.insert($0) } } }
        set.remove(me)
        let blocked = try await db.read { db in try String.fetchAll(db, sql: "SELECT username FROM contact WHERE blocked = 1") }
        return Array(set.subtracting(blocked))
    }

    private func sendDM(_ content: Content, to user: String) async throws {
        let plain = try content.encoded()
        let (type, ct) = try await crypto.encrypt(plain, for: user)
        try await APIClient.shared.send([EnvelopeOut(toUsername: user, msgType: type, ciphertext: ct.base64EncodedString())])
    }

    /// Chiamato da MessageService quando arriva un .profile: scarica e decifra l'avatar.
    public func applyIncomingProfile(_ c: Content, from sender: String) async {
        guard let pk = c.profileKey.flatMap({ Data(base64Encoded: $0) }) else { return }
        var path: String?
        if let att = c.avatarAtt, let blob = try? await APIClient.shared.download(attachmentId: att),
           let box = try? AES.GCM.SealedBox(combined: blob), let jpeg = try? AES.GCM.open(box, using: SymmetricKey(data: pk)) {
            let url = HESHConfig.attachmentsDir.appendingPathComponent("avatar-\(sender).jpg")
            try? FileManager.default.createDirectory(at: HESHConfig.attachmentsDir, withIntermediateDirectories: true)
            if (try? jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil { path = url.path }
        }
        let birthday = c.birthday
        try? await db.write { db in
            var contact = try Contact.fetchOne(db, key: sender) ?? Contact(username: sender)
            contact.profileKey = pk
            if let path { contact.avatarPath = path }
            contact.birthday = birthday
            try contact.save(db)
        }
    }

    // MARK: Richieste di contatto

    public func requestContact(_ username: String) async throws {
        _ = try await APIClient.shared.lookup(username: username)
        try await crypto.ensureSession(with: username)
        try await db.write { db in
            var c = try Contact.fetchOne(db, key: username) ?? Contact(username: username)
            if c.status != "accepted" { c.status = "pending_out" }
            try c.save(db)
        }
        try await sendDM(Content(kind: .contactRequest, chat: "dm:\(username)"), to: username)
    }

    public func acceptContact(_ username: String) async throws {
        try await db.write { db in
            var c = try Contact.fetchOne(db, key: username) ?? Contact(username: username)
            c.status = "accepted"
            c.blocked = false
            try c.save(db)
            if try Chat.fetchOne(db, key: "dm:\(username)") == nil { try Chat.dm(username).save(db) }
        }
        try await sendDM(Content(kind: .contactAccept, chat: "dm:\(username)"), to: username)
        try? await broadcastProfile()
        Task { try? await Recovery.shared.uploadBackup() }
    }

    public func declineContact(_ username: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM contact WHERE username = ? AND status = 'pending_in'", arguments: [username]) }
    }

    public func setBlocked(_ username: String, blocked: Bool) async throws {
        try await db.write { db in
            var c = try Contact.fetchOne(db, key: username) ?? Contact(username: username)
            c.blocked = blocked
            if blocked { c.status = "none" }
            try c.save(db)
        }
        if blocked { try? await sendDM(Content(kind: .contactBlock, chat: "dm:\(username)"), to: username) }
    }

    public func applyIncomingContact(_ c: Content, from sender: String) async {
        try? await db.write { db in
            var contact = try Contact.fetchOne(db, key: sender) ?? Contact(username: sender)
            switch c.kind {
            case .contactRequest:
                if contact.status == "pending_out" || contact.status == "accepted" {
                    contact.status = "accepted"
                    if try Chat.fetchOne(db, key: "dm:\(sender)") == nil { try Chat.dm(sender).save(db) }
                } else if contact.status != "accepted" {
                    contact.status = "pending_in"
                }
            case .contactAccept:
                contact.status = "accepted"
                if try Chat.fetchOne(db, key: "dm:\(sender)") == nil { try Chat.dm(sender).save(db) }
            case .contactBlock:
                contact.status = "none"
            default: break
            }
            try contact.save(db)
        }
        if c.kind == .contactRequest {
            if let st = try? await db.read({ db in try Contact.fetchOne(db, key: sender)?.status }), st == "accepted" {
                try? await sendDM(Content(kind: .contactAccept, chat: "dm:\(sender)"), to: sender)
            }
        }
    }

    public func isBlocked(_ username: String) async -> Bool {
        (try? await db.read { db in try Contact.fetchOne(db, key: username)?.blocked }) ?? false
    }

    // MARK: Gruppi: membri e ruoli

    public func updateGroup(_ chat: Chat, name: String? = nil, addMembers: [String] = [], removeMembers: [String] = [],
                            setAdmin: (String, Bool)? = nil, family: Bool? = nil) async throws {
        guard let gid = chat.groupId, chat.canManage(me) else { throw SocialError.notAllowed }
        var updated = chat
        if let name { updated.title = name }
        var members = Set(updated.members)
        addMembers.forEach { members.insert($0) }
        removeMembers.forEach { members.remove($0) }
        updated.members = Array(members)
        if let (u, admin) = setAdmin {
            var a = Set(updated.admins)
            if admin { a.insert(u) } else { a.remove(u) }
            updated.admins = Array(a)
        }
        if let family { updated.isFamily = family }
        let u = updated
        try await db.write { db in try u.update(db) }

        var c = Content(kind: .groupUpdate, chat: chat.id)
        c.groupId = gid.uuidString
        c.name = updated.title
        c.members = updated.members
        c.ids = updated.admins          // ids riusato per gli admin
        c.scope = updated.owner
        c.ephemeralS = updated.ephemeralS
        let plain = try c.encoded()
        // Anche i rimossi ricevono l'aggiornamento, cosi' sanno di essere fuori.
        for user in (members.union(removeMembers)).subtracting([me]) {
            let (type, ct) = try await crypto.encrypt(plain, for: user)
            try? await APIClient.shared.send([EnvelopeOut(toUsername: user, msgType: type, ciphertext: ct.base64EncodedString())])
        }
        if !removeMembers.isEmpty || !addMembers.isEmpty {
            try await crypto.rotateSenderKey(for: gid)
            try await messages.distributeSenderKey(for: updated)
        }
        Task { try? await Recovery.shared.uploadBackup() }
    }

    public func leaveGroup(_ chat: Chat) async throws {
        guard let gid = chat.groupId else { return }
        var c = Content(kind: .groupUpdate, chat: chat.id)
        c.groupId = gid.uuidString
        c.name = chat.title
        c.members = chat.members.filter { $0 != me }
        c.ids = chat.admins.filter { $0 != me }
        c.scope = chat.owner == me ? (c.members?.first) : chat.owner   // il proprietario che esce passa il gruppo al primo
        c.ephemeralS = chat.ephemeralS
        let plain = try c.encoded()
        for user in chat.members where user != me {
            let (type, ct) = try await crypto.encrypt(plain, for: user)
            try? await APIClient.shared.send([EnvelopeOut(toUsername: user, msgType: type, ciphertext: ct.base64EncodedString())])
        }
        try await db.write { db in try db.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [chat.id]) }
    }

    public enum SocialError: Error { case notAllowed }
}
