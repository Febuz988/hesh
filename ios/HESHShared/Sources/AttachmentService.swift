import CryptoKit
import Foundation
import GRDB

/// Allegati: cifrati con AES-256-GCM sul dispositivo, caricati come blob
/// opachi, chiave e digest viaggiano dentro il messaggio cifrato.
/// Cache locale in App Group, protetta da Data Protection.
public actor AttachmentService {
    public static let shared = AttachmentService()

    private let api = APIClient.shared
    private var dir: URL { HESHConfig.attachmentsDir }

    public struct Upload: Sendable {
        public let attId: String
        public let key: String      // b64 della chiave AES
        public let digest: String   // b64 SHA-256 del blob
        public let size: Int
    }

    /// Cifra, carica, salva in cache locale (in chiaro, con Data Protection) e
    /// restituisce i campi da mettere nel Content.
    public func upload(_ plain: Data) async throws -> Upload {
        let (blob, key) = try CryptoService.encryptAttachment(plain)
        let res = try await api.upload(encryptedBlob: blob)
        try cache(plain, for: res.id)
        return Upload(attId: res.id, key: key.key.base64EncodedString(), digest: key.digest.base64EncodedString(), size: plain.count)
    }

    /// Restituisce il file in chiaro dalla cache o lo scarica e lo decifra.
    public func fetch(attId: String, key: String, digest: String) async throws -> URL {
        let url = cacheURL(attId)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let k = Data(base64Encoded: key), let d = Data(base64Encoded: digest) else { throw AttachmentError.badKey }
        let blob = try await api.download(attachmentId: attId)
        let plain = try CryptoService.decryptAttachment(blob, key: .init(key: k, digest: d))
        try cache(plain, for: attId)
        return url
    }

    public func cacheURL(_ attId: String) -> URL { dir.appendingPathComponent(attId) }

    private func cache(_ data: Data, for attId: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: cacheURL(attId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func purgeCache(olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    public enum AttachmentError: Error { case badKey }
}

public extension Content {
    static func attachment(chat: String, up: AttachmentService.Upload, mime: String, name: String?, caption: String?, durationS: Double?, ephemeralS: Int?) -> Content {
        var c = Content(kind: .attachment, chat: chat)
        c.attId = up.attId; c.key = up.key; c.digest = up.digest; c.size = up.size
        c.mime = mime; c.name = name; c.caption = caption; c.durationS = durationS; c.ephemeralS = ephemeralS
        return c
    }

    var isImage: Bool { mime?.hasPrefix("image/") == true }
    var isVideo: Bool { mime?.hasPrefix("video/") == true }
    var isAudio: Bool { mime?.hasPrefix("audio/") == true }
    var isVoice: Bool { isAudio && name == nil }
}
