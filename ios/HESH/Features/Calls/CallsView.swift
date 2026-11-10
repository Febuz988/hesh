import GRDB
import HESHShared
import SwiftUI

/// Registro chiamate (righe call_end delle chat 1:1) e avvio di nuove chiamate.
struct CallsView: View {
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var log: [Message] = []
    @State private var contacts: [Contact] = []
    @State private var observer: DatabaseCancellable?
    @State private var showNew = false
    private var me: String { Keychain.string(for: .username) ?? "" }

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                List {
                    ForEach(log) { m in
                        if let c = m.content {
                            let peer = String(m.chatId.dropFirst(3))
                            let mine = m.sender == me
                            HStack(spacing: 12) {
                                ContactAvatar(contact: contacts.first { $0.username == peer }, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(peer).font(.system(size: 16, weight: .semibold))
                                    HStack(spacing: 5) {
                                        Image(systemName: CallLog.isMissed(c, mine: mine) ? "arrow.down.left" : mine ? "arrow.up.right" : "arrow.down.left")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(CallLog.isMissed(c, mine: mine) ? Theme.danger : Color.heshMuted(scheme))
                                        Text(CallLog.short(c, mine: mine)).font(.system(size: 13)).foregroundStyle(Color.heshMuted(scheme))
                                    }
                                }
                                Spacer()
                                Text(m.ts.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                                Button { CallService.shared.startCall(to: peer, video: c.video == true) } label: {
                                    Image(systemName: c.video == true ? "video" : "phone").foregroundStyle(theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if log.isEmpty {
                        ContentUnavailableView("Nessuna chiamata", systemImage: "phone", description: Text("Audio e video cifrati da telefono a telefono. Il server non sente nulla."))
                    }
                }
            }
            .navigationTitle("Chiamate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "phone.badge.plus") } }
            }
            .sheet(isPresented: $showNew) { NewCallSheet(contacts: contacts.filter { $0.status == "accepted" && !$0.blocked }) }
        }
        .onAppear(perform: observe)
    }

    private func observe() {
        observer = ValueObservation
            .tracking { db in
                (try Message.filter(sql: "kind = 'call_end' AND deleted = 0").order(Column("ts").desc).limit(200).fetchAll(db),
                 try Contact.fetchAll(db))
            }
            .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { log = $0.0; contacts = $0.1 })
    }
}

private struct NewCallSheet: View {
    let contacts: [Contact]
    @Environment(\.dismiss) private var dismiss
    @Environment(Theme.self) private var theme
    var body: some View {
        NavigationStack {
            List(contacts) { c in
                HStack(spacing: 12) {
                    ContactAvatar(contact: c, size: 40)
                    Text(c.username).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button { dismiss(); CallService.shared.startCall(to: c.username, video: false) } label: { Image(systemName: "phone").foregroundStyle(theme.accent) }.buttonStyle(.plain)
                    Button { dismiss(); CallService.shared.startCall(to: c.username, video: true) } label: { Image(systemName: "video").foregroundStyle(theme.accent) }.buttonStyle(.plain).padding(.leading, 10)
                }
            }
            .navigationTitle("Nuova chiamata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Testi del registro chiamate, condivisi con la riga di sistema in chat.
enum CallLog {
    static func isMissed(_ c: Content, mine: Bool) -> Bool {
        // call_end lo manda chi chiude: timeout lo manda il chiamante, quindi per chi lo riceve e' una persa.
        c.reason == "timeout" && !mine
    }

    static func short(_ c: Content, mine: Bool) -> String {
        let kind = c.video == true ? "Videochiamata" : "Chiamata"
        switch c.reason {
        case "timeout": return mine ? "\(kind), nessuna risposta" : "\(kind) persa"
        case "declined": return mine ? "\(kind) rifiutata" : "\(kind) rifiutata"
        case "busy": return "\(kind), occupato"
        case "failed": return "\(kind) non riuscita"
        default:
            if let d = c.durationS, d > 0 { return "\(kind), \(duration(d))" }
            return kind
        }
    }

    static func describe(_ c: Content, mine: Bool) -> String { short(c, mine: mine) }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 60 ? "\(t / 60) min \(t % 60) s" : "\(t) s"
    }
}
