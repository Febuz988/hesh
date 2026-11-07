import HESHShared
import SwiftUI
import UserNotifications

@main
struct HESHApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionState()
    @State private var theme = Theme()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(theme)
                .preferredColorScheme(theme.mode.colorScheme)
                .onOpenURL { url in session.pendingInvite = InviteLink.parse(url) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await APIClient.shared.setAPNs(token: hex) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        _ = try? await MessageService.shared.drainQueue()
        return .newData
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

/// Parsing di `hesh://invite/<token>` e `https://hesh.it/i/<token>`.
enum InviteLink {
    static func parse(_ url: URL) -> String? {
        if url.scheme == HESHConfig.urlScheme, url.host == "invite" {
            return url.pathComponents.dropFirst().first
        }
        if url.host == HESHConfig.universalLinkHost, url.pathComponents.count >= 3, url.pathComponents[1] == "i" {
            return url.pathComponents[2]
        }
        return nil
    }
}
