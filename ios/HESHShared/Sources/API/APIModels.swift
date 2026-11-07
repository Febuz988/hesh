import Foundation

// Specchio di server/app/schemas.py. Binari in base64.

public struct PreKeyIn: Codable, Sendable {
    public var keyId: UInt32
    public var publicKey: String
    enum CodingKeys: String, CodingKey { case keyId = "key_id", publicKey = "public_key" }
    public init(keyId: UInt32, publicKey: String) { self.keyId = keyId; self.publicKey = publicKey }
}

public struct RegisterRequest: Codable, Sendable {
    public var inviteToken: String
    public var username: String
    public var deviceName: String
    public var identityKey: String
    public var registrationId: UInt32
    public var signedPrekeyId: UInt32
    public var signedPrekey: String
    public var signedPrekeySignature: String
    public var kyberPrekeyId: UInt32?
    public var kyberPrekey: String?
    public var kyberPrekeySignature: String?
    public var oneTimePrekeys: [PreKeyIn]
    public var apnsToken: String?
    enum CodingKeys: String, CodingKey {
        case inviteToken = "invite_token", username, deviceName = "device_name"
        case identityKey = "identity_key", registrationId = "registration_id"
        case signedPrekeyId = "signed_prekey_id", signedPrekey = "signed_prekey", signedPrekeySignature = "signed_prekey_signature"
        case kyberPrekeyId = "kyber_prekey_id", kyberPrekey = "kyber_prekey", kyberPrekeySignature = "kyber_prekey_signature"
        case oneTimePrekeys = "one_time_prekeys", apnsToken = "apns_token"
    }
}

public struct RegisterResponse: Codable, Sendable {
    public var userId: String
    public var username: String
    public var deviceId: UInt32
    public var token: String
    enum CodingKeys: String, CodingKey { case userId = "user_id", username, deviceId = "device_id", token }
}

public struct Invite: Codable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var status: String
    public var createdAt: String
    public var expiresAt: String
    public var token: String?
    public var link: String?
    enum CodingKeys: String, CodingKey { case id, label, status, createdAt = "created_at", expiresAt = "expires_at", token, link }
}

public struct PreKeyBundleResponse: Codable, Sendable {
    public var userId: String
    public var username: String
    public var deviceId: UInt32
    public var registrationId: UInt32
    public var identityKey: String
    public var signedPrekeyId: UInt32
    public var signedPrekey: String
    public var signedPrekeySignature: String
    public var kyberPrekeyId: UInt32?
    public var kyberPrekey: String?
    public var kyberPrekeySignature: String?
    public var oneTimePrekeyId: UInt32?
    public var oneTimePrekey: String?
    enum CodingKeys: String, CodingKey {
        case userId = "user_id", username, deviceId = "device_id", registrationId = "registration_id"
        case identityKey = "identity_key", signedPrekeyId = "signed_prekey_id", signedPrekey = "signed_prekey"
        case signedPrekeySignature = "signed_prekey_signature", kyberPrekeyId = "kyber_prekey_id"
        case kyberPrekey = "kyber_prekey", kyberPrekeySignature = "kyber_prekey_signature"
        case oneTimePrekeyId = "one_time_prekey_id", oneTimePrekey = "one_time_prekey"
    }
}

public struct ReplenishRequest: Codable, Sendable {
    public var oneTimePrekeys: [PreKeyIn]
    enum CodingKeys: String, CodingKey { case oneTimePrekeys = "one_time_prekeys" }
    public init(oneTimePrekeys: [PreKeyIn]) { self.oneTimePrekeys = oneTimePrekeys }
}

public struct UserLookup: Codable, Sendable {
    public var userId: String
    public var username: String
    public var identityKey: String
    public var devices: [UInt32]
    enum CodingKeys: String, CodingKey { case userId = "user_id", username, identityKey = "identity_key", devices }
}

public struct EnvelopeOut: Codable, Sendable {
    public var toUsername: String
    public var toDeviceId: UInt32
    public var msgType: Int
    public var ciphertext: String
    public var priority: String
    enum CodingKeys: String, CodingKey { case toUsername = "to_username", toDeviceId = "to_device_id", msgType = "msg_type", ciphertext, priority }
    public init(toUsername: String, toDeviceId: UInt32 = 1, msgType: Int, ciphertext: String, priority: String = "normal") {
        self.toUsername = toUsername; self.toDeviceId = toDeviceId; self.msgType = msgType; self.ciphertext = ciphertext; self.priority = priority
    }
}

public struct EnvelopeIn: Codable, Sendable, Identifiable {
    public var id: String
    public var fromUsername: String
    public var fromDeviceId: UInt32
    public var msgType: Int
    public var ciphertext: String
    public var priority: String
    public var createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, fromUsername = "from_username", fromDeviceId = "from_device_id", msgType = "msg_type", ciphertext, priority, createdAt = "created_at"
    }
}

public struct DeviceInfo: Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: UInt32
    public var name: String
    public var createdAt: String
    public var lastSeenAt: String
    public var current: Bool
    enum CodingKeys: String, CodingKey { case id, deviceId = "device_id", name, createdAt = "created_at", lastSeenAt = "last_seen_at", current }
}

public struct AttachmentUpload: Codable, Sendable {
    public var id: String
    public var size: Int
    public var expiresAt: String
    enum CodingKeys: String, CodingKey { case id, size, expiresAt = "expires_at" }
}
