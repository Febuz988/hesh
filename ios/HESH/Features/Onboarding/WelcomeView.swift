import HESHShared
import SwiftUI

struct WelcomeView: View {
    @Environment(SessionState.self) private var session
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var showScanner = false
    @State private var manualToken = ""
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                VStack(alignment: .leading, spacing: 20) {
                    Spacer().frame(height: 40)
                    GlassCard(radius: 22) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(theme.accent)
                            .frame(width: 64, height: 64)
                    }
                    Text("HESH")
                        .font(.system(size: 40, weight: .bold, design: .rounded)).tracking(3)
                    Text("Cerchio di fiducia. Si entra solo con un invito generato da HESH.")
                        .font(.system(size: 15)).foregroundStyle(Color.heshMuted(scheme))

                    GlassCard(radius: 26) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Hai un invito?").font(.system(size: 17, weight: .bold, design: .rounded))
                            Button { showScanner = true } label: { Label("Scansiona il QR", systemImage: "qrcode.viewfinder") }
                                .buttonStyle(PillButtonStyle())
                            Button { showManual = true } label: { Label("Ho un link di invito", systemImage: "link") }
                                .buttonStyle(PillButtonStyle(filled: false))
                            Text("Inviti monouso, scadenza 24 ore. Il nome utente da solo non dà accesso.")
                                .font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                        }
                        .padding(20)
                    }
                    Spacer()
                    Text("Codice sorgente aperto · nessun numero di telefono, nessuna email")
                        .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme))
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .navigationDestination(item: Binding(get: { session.pendingInvite }, set: { session.pendingInvite = $0 })) { token in
                RegisterView(inviteToken: token)
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    if let url = URL(string: code), let t = InviteLink.parse(url) { session.pendingInvite = t }
                    else if code.count >= 16 { session.pendingInvite = code }
                }
            }
            .alert("Link di invito", isPresented: $showManual) {
                TextField("hesh://invite/...", text: $manualToken)
                Button("Continua") {
                    if let url = URL(string: manualToken), let t = InviteLink.parse(url) { session.pendingInvite = t }
                    else { session.pendingInvite = manualToken.trimmingCharacters(in: .whitespaces) }
                }
                Button("Annulla", role: .cancel) {}
            }
        }
    }
}
