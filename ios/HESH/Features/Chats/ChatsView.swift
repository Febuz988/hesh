import GRDB
import HESHShared
import SwiftUI

struct ChatsView: View {
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var chats: [Chat] = []
    @State private var search = ""
    @State private var showNew = false
    @State private var observer: DatabaseCancellable?

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                List {
                    ForEach(filtered) { chat in
                        NavigationLink(value: chat) { ChatRow(chat: chat) }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if chats.isEmpty {
                        ContentUnavailableView("Nessuna chat", systemImage: "bubble.left.and.bubble.right", description: Text("Crea un gruppo o invita un familiare."))
                    }
                }
            }
            .navigationTitle("Chat")
            .searchable(text: $search, prompt: "Cerca chat, gruppi, messaggi")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { InvitesView() } label: { Image(systemName: "qrcode") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: Chat.self) { ChatView(chat: $0) }
            .sheet(isPresented: $showNew) { NewChatView() }
            .onAppear(perform: observe)
        }
    }

    private var filtered: [Chat] {
        search.isEmpty ? chats : chats.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func observe() {
        observer = ValueObservation
            .tracking { db in try Chat.order(Column("last_activity").desc).fetchAll(db) }
            .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { chats = $0 })
    }
}

struct ChatRow: View {
    let chat: Chat
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var last: Message?
    @State private var contact: Contact?

    var body: some View {
        HStack(spacing: 14) {
            if chat.isGroup { Avatar(name: chat.title, isGroup: true, size: 52) } else { ContactAvatar(contact: contact ?? Contact(username: chat.title), size: 52) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 6) {
                        if chat.isSecret { Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.accent) }
                        Text(chat.title).font(.system(size: 16, weight: .semibold))
                        if chat.isFamily { Text("SOS").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.danger.opacity(0.18)).foregroundStyle(Theme.danger).clipShape(RoundedRectangle(cornerRadius: 6)) }
                    }
                    Spacer()
                    if let d = chat.lastActivity { Text(d, style: .time).font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme)) }
                }
                Text(preview).font(.system(size: 14)).foregroundStyle(Color.heshMuted(scheme)).lineLimit(1)
            }
            if chat.unread > 0 {
                Text("\(chat.unread)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.heshInk)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22).background(Capsule().fill(theme.accent))
            }
        }
        .padding(12)
        .background {
            if chat.unread > 0 {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .task(id: chat.lastActivity) {
            last = try? await Database.shared.pool.read { db in
                try Message.filter(Column("chat_id") == chat.id).order(Column("ts").desc).fetchOne(db)
            }
            if let u = chat.dmUsername { contact = try? await Database.shared.pool.read { db in try Contact.fetchOne(db, key: u) } }
        }
    }

    private var preview: String {
        guard let last else { return chat.isSecret ? "Chat segreta" : "" }
        if last.deleted { return "Messaggio eliminato" }
        switch last.content?.kind {
        case .text: return last.content?.body ?? ""
        case .attachment: return last.content?.isImage == true ? "Foto" : last.content?.isVoice == true ? "Messaggio vocale" : (last.content?.name ?? "Allegato")
        case .location: return "Posizione"
        case .sos: return "SOS"
        case .callEnd: return last.content.map { CallLog.short($0, mine: last.sender == (Keychain.string(for: .username) ?? "")) } ?? "Chiamata"
        case .checkin, .geofence: return "Posizione"
        case .sosResolved: return "Avviso rientrato"
        default: return last.kind
        }
    }
}

struct Avatar: View {
    let name: String
    var isGroup = false
    var size: CGFloat = 40
    @Environment(Theme.self) private var theme
    var body: some View {
        ZStack {
            if isGroup {
                RoundedRectangle(cornerRadius: size * 0.34, style: .continuous).fill(theme.accent)
                Image(systemName: "person.2").foregroundStyle(Color.heshInk).font(.system(size: size * 0.42))
            } else {
                Circle().fill(Theme.Original.ultraviolet.color.opacity(0.35))
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.36, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
    }
}
