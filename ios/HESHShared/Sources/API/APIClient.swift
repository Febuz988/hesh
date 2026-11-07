import Foundation

public enum APIError: Error, LocalizedError {
    case http(Int, String)
    case unauthorized
    case transport(Error)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let detail): return "Errore \(code): \(detail)"
        case .unauthorized: return "Sessione non valida"
        case .transport(let e): return e.localizedDescription
        case .decoding(let e): return "Risposta non valida: \(e.localizedDescription)"
        }
    }
}

/// Client REST verso il server HESH. Nessuna crittografia qui: trasporta solo
/// buste e chiavi pubbliche gia' preparate da CryptoService.
public actor APIClient {
    public static let shared = APIClient()

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json", auth: Bool = true) async throws -> Data {
        var req = URLRequest(url: HESHConfig.apiBase.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if auth, let token = Keychain.string(for: .sessionToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw APIError.transport(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(code, detail)
        }
        return data
    }

    private func json<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw APIError.decoding(error) }
    }

    // MARK: Register / invites

    public func register(_ body: RegisterRequest) async throws -> RegisterResponse {
        try json(try await request("POST", "register", body: try encoder.encode(body), auth: false))
    }

    public func createInvite(label: String) async throws -> Invite {
        try json(try await request("POST", "invites", body: try encoder.encode(["label": label])))
    }

    public func invites() async throws -> [Invite] {
        try json(try await request("GET", "invites"))
    }

    public func revokeInvite(id: String) async throws {
        _ = try await request("DELETE", "invites/\(id)")
    }

    // MARK: Keys

    public func lookup(username: String) async throws -> UserLookup {
        try json(try await request("GET", "keys/lookup/\(username)"))
    }

    public func bundle(username: String, deviceId: UInt32) async throws -> PreKeyBundleResponse {
        try json(try await request("GET", "keys/bundle/\(username)/\(deviceId)"))
    }

    public func prekeyCount() async throws -> (count: Int, low: Bool) {
        let d: [String: AnyCodable] = try json(try await request("GET", "keys/count"))
        return ((d["one_time_prekeys"]?.value as? Int) ?? 0, (d["low"]?.value as? Bool) ?? false)
    }

    public func replenish(_ body: ReplenishRequest) async throws {
        _ = try await request("PUT", "keys/replenish", body: try encoder.encode(body))
    }

    // MARK: Messages

    public func send(_ envelopes: [EnvelopeOut]) async throws {
        _ = try await request("POST", "messages", body: try encoder.encode(["envelopes": envelopes]))
    }

    public func fetchEnvelopes() async throws -> [EnvelopeIn] {
        try json(try await request("GET", "messages"))
    }

    public func ack(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await request("POST", "messages/ack", body: try encoder.encode(["ids": ids]))
    }

    // MARK: Attachments

    public func upload(encryptedBlob: Data) async throws -> AttachmentUpload {
        try json(try await request("POST", "attachments", body: encryptedBlob, contentType: "application/octet-stream"))
    }

    public func download(attachmentId: String) async throws -> Data {
        try await request("GET", "attachments/\(attachmentId)")
    }

    // MARK: Devices

    public func devices() async throws -> [DeviceInfo] {
        try json(try await request("GET", "devices"))
    }

    public func setAPNs(token: String) async throws {
        _ = try await request("PUT", "devices/me/apns", body: try encoder.encode(["apns_token": token]))
    }

    public func revokeDevice(id: String) async throws {
        _ = try await request("DELETE", "devices/\(id)")
    }

    public func logout() async throws {
        _ = try await request("POST", "devices/me/logout")
    }

    public func deleteAccount() async throws {
        _ = try await request("DELETE", "devices/me/account")
    }
}

/// Minimo per decodificare JSON misti senza tirare dentro una libreria.
public struct AnyCodable: Decodable, Sendable {
    public let value: any Sendable
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else { value = "" }
    }
}
