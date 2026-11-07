import HESHShared
import LocalAuthentication
import SwiftUI

struct RootView: View {
    @Environment(SessionState.self) private var session
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if session.isLoggedIn {
                MainTabView()
                    .onAppear { session.start() }
            } else {
                WelcomeView()
            }
        }
        .overlay { if session.isLocked { LockScreen() } }
        .onChange(of: phase) { _, new in
            if new == .background, session.isLoggedIn { session.isLocked = true }
            if new == .active, session.isLocked { unlock() }
        }
    }

    private func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { session.isLocked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Sblocca HESH") { ok, _ in
            Task { @MainActor in session.isLocked = !ok }
        }
    }
}

struct LockScreen: View {
    var body: some View {
        ZStack {
            HESHBackground()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .light))
                Text("HESH").font(.system(size: 28, weight: .bold, design: .rounded)).tracking(4)
            }
        }
    }
}

struct MainTabView: View {
    @Environment(Theme.self) private var theme
    var body: some View {
        TabView {
            ChatsView().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            CallsPlaceholderView().tabItem { Label("Chiamate", systemImage: "phone") }
            SOSView().tabItem { Label("SOS", systemImage: "exclamationmark.triangle") }
            MapPlaceholderView().tabItem { Label("Mappa", systemImage: "map") }
            ProfileView().tabItem { Label("Io", systemImage: "person.crop.circle") }
        }
        .tint(theme.accent)
    }
}

struct CallsPlaceholderView: View {
    var body: some View {
        ZStack { HESHBackground(); Text("Chiamate: milestone 4").foregroundStyle(.secondary) }
    }
}

struct MapPlaceholderView: View {
    var body: some View {
        ZStack { HESHBackground(); Text("Mappa famiglia: milestone 5").foregroundStyle(.secondary) }
    }
}
