import HESHShared
import UserNotifications

/// La push non contiene contenuto. La NSE scarica la coda, decifra con lo store
/// condiviso e compone titolo e corpo. Il DB e' apribile dopo il primo sblocco
/// del dispositivo (Data Protection completeUntilFirstUserAuthentication).
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        best = (request.content.mutableCopy() as? UNMutableNotificationContent)
        let isSOS = (request.content.userInfo["hesh"] as? [String: Any])?["kind"] as? String == "sos"

        Task {
            defer { deliver() }
            guard let contents = try? await MessageService.shared.drainQueue(), let c = contents.last(where: { $0.kind != .typing && $0.kind != .read }) else {
                best?.body = isSOS ? "SOS dalla famiglia" : "Nuovo messaggio"
                return
            }
            let chatTitle = await chatTitle(for: c.chat)
            let secret = await isSecret(c.chat)
            best?.title = chatTitle
            best?.threadIdentifier = c.chat
            switch c.kind {
            case .sos:
                best?.title = "SOS · \(chatTitle)"
                best?.body = "Qualcuno della famiglia ha chiesto aiuto. Apri per vedere la posizione."
                best?.interruptionLevel = .timeSensitive
                best?.sound = UNNotificationSound(named: UNNotificationSoundName("sos.caf"))
            case .sosResolved:
                best?.body = "Emergenza rientrata"
            case .text:
                best?.body = secret ? "Nuovo messaggio" : (c.body ?? "Nuovo messaggio")
            case .attachment:
                best?.body = "Allegato"
            case .location:
                best?.body = "Posizione condivisa"
            case .geofence:
                best?.body = c.event == "enter" ? "è arrivato a \(c.place ?? "")" : "ha lasciato \(c.place ?? "")"
            case .checkin:
                best?.body = "è arrivato"
            case .groupCreate:
                best?.body = "Sei stato aggiunto al gruppo \(c.name ?? "")"
            default:
                best?.body = "Nuovo messaggio"
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        best?.body = "Nuovo messaggio"
        deliver()
    }

    private func deliver() {
        if let best, let handler { handler(best) }
        handler = nil
    }

    private func chatTitle(for id: String) async -> String {
        (try? await Database.shared.pool.read { db in try Chat.fetchOne(db, key: id)?.title }) ?? "HESH"
    }

    private func isSecret(_ id: String) async -> Bool {
        (try? await Database.shared.pool.read { db in try Chat.fetchOne(db, key: id)?.isSecret }) ?? false
    }
}
