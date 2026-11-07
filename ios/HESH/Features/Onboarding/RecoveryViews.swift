import HESHShared
import LocalAuthentication
import SwiftUI

/// Mostrata subito dopo la registrazione: 12 parole da custodire, poi passkey.
struct RecoverySetupView: View {
    let onDone: () -> Void
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var phrase: [String] = []
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    @State private var passkeyDone = false

    var body: some View {
        ZStack {
            HESHBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Le tue 12 parole").font(.system(size: 30, weight: .bold, design: .rounded)).padding(.top, 20)
                    Text("Sono l'unico modo per recuperare i messaggi su un nuovo iPhone. HESH non le conserva e non può rigenerarle. Scrivile su carta.")
                        .font(.system(size: 14)).foregroundStyle(Color.heshMuted(scheme))
                    PhraseGrid(words: phrase)
                    Toggle("Le ho scritte in un posto sicuro", isOn: $confirmed).tint(theme.accent)
                    Button { Task { await savePhrase() } } label: { if busy { ProgressView().tint(.black) } else { Text("Conferma e crea il backup") } }
                        .buttonStyle(PillButtonStyle()).disabled(!confirmed || busy || phrase.isEmpty)

                    Divider().padding(.vertical, 6)
                    Text("Passkey").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Per accedere da un nuovo iPhone senza password: resta nel portachiavi iCloud, Face ID la sblocca.")
                        .font(.system(size: 14)).foregroundStyle(Color.heshMuted(scheme))
                    Button(passkeyDone ? "Passkey creata" : "Crea passkey") { Task { await createPasskey() } }
                        .buttonStyle(PillButtonStyle(filled: false)).disabled(passkeyDone)
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    Button("Continua") { onDone() }.buttonStyle(PillButtonStyle(filled: false)).padding(.top, 6)
                }
                .padding(24)
            }
        }
        .navigationBarBackButtonHidden()
        .task { phrase = (try? await Recovery.shared.generatePhrase()) ?? [] }
    }

    private func savePhrase() async {
        busy = true
        defer { busy = false }
        do {
            try await Recovery.shared.savePhraseLocally(phrase)
            try await Recovery.shared.uploadBackup()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func createPasskey() async {
        do { try await PasskeyManager.shared.createPasskey(); passkeyDone = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct PhraseGrid: View {
    let words: [String]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).frame(width: 18, alignment: .trailing)
                    Text(w).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.07)))
            }
        }
        .textSelection(.enabled)
    }
}

/// Nuovo iPhone: passkey → backup → 12 parole → ripristino.
struct RestoreView: View {
    @Environment(SessionState.self) private var session
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var username = ""
    @State private var step = 0
    @State private var words = Array(repeating: "", count: 12)
    @State private var busy = false
    @State private var error: String?
    @State private var pending: RegisterResponse?

    var body: some View {
        ZStack {
            HESHBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if step == 0 {
                        Text("Accedi con passkey").font(.system(size: 30, weight: .bold, design: .rounded))
                        SectionLabel("Nome utente")
                        HStack(spacing: 6) {
                            Text("@").foregroundStyle(Color.heshMuted(scheme))
                            TextField("nome", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 18, weight: .semibold))
                        }
                        .padding(.horizontal, 18).frame(height: 58)
                        .background(Capsule().fill(Color.primary.opacity(0.06)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.16))))
                        Button { Task { await login() } } label: { if busy { ProgressView().tint(.black) } else { Label("Continua con passkey", systemImage: "person.badge.key") } }
                            .buttonStyle(PillButtonStyle()).disabled(username.count < 3 || busy)
                    } else {
                        Text("Le tue 12 parole").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Servono per decifrare il backup. Scrivile nell'ordine giusto.").font(.system(size: 14)).foregroundStyle(Color.heshMuted(scheme))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                            ForEach(0..<12, id: \.self) { i in
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).frame(width: 18, alignment: .trailing)
                                    TextField("parola", text: $words[i]).textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 15, weight: .semibold, design: .rounded))
                                }
                                .padding(.horizontal, 10).frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.07)))
                            }
                        }
                        Button("Incolla le 12 parole") { if let s = UIPasteboard.general.string { let w = s.lowercased().split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init); if w.count == 12 { words = w } } }
                            .font(.system(size: 13)).foregroundStyle(theme.accent)
                        Button { Task { await restore() } } label: { if busy { ProgressView().tint(.black) } else { Text("Ripristina") } }
                            .buttonStyle(PillButtonStyle()).disabled(words.contains(where: \.isEmpty) || busy)
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    Text("Questo iPhone sostituirà il precedente: il vecchio smette di ricevere messaggi. Le chat vengono ripristinate senza cronologia.")
                        .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme))
                }
                .padding(24)
            }
        }
        .navigationTitle("Recupero")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func login() async {
        busy = true
        defer { busy = false }
        do {
            let u = username.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
            let res = try await PasskeyManager.shared.login(username: u)
            try Keychain.set(res.token, for: .sessionToken)
            try Keychain.set(res.userId, for: .userId)
            pending = res
            step = 1
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func restore() async {
        guard let pending else { return }
        busy = true
        defer { busy = false }
        do {
            try await Recovery.shared.restore(phrase: words, username: pending.username)
            await MainActor.run { session.username = pending.username }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Impostazioni: mostra la frase (Face ID), stato backup, passkey.
struct AuthSettingsView: View {
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var phrase: [String]?
    @State private var passkeys: [(String, String)] = []
    @State private var lastBackup: Date?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            HESHBackground()
            List {
                Section("Frase di recupero") {
                    if let phrase { PhraseGrid(words: phrase).listRowBackground(Color.clear) }
                    Button(phrase == nil ? "Mostra con Face ID" : "Nascondi") { if phrase == nil { reveal() } else { phrase = nil } }
                    LabeledContent("Ultimo backup", value: lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "mai")
                    Button("Aggiorna il backup adesso") { Task { busy = true; try? await Recovery.shared.uploadBackup(); lastBackup = await Recovery.shared.lastUpload; busy = false } }.disabled(busy)
                }
                Section("Passkey") {
                    ForEach(passkeys, id: \.0) { id, name in
                        HStack { Label(name, systemImage: "person.badge.key"); Spacer() }
                            .swipeActions { Button("Elimina", role: .destructive) { Task { try? await APIClient.shared.deletePasskey(id: id); await load() } } }
                    }
                    Button("Crea una passkey su questo iPhone") { Task { do { try await PasskeyManager.shared.createPasskey(); await load() } catch { self.error = error.localizedDescription } } }
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
                Section { } footer: {
                    Text("Senza email né telefono, il recupero si basa su queste due cose: la passkey prova che sei tu al server, le 12 parole decifrano il backup. Chi ha entrambe può ripristinare l'account su un nuovo iPhone.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Accesso e recupero")
        .task { await load() }
    }

    private func load() async {
        lastBackup = await Recovery.shared.lastUpload
        passkeys = ((try? await APIClient.shared.passkeys()) ?? []).compactMap { d in
            guard let id = d["id"]?.value as? String else { return nil }
            return (id, d["name"]?.value as? String ?? "Passkey")
        }
    }

    private func reveal() {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Mostra la frase di recupero") { ok, _ in
            Task { @MainActor in if ok { phrase = await Recovery.shared.localPhrase() } }
        }
    }
}
