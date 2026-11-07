import HESHShared
import SwiftUI
import UIKit
import UserNotifications

/// Stato globale: loggato o no, invito in arrivo, avvio dei servizi.
@Observable
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
                _ = try? await MessageService.shared.handle(env)
                await WSClient.shared.ack([env.id])
            }
            await MessageService.shared.replenishPrekeysIfNeeded()
            try? await MessageService.shared.purgeExpired()
        }
        Task { await requestPush() }
    }

    func stop() {
        Task { await WSClient.shared.stop() }
    }

    @MainActor
    private func requestPush() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    @MainActor
    func logout() {
        Task { try? await APIClient.shared.logout() }
        stop()
        Keychain.wipe()
        username = nil
    }
}
