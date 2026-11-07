import Foundation

/// Contenuto in chiaro dentro la busta cifrata. Vedi ios/Protocol.md.
public struct Content: Codable, Sendable {
    public var v: Int = 1
    public var id: String
    public var ts: Int64
    public var kind: Kind
    public var chat: String

    // campi opzionali per kind
    public var body: String?
    public var replyTo: String?
    public var ephemeralS: Int?
    public var attId: String?
    public var key: String?
    public var digest: String?
    public var mime: String?
    public var size: Int?
    public var name: String?
    public var caption: String?
    public var durationS: Double?
    public var lat: Double?
    public var lon: Double?
    public var accM: Double?
    public var liveUntilTs: Int64?
    public var audioAtt: String?
    public var sosId: String?
    public var place: String?
    public var event: String?
    public var targetId: String?
    public var scope: String?
    public var ids: [String]?
    public var profileKey: String?
    public var avatarAtt: String?
    public var birthday: String?
    public var groupId: String?
    public var members: [String]?
    public var distribution: String?
    public var lock: Bool?
    public var battery: Double?

    public enum Kind: String, Codable, Sendable {
        case text, attachment, location, sos, sosResolved = "sos_resolved", geofence, checkin
        case delete, read, typing, profile
        case contactRequest = "contact_request", contactAccept = "contact_accept", contactBlock = "contact_block"
        case groupCreate = "group_create", groupUpdate = "group_update", senderKey = "sender_key"
        case secretStart = "secret_start", secretUpdate = "secret_update", keyChangeAck = "key_change_ack"
    }

    enum CodingKeys: String, CodingKey {
        case v, id, ts, kind, chat, body
        case replyTo = "reply_to", ephemeralS = "ephemeral_s", attId = "att_id", key, digest, mime, size, name, caption
        case durationS = "duration_s", lat, lon, accM = "acc_m", liveUntilTs = "live_until_ts", audioAtt = "audio_att"
        case sosId = "sos_id", place, event, targetId = "target_id", scope, ids, profileKey = "profile_key"
        case avatarAtt = "avatar_att", birthday, groupId = "group_id", members, distribution, lock, battery
    }

    public init(kind: Kind, chat: String) {
        self.id = ULID.new()
        self.ts = Int64(Date().timeIntervalSince1970 * 1000)
        self.kind = kind
        self.chat = chat
    }

    public static func text(_ body: String, chat: String, ephemeralS: Int? = nil) -> Content {
        var c = Content(kind: .text, chat: chat)
        c.body = body
        c.ephemeralS = ephemeralS
        return c
    }

    public static func sos(chat: String, lat: Double?, lon: Double?, accM: Double?) -> Content {
        var c = Content(kind: .sos, chat: chat)
        c.lat = lat; c.lon = lon; c.accM = accM
        return c
    }

    public static func location(chat: String, lat: Double, lon: Double, accM: Double?, liveUntil: Date?, battery: Double?) -> Content {
        var c = Content(kind: .location, chat: chat)
        c.lat = lat; c.lon = lon; c.accM = accM; c.battery = battery
        c.liveUntilTs = liveUntil.map { Int64($0.timeIntervalSince1970 * 1000) }
        return c
    }

    public static func delete(targetId: String, chat: String, everyone: Bool) -> Content {
        var c = Content(kind: .delete, chat: chat)
        c.targetId = targetId
        c.scope = everyone ? "everyone" : "me"
        return c
    }

    public var isSOS: Bool { kind == .sos }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Content { try JSONDecoder().decode(Content.self, from: data) }
}

/// ULID: ordinabile per tempo, senza dipendenze.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static func new() -> String {
        var ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var time = [Character](repeating: "0", count: 10)
        for i in (0..<10).reversed() { time[i] = alphabet[Int(ms & 31)]; ms >>= 5 }
        let rand = (0..<16).map { _ in alphabet[Int.random(in: 0..<32)] }
        return String(time + rand)
    }
}
