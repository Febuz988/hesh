import HESHShared
import SwiftUI
import UIKit
import UserNotifications

/// Stato globale: loggato o no, invito in arrivo, avvio dei servizi.
@Observable
@MainActor
final class SessionState {
    var username: String?
    var pendingInvite: String?
    var isLocked = false

    init() {
        // Il Keychain sopravvive alla disinstallazione, il database e UserDefaults no.
        // Prima apertura dopo un'installazione: stato pulito, altrimenti si entra con
        // un token valido ma senza chiavi Signal.
        if !UserDefaults.standard.bool(forKey: "hesh.installed") {
            // Se il database c'e' ancora e' un aggiornamento, non una reinstallazione.
            if !FileManager.default.fileExists(atPath: HESHConfig.databaseURL.path) { Keychain.wipe() }
            UserDefaults.standard.set(true, forKey: "hesh.installed")
        }
        username = Keychain.string(for: .username)
    }

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

    /// App tornata in primo piano: WS fresco e coda svuotata via REST.
    func resume() {
        guard isLoggedIn else { return }
        Task {
            await WSClient.shared.reconnect()
            _ = try? await MessageService.shared.drainQueue()
        }
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
