import GRDB
import HESHShared
import LocalAuthentication
import SwiftUI

struct ChatView: View {
    let chat: Chat
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var observer: DatabaseCancellable?
    @State private var error: String?
    @State private var showAttach = false
    @State private var unlocked = false
    @State private var liveChat: Chat

    init(chat: Chat) {
        self.chat = chat
        _liveChat = State(initialValue: chat)
    }

    private var me: String { Keychain.string(for: .username) ?? "" }

    var body: some View {
        ZStack {
            HESHBackground()
            if liveChat.isSecret && !unlocked {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield").font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent)
                    Text("Chat segreta").font(.system(size: 20, weight: .bold, design: .rounded))
                    Button("Sblocca") { unlock() }.buttonStyle(PillButtonStyle()).frame(width: 200)
                }
            } else {
            VStack(spacing: 0) {
                if liveChat.isSecret {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.system(size: 11))
                        Text("Chat segreta" + (liveChat.ephemeralS.map { " · messaggi \(MessageService.label(seconds: $0))" } ?? ""))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Original.ice.color)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Theme.Original.ice.color.opacity(0.12))
                }
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
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let peer = liveChat.dmUsername {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { CallService.shared.startCall(to: peer, video: true) } label: { Image(systemName: "video") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { CallService.shared.startCall(to: peer, video: false) } label: { Image(systemName: "phone") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ChatInfoView(chat: liveChat) } label: { Image(systemName: liveChat.isSecret ? "lock.circle" : "info.circle") }
            }
        }
        .onAppear { observe(); markRead(); if liveChat.isSecret { unlock() } else { unlocked = true } }
        .task {
            while !Task.isCancelled {
                try? await MessageService.shared.purgeExpired()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $showAttach) {
            AttachmentSheet(chat: liveChat) { content in try await MessageService.shared.send(content) }
        }
        .alert("Errore", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { showAttach = true } label: { Image(systemName: "plus") }
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
            .tracking { db in
                (try Message.filter(Column("chat_id") == chat.id).order(Column("ts")).fetchAll(db),
                 try Chat.fetchOne(db, key: chat.id))
            }
            .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { pair in
                messages = pair.0
                if let c = pair.1 { liveChat = c }
                markRead()
            })
    }

    private func markRead() {
        Task {
            try? await Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE chat SET unread = 0 WHERE id = ?", arguments: [chat.id])
            }
            await MessageService.shared.sendReadReceipts(chat: chat.id)
        }
    }

    private func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { unlocked = true; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Apri la chat segreta") { ok, _ in
            Task { @MainActor in unlocked = ok }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        do { try await MessageService.shared.send(.text(text, chat: chat.id, ephemeralS: liveChat.ephemeralS)) }
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
                } else if message.content?.kind == .attachment, let c = message.content {
                    AttachmentBubble(content: c, mine: mine)
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
                if let e = message.expiresAt { Image(systemName: "timer"); Text(e, style: .relative) }
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
        case .sosResolved: return ("\(mine ? "Hai comunicato" : message.sender + " ha comunicato") che l'avviso è rientrato", "checkmark.shield")
        case .checkin: return ("\(mine ? "Sei arrivato" : message.sender + " è arrivato")\(c.place.map { " a \($0)" } ?? "")", "figure.walk.arrival")
        case .geofence: return ("\(mine ? "Sei" : message.sender + " è") \(c.event == "enter" ? "arrivato a" : "uscito da") \(c.place ?? "")", "mappin.and.ellipse")
        case .location:
            if c.liveUntilTs == 0 { return ("\(mine ? "Hai smesso" : message.sender + " ha smesso") di condividere la posizione", "location.slash") }
            if c.event == "travel" { return ("\(mine ? "Sei" : message.sender + " è") in modalità viaggio: posizione condivisa fino allo stop", "car") }
            if c.event == "start", let u = c.liveUntilTs {
                let min = max(1, Int((Double(u) / 1000 - Double(c.ts) / 1000) / 60))
                return ("\(mine ? "Stai condividendo" : message.sender + " condivide") la posizione per \(min) min", "location.fill")
            }
            return ("\(mine ? "Hai inviato" : message.sender + " ha inviato") la posizione", "mappin")
        case .groupCreate, .groupUpdate, .senderKey: return ("Gruppo aggiornato", "person.2")
        case .callEnd: return (CallLog.describe(c, mine: mine), c.video == true ? "video" : "phone")
        default: return nil
        }
    }
}
