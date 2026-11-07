import GRDB
import HESHShared
import SwiftUI

struct MyAvatar: View {
    var size: CGFloat = 40
    @Environment(SessionState.self) private var session
    var body: some View {
        if let path = UserDefaults(suiteName: HESHConfig.appGroup)?.string(forKey: "profile.avatarPath"), let img = UIImage(contentsOfFile: path) {
            Image(uiImage: img).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
        } else {
            Avatar(name: session.username ?? "?", size: size)
        }
    }
}

struct ProfileView: View {
    @Environment(SessionState.self) private var session
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var fingerprint = ""
    @State private var confirmDelete = false
    @State private var pendingRequests = 0
    @State private var observer: DatabaseCancellable?

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                List {
                    Section {
                        VStack(spacing: 10) {
                            MyAvatar(size: 96)
                            Text("@\(session.username ?? "")").font(.system(size: 24, weight: .bold, design: .rounded))
                            Label(fingerprint, systemImage: "lock.fill").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.heshMuted(scheme))
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                    Section("Impostazioni") {
                        NavigationLink { ProfileEditView() } label: { Label("Profilo e compleanno", systemImage: "person.crop.circle") }
                        NavigationLink { ContactsView() } label: {
                            HStack { Label("Contatti e richieste", systemImage: "person.2"); Spacer()
                                if pendingRequests > 0 { Text("\(pendingRequests)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.heshInk).padding(.horizontal, 7).frame(minHeight: 22).background(Capsule().fill(theme.accent)) } }
                        }
                        NavigationLink { InvitesView() } label: { Label("Inviti", systemImage: "qrcode") }
                        NavigationLink { DevicesView() } label: { Label("Dispositivi collegati", systemImage: "laptopcomputer.and.iphone") }
                        NavigationLink { NotificationSettingsView() } label: { Label("Notifiche e suoni", systemImage: "bell") }
                        NavigationLink { ThemesView() } label: { Label("Aspetto e temi", systemImage: "circle.lefthalf.filled") }
                    }
                    Section {
                        Button("Esci da questo dispositivo") { session.logout() }
                        Button("Elimina account", role: .destructive) { confirmDelete = true }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Io")
            .task { fingerprint = (try? await CryptoService.shared.localIdentityFingerprint()) ?? "" }
            .onAppear {
                observer = ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contact WHERE status = 'pending_in'") ?? 0 }
                    .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { pendingRequests = $0 })
            }
            .confirmationDialog("Eliminare l'account? L'azione è definitiva. I messaggi già consegnati restano sui dispositivi degli altri.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina definitivamente", role: .destructive) {
                    Task { try? await APIClient.shared.deleteAccount(); await MainActor.run { session.logout() } }
                }
            }
        }
    }
}

struct InvitesView: View {
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var invites: [Invite] = []
    @State private var fresh: Invite?
    @State private var label = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            HESHBackground()
            List {
                if let fresh, let link = fresh.link {
                    Section {
                        VStack(spacing: 14) {
                            QRCodeView(text: link).frame(width: 200, height: 200)
                            Text("Invito monouso · scade in 24 h").font(.system(size: 13)).foregroundStyle(Color.heshMuted(scheme))
                            ShareLink(item: URL(string: "https://\(HESHConfig.universalLinkHost)/i/\(fresh.token ?? "")")!) {
                                Label("Condividi link", systemImage: "link")
                            }
                            .buttonStyle(PillButtonStyle())
                            Text("Il link vale una volta sola. Chi lo riceve lo può inoltrare: condividilo solo con chi vuoi davvero dentro.")
                                .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    TextField("Per chi è (facoltativo)", text: $label)
                    Button("Nuovo invito all'app") { Task { await create() } }
                }
                Section("I miei inviti") {
                    ForEach(invites) { inv in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(inv.label.isEmpty ? "Senza destinatario" : inv.label).font(.system(size: 15, weight: .semibold))
                                Text(inv.expiresAt.prefix(16).replacingOccurrences(of: "T", with: " ")).font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                            }
                            Spacer()
                            Text(status(inv.status)).font(.system(size: 12, weight: .semibold)).foregroundStyle(inv.status == "active" ? theme.accent : Color.heshMuted(scheme))
                        }
                        .swipeActions { if inv.status == "active" { Button("Revoca", role: .destructive) { Task { await revoke(inv) } } } }
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Inviti")
        .task { await load() }
    }

    private func status(_ s: String) -> String {
        ["active": "Attivo", "used": "Usato", "expired": "Scaduto", "revoked": "Revocato"][s] ?? s
    }

    private func load() async { invites = (try? await APIClient.shared.invites()) ?? [] }
    private func create() async {
        do { fresh = try await APIClient.shared.createInvite(label: label); label = ""; await load() }
        catch { self.error = error.localizedDescription }
    }
    private func revoke(_ inv: Invite) async {
        try? await APIClient.shared.revokeInvite(id: inv.id)
        await load()
    }
}

struct DevicesView: View {
    @State private var devices: [DeviceInfo] = []
    var body: some View {
        ZStack {
            HESHBackground()
            List(devices) { d in
                HStack {
                    VStack(alignment: .leading) {
                        Text(d.name).font(.system(size: 15, weight: .semibold))
                        Text(d.current ? "Questo dispositivo" : "Ultimo accesso \(d.lastSeenAt.prefix(16))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !d.current { Button("Revoca", role: .destructive) { Task { try? await APIClient.shared.revokeDevice(id: d.id); devices = (try? await APIClient.shared.devices()) ?? [] } } }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Dispositivi")
        .task { devices = (try? await APIClient.shared.devices()) ?? [] }
    }
}

struct ThemesView: View {
    @Environment(Theme.self) private var theme
    var body: some View {
        @Bindable var theme = theme
        ZStack {
            HESHBackground()
            List {
                Section("Modalità") {
                    Picker("Modalità", selection: $theme.mode) { ForEach(Theme.Mode.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.inline).labelsHidden()
                }
                Section("HESH Originals") {
                    HStack(spacing: 12) {
                        ForEach(Theme.Original.allCases) { o in
                            Button { theme.original = o } label: {
                                VStack(spacing: 8) {
                                    Circle().fill(o.color).frame(width: 36, height: 36).shadow(color: o.color.opacity(0.6), radius: 10)
                                    Text(o.label).font(.system(size: 12, weight: theme.original == o ? .bold : .regular))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(theme.original == o ? 0.1 : 0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.original == o ? o.color : Color.primary.opacity(0.12))))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Accessibilità") {
                    Toggle("Riduci trasparenze e animazioni", isOn: $theme.reduceGlass)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Aspetto e temi")
    }
}
