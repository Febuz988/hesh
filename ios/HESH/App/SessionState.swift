import HESHShared
import SwiftUI
import UIKit
import UserNotifications

/// Stato globale: loggato o no, invito in arrivo, avvio dei servizi.
@Observable
@MainActor
final class SessionState {
    var username: String? = Keychain.string(for: .username)
    var pendingInvite: String?
    var isLocked = false

    var isLoggedIn: Bool { username != nil && Keychain.string(for: .sessionToken) != nil }

    func start() {
        guard isLoggedIn else { return }
        Task {
            _ = try? await MessageService.shared.drainQueue()
            await WSClient.shared.start { env in
                do {
                    _ = try await MessageService.shared.handle(env)
                    await WSClient.shared.ack([env.id])
                } catch MessageService.ServiceError.duplicate {
                    await WSClient.shared.ack([env.id])
                } catch {
                    Diagnostics.record("busta da \(env.fromUsername) tipo \(env.msgType): \(error)")
                }
            }
            await MessageService.shared.replenishPrekeysIfNeeded()
            try? await MessageService.shared.purgeExpired()
            if let last = await Recovery.shared.lastUpload, Date().timeIntervalSince(last) < 86400 { } else { try? await Recovery.shared.uploadBackup() }
        }
        Task { await requestPush() }
    }

    func stop() {
        Task { await WSClient.shared.stop() }
    }

    private func requestPush() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func logout() {
        Task { try? await APIClient.shared.logout() }
        stop()
        Keychain.wipe()
        username = nil
    }
}
