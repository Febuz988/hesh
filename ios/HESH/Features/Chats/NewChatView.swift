import GRDB
import HESHShared
import SwiftUI

/// Nuova chat 1:1 (per nome utente di un membro ammesso) o nuovo gruppo.
struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var mode = 0
    @State private var username = ""
    @State private var groupName = "Famiglia"
    @State private var members = ""
    @State private var family = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                VStack(alignment: .leading, spacing: 18) {
                    Picker("", selection: $mode) { Text("Chat").tag(0); Text("Gruppo").tag(1) }.pickerStyle(.segmented)
                    if mode == 0 {
                        SectionLabel("Nome utente del membro")
                        field("@nome", text: $username)
                        Text("Deve essere già ammesso in HESH. Il nome utente non dà accesso a chi è fuori.")
                            .font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                    } else {
                        SectionLabel("Nome del gruppo")
                        field("Famiglia", text: $groupName)
                        SectionLabel("Membri, separati da virgola")
                        field("giulia, mamma, papa.g", text: $members)
                        Toggle(isOn: $family) {
                            Label("Cerchio familiare e destinatario SOS", systemImage: "exclamationmark.triangle")
                        }.tint(theme.accent)
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    Spacer()
                    Button { Task { await create() } } label: { if busy { ProgressView() } else { Text(mode == 0 ? "Apri chat" : "Crea gruppo") } }
                        .buttonStyle(PillButtonStyle()).disabled(busy)
                }
                .padding(24)
            }
            .navigationTitle(mode == 0 ? "Nuova chat" : "Nuovo gruppo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 18).frame(height: 54)
            .background(Capsule().fill(Color.primary.opacity(0.06)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.16))))
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            if mode == 0 {
                let u = username.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
                _ = try await APIClient.shared.lookup(username: u)
                try await CryptoService.shared.ensureSession(with: u)
                try await Database.shared.pool.write { db in try Chat.dm(u).save(db) }
            } else {
                let list = members.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "") }.filter { !$0.isEmpty }
                guard !list.isEmpty else { error = "Aggiungi almeno un membro"; return }
                for u in list { _ = try await APIClient.shared.lookup(username: u) }
                _ = try await MessageService.shared.createGroup(name: groupName, members: list, family: family)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ChatInfoView: View {
    let chat: Chat
    @Environment(\.colorScheme) private var scheme
    @Environment(Theme.self) private var theme
    @State private var secret: Bool
    @State private var ephemeral: Int
    @State private var error: String?

    init(chat: Chat) {
        self.chat = chat
        _secret = State(initialValue: chat.isSecret)
        _ephemeral = State(initialValue: chat.ephemeralS ?? 0)
    }

    var body: some View {
        ZStack {
            HESHBackground()
            List {
                Section("Membri") { ForEach(chat.members, id: \.self) { Text($0) } }
                Section("Sicurezza") {
                    if let u = chat.dmUsername { NavigationLink("Verifica codice di sicurezza") { VerifyView(username: u) } }
                    if !chat.isGroup {
                        Toggle(isOn: $secret) { Label("Chat segreta", systemImage: "lock.fill") }.tint(theme.accent)
                            .onChange(of: secret) { _, v in if !v { ephemeral = 0 }; Task { await apply() } }
                    }
                    Picker("Messaggi effimeri", selection: $ephemeral) {
                        Text("Disattivati").tag(0)
                        Text("1 ora").tag(3600)
                        Text("24 ore").tag(86400)
                        Text("7 giorni").tag(604800)
                    }
                    .onChange(of: ephemeral) { _, _ in Task { await apply() } }
                    if secret {
                        Text("Anteprime nascoste nelle notifiche, Face ID per aprire, nessun backup. Non impedisce screenshot dall'altro lato.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(chat.title)
    }

    private func apply() async {
        do {
            if chat.isGroup {
                var c = chat; c.ephemeralS = ephemeral == 0 ? nil : ephemeral
                let u = c
                try await Database.shared.pool.write { db in try u.update(db) }
                var upd = Content(kind: .groupUpdate, chat: chat.id); upd.groupId = chat.groupId?.uuidString; upd.ephemeralS = u.ephemeralS; upd.members = chat.members; upd.name = chat.title
                try await MessageService.shared.send(upd)
            } else {
                try await MessageService.shared.setSecret(chat: chat, secret: secret, ephemeralS: ephemeral == 0 ? nil : ephemeral, lock: secret)
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct VerifyView: View {
    let username: String
    @Environment(Theme.self) private var theme
    @State private var mine = ""
    @State private var theirs = ""
    var body: some View {
        ZStack {
            HESHBackground()
            VStack(spacing: 18) {
                SectionLabel("Il mio codice")
                Text(mine).font(.system(.title3, design: .monospaced))
                SectionLabel("Codice di \(username)")
                Text(theirs).font(.system(.title3, design: .monospaced))
                Text("Confrontateli di persona o per telefono. Se coincidono, la cifratura è tra voi due e nessun altro.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .navigationTitle("Verifica")
        .task {
            mine = (try? await CryptoService.shared.localIdentityFingerprint()) ?? ""
            if let l = try? await APIClient.shared.lookup(username: username), let d = Data(base64Encoded: l.identityKey) {
                theirs = CryptoService.fingerprint(d)
            }
        }
    }
}
