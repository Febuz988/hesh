import Foundation
import GRDB

public struct Chat: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "chat"
    public var id: String
    public var title: String
    public var isGroup: Bool
    public var isSecret: Bool = false
    public var ephemeralS: Int?
    public var muted: Bool = false
    public var isFamily: Bool = false
    public var membersJson: String = "[]"
    public var lastActivity: Date?
    public var unread: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, title, isGroup = "is_group", isSecret = "is_secret", ephemeralS = "ephemeral_s", muted
        case isFamily = "is_family", membersJson = "members_json", lastActivity = "last_activity", unread
    }

    public var members: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(membersJson.utf8))) ?? [] }
        set { membersJson = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    public init(id: String, title: String, isGroup: Bool, isSecret: Bool = false, ephemeralS: Int? = nil, muted: Bool = false,
                isFamily: Bool = false, membersJson: String = "[]", lastActivity: Date? = nil, unread: Int = 0) {
        self.id = id; self.title = title; self.isGroup = isGroup; self.isSecret = isSecret; self.ephemeralS = ephemeralS
        self.muted = muted; self.isFamily = isFamily; self.membersJson = membersJson; self.lastActivity = lastActivity; self.unread = unread
    }

    public var dmUsername: String? { id.hasPrefix("dm:") ? String(id.dropFirst(3)) : nil }
    public var groupId: UUID? { id.hasPrefix("g:") ? UUID(uuidString: String(id.dropFirst(2))) : nil }

    public static func dm(_ username: String) -> Chat {
        Chat(id: "dm:\(username)", title: username, isGroup: false, membersJson: "[\"\(username)\"]")
    }
}

public struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "message"
    public var id: String
    public var chatId: String
    public var sender: String
    public var kind: String
    public var bodyJson: String
    public var ts: Date
    public var status: String
    public var deleted: Bool = false
    public var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, chatId = "chat_id", sender, kind, bodyJson = "body_json", ts, status, deleted, expiresAt = "expires_at"
    }

    public var content: Content? { try? Content.decode(Data(bodyJson.utf8)) }

    public init(from content: Content, sender: String, status: String) {
        id = content.id
        chatId = content.chat
        self.sender = sender
        kind = content.kind.rawValue
        bodyJson = String(data: (try? content.encoded()) ?? Data(), encoding: .utf8) ?? "{}"
        ts = Date(timeIntervalSince1970: TimeInterval(content.ts) / 1000)
        self.status = status
        if let e = content.ephemeralS { expiresAt = ts.addingTimeInterval(TimeInterval(e)) }
    }
}

public struct Contact: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "contact"
    public var username: String
    public var displayName: String?
    public var profileKey: Data?
    public var avatarPath: String?
    public var verified: Bool = false
    public var blocked: Bool = false
    public var keyChanged: Bool = false
    public var id: String { username }
    public init(username: String) { self.username = username }

    enum CodingKeys: String, CodingKey {
        case username, displayName = "display_name", profileKey = "profile_key", avatarPath = "avatar_path", verified, blocked, keyChanged = "key_changed"
    }
}

public struct MemberLocation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "member_location"
    public var username: String
    public var lat: Double
    public var lon: Double
    public var accM: Double?
    public var ts: Date
    public var liveUntil: Date?
    public var battery: Double?
    public var id: String { username }
    enum CodingKeys: String, CodingKey { case username, lat, lon, accM = "acc_m", ts, liveUntil = "live_until", battery }
    public init(username: String, lat: Double, lon: Double, accM: Double?, ts: Date, liveUntil: Date?, battery: Double?) {
        self.username = username; self.lat = lat; self.lon = lon; self.accM = accM; self.ts = ts; self.liveUntil = liveUntil; self.battery = battery
    }

    public var isStale: Bool { Date().timeIntervalSince(ts) > 300 }
}

public struct Place: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "place"
    public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    public var radiusM: Double
    public var notify: Bool = true
    enum CodingKeys: String, CodingKey { case id, name, lat, lon, radiusM = "radius_m", notify }
    public init(id: String, name: String, lat: Double, lon: Double, radiusM: Double, notify: Bool = true) {
        self.id = id; self.name = name; self.lat = lat; self.lon = lon; self.radiusM = radiusM; self.notify = notify
    }
}
