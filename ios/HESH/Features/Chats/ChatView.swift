import GRDB
import HESHShared
import SwiftUI

struct ChatView: View {
    let chat: Chat
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var observer: DatabaseCancellable?
    @State private var error: String?

    private var me: String { Keychain.string(for: .username) ?? "" }

    var body: some View {
        ZStack {
            HESHBackground()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            Label("I messaggi sono cifrati end-to-end", systemImage: "lock.fill")
                                .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                .padding(.top, 8)
                            ForEach(messages) { m in
                                Bubble(message: m, mine: m.sender == me, showSender: chat.isGroup)
                                    .id(m.id)
                                    .contextMenu {
                                        if m.sender == me, !m.deleted {
                                            Button(role: .destructive) { Task { await delete(m, everyone: true) } } label: { Label("Elimina per tutti", systemImage: "trash") }
                                        }
                                        Button { Task { await delete(m, everyone: false) } } label: { Label("Elimina per me", systemImage: "eye.slash") }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                composer
            }
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ChatInfoView(chat: chat) } label: { Image(systemName: "info.circle") }
            }
        }
        .onAppear { observe(); markRead() }
        .alert("Errore", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { } label: { Image(systemName: "plus") }
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.06)).overlay(Circle().strokeBorder(Color.primary.opacity(0.14))))
            TextField(chat.isGroup ? "Messaggio al gruppo" : "Messaggio", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Capsule().fill(Color.primary.opacity(0.06)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.14))))
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.heshInk)
            }
            .frame(width: 44, height: 44)
            .background(Circle().fill(theme.accent))
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func observe() {
        observer = ValueObservation
            .tracking { db in try Message.filter(Column("chat_id") == chat.id).order(Column("ts")).fetchAll(db) }
            .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { messages = $0 })
    }

    private func markRead() {
        Task {
            try? await Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE chat SET unread = 0 WHERE id = ?", arguments: [chat.id])
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        do { try await MessageService.shared.send(.text(text, chat: chat.id, ephemeralS: chat.ephemeralS)) }
        catch { self.error = error.localizedDescription }
    }

    private func delete(_ m: Message, everyone: Bool) async {
        do {
            if everyone { try await MessageService.shared.send(.delete(targetId: m.id, chat: chat.id, everyone: true)) }
            try await Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE message SET deleted = 1, body_json = '{}' WHERE id = ?", arguments: [m.id])
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct Bubble: View {
    let message: Message
    let mine: Bool
    let showSender: Bool
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showSender, !mine { Text(message.sender).font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).padding(.horizontal, 6) }
            Group {
                if message.deleted {
                    Label(mine ? "Hai eliminato questo messaggio" : "Messaggio eliminato", systemImage: "trash")
                        .font(.system(size: 14)).italic().foregroundStyle(Color.heshMuted(scheme))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Color.primary.opacity(0.25)))
                } else if message.content?.kind == .sos {
                    Label("SOS", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.heshInk)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.danger))
                } else if let event = systemLine {
                    Label(event.text, systemImage: event.icon)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.heshMuted(scheme))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                } else {
                    Text(message.content?.body ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(mine ? Color.heshInk : .primary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(
                            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: mine ? 20 : 6, bottomTrailing: mine ? 6 : 20, topTrailing: 20), style: .continuous)
                                .fill(mine ? theme.accent : Color.primary.opacity(0.08))
                        )
                }
            }
            HStack(spacing: 4) {
                Text(message.ts, style: .time)
                if mine {
                    Image(systemName: message.status == "read" ? "checkmark.circle.fill" : message.status == "failed" ? "exclamationmark.circle" : "checkmark")
                        .foregroundStyle(message.status == "failed" ? Theme.danger : (message.status == "read" ? theme.accent : Color.heshMuted(scheme)))
                }
                if message.expiresAt != nil { Image(systemName: "timer") }
            }
            .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).padding(.horizontal, 6)
        }
        .frame(maxWidth: 290, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var systemLine: (text: String, icon: String)? {
        guard let c = message.content else { return nil }
        let who = mine ? "Hai" : message.sender
        switch c.kind {
        case .sosResolved: return ("\(mine ? "Hai comunicato" : message.sender + " ha comunicato") che l'emergenza è rientrata", "checkmark.shield")
        case .checkin: return ("\(mine ? "Sei arrivato" : message.sender + " è arrivato")\(c.place.map { " a \($0)" } ?? "")", "figure.walk.arrival")
        case .geofence: return ("\(mine ? "Sei" : message.sender + " è") \(c.event == "enter" ? "arrivato a" : "uscito da") \(c.place ?? "")", "mappin.and.ellipse")
        case .location: return c.liveUntilTs == 0 ? ("\(who) smesso di condividere la posizione", "location.slash") : ("\(mine ? "Stai condividendo" : message.sender + " condivide") la posizione", "location.fill")
        case .groupCreate, .groupUpdate, .senderKey: return ("Gruppo aggiornato", "person.2")
        default: return nil
        }
    }
}
