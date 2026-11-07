import HESHShared
import SwiftUI
import UIKit

struct RegisterView: View {
    let inviteToken: String
    @Environment(SessionState.self) private var session
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var username = ""
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool {
        username.range(of: "^[a-z0-9][a-z0-9.]{2,19}$", options: .regularExpression) != nil
    }

    var body: some View {
        ZStack {
            HESHBackground()
            VStack(alignment: .leading, spacing: 18) {
                GlassCard(radius: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Invito ricevuto").font(.system(size: 14, weight: .semibold))
                            Text("Verrà verificato dal server al momento della creazione").font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                        }
                    }
                    .padding(14)
                }

                Text("Scegli il tuo nome utente")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("È la tua identità in HESH. Niente telefono, niente email.")
                    .font(.system(size: 14)).foregroundStyle(Color.heshMuted(scheme))

                SectionLabel("Nome utente")
                HStack(spacing: 6) {
                    Text("@").foregroundStyle(Color.heshMuted(scheme))
                    TextField("nome", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 18, weight: .semibold))
                        .onChange(of: username) { _, v in username = v.lowercased() }
                    if valid { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                }
                .padding(.horizontal, 18).frame(height: 58)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16)))
                Text("Lettere minuscole, numeri e punto, da 3 a 20 caratteri.")
                    .font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))

                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger)
                }

                Spacer()

                Button {
                    Task { await register() }
                } label: {
                    if busy { ProgressView().tint(.black) } else { Text("Crea il mio accesso") }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!valid || busy)
                Text("Le chiavi di cifratura nascono su questo iPhone. Il server non può leggerle.")
                    .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .navigationTitle("Passo 2 di 2")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func register() async {
        busy = true
        defer { busy = false }
        do {
            let m = try await CryptoService.shared.prepareRegistration()
            let req = RegisterRequest(
                inviteToken: inviteToken,
                username: username,
                deviceName: UIDevice.current.name,
                identityKey: m.identityKey,
                registrationId: m.registrationId,
                signedPrekeyId: m.signedPrekeyId,
                signedPrekey: m.signedPrekey,
                signedPrekeySignature: m.signedPrekeySignature,
                kyberPrekeyId: m.kyberPrekeyId,
                kyberPrekey: m.kyberPrekey,
                kyberPrekeySignature: m.kyberPrekeySignature,
                oneTimePrekeys: m.oneTimePrekeys,
                apnsToken: nil)
            let res = try await APIClient.shared.register(req)
            try Keychain.set(res.token, for: .sessionToken)
            try Keychain.set(res.username, for: .username)
            try Keychain.set(res.userId, for: .userId)
            await MainActor.run {
                session.pendingInvite = nil
                session.username = res.username
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
