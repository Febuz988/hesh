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
            let (secret, muted) = await chatFlags(c.chat)
            let prefs = UserDefaults(suiteName: HESHConfig.appGroup)
            let previews = (prefs?.object(forKey: "notif.previews") as? Bool ?? true) && !secret
            let ringtone = prefs?.string(forKey: "notif.ringtone") ?? "pulse"
            let groupsOn = prefs?.object(forKey: "notif.groups") as? Bool ?? true
            let messagesOn = prefs?.object(forKey: "notif.messages") as? Bool ?? true
            best?.title = chatTitle
            best?.threadIdentifier = c.chat
            if c.kind != .sos {
                if muted || (c.chat.hasPrefix("g:") && !groupsOn) || (c.chat.hasPrefix("dm:") && !messagesOn) {
                    best?.sound = nil
                    best?.interruptionLevel = .passive
                } else {
                    best?.sound = ringtone == "silent" ? nil : UNNotificationSound(named: UNNotificationSoundName("\(ringtone).wav"))
                }
            }
            switch c.kind {
            case .sos:
                best?.title = "SOS · \(chatTitle)"
                best?.body = "Qualcuno della famiglia ha chiesto aiuto. Apri per vedere la posizione."
                best?.interruptionLevel = .timeSensitive
                best?.sound = UNNotificationSound(named: UNNotificationSoundName("sos.wav"))
            case .sosResolved:
                best?.body = "Emergenza rientrata"
            case .text:
                best?.body = previews ? (c.body ?? "Nuovo messaggio") : "Nuovo messaggio"
            case .attachment:
                best?.body = previews ? (c.isImage ? "Foto" : c.isVoice ? "Messaggio vocale" : (c.name ?? "Allegato")) : "Nuovo messaggio"
            case .contactRequest:
                best?.body = "\(c.chat.dropFirst(3)) vuole aggiungerti ai contatti"
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

    private func chatFlags(_ id: String) async -> (Bool, Bool) {
        (try? await Database.shared.pool.read { db in
            let c = try Chat.fetchOne(db, key: id)
            return (c?.isSecret ?? false, c?.muted ?? false)
        }) ?? (false, false)
    }
}
