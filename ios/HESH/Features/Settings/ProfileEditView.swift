import GRDB
import HESHShared
import PhotosUI
import SwiftUI

struct ProfileEditView: View {
    @Environment(Theme.self) private var theme
    @Environment(SessionState.self) private var session
    @State private var photo: PhotosPickerItem?
    @State private var avatar: UIImage?
    @State private var birthday = Date(timeIntervalSince1970: 0)
    @State private var hasBirthday = false
    @State private var visibility = "circle"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            HESHBackground()
            List {
                Section {
                    VStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            if let avatar {
                                Image(uiImage: avatar).resizable().scaledToFill().frame(width: 104, height: 104)
                                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                            } else {
                                Avatar(name: session.username ?? "?", size: 104)
                            }
                            PhotosPicker(selection: $photo, matching: .images) {
                                Image(systemName: "camera.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.heshInk)
                                    .frame(width: 36, height: 36).background(Circle().fill(theme.accent))
                            }
                            .offset(x: 6, y: 6)
                        }
                        Text("@\(session.username ?? "")").font(.system(size: 20, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section("Compleanno") {
                    Toggle("Mostra il compleanno", isOn: $hasBirthday).tint(theme.accent)
                    if hasBirthday {
                        DatePicker("Data", selection: $birthday, displayedComponents: .date)
                        Picker("Visibile a", selection: $visibility) {
                            Text("Il mio cerchio").tag("circle")
                            Text("Nessuno").tag("nobody")
                        }
                    }
                }
                Section {
                    Button { Task { await save() } } label: { if busy { ProgressView() } else { Text("Salva e aggiorna i contatti") } }
                        .disabled(busy)
                    if let error { Text(error).foregroundStyle(Theme.danger) }
                } footer: {
                    Text("Foto e compleanno viaggiano cifrati solo verso le persone con cui hai una chat o un gruppo. Il server vede un blob.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Profilo")
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { avatar = img.resized(maxSide: 512) } }
        }
        .task {
            let p = await SocialService.shared.myProfile()
            if let path = p.avatarPath { avatar = UIImage(contentsOfFile: path) }
            if let b = p.birthday, let d = ISO8601DateFormatter().date(from: b + "T00:00:00Z") { birthday = d; hasBirthday = true }
            visibility = p.birthdayVisibility
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let jpeg = avatar?.jpegData(compressionQuality: 0.85)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            try await SocialService.shared.updateProfile(avatarJPEG: jpeg, birthday: hasBirthday ? f.string(from: birthday) : nil, birthdayVisibility: visibility)
        } catch { self.error = error.localizedDescription }
    }
}

struct ContactsView: View {
    @Environment(Theme.self) private var theme
    @State private var contacts: [Contact] = []
    @State private var observer: DatabaseCancellable?
    @State private var newUser = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            HESHBackground()
            List {
                Section("Nuova richiesta") {
                    HStack {
                        TextField("@nomeutente", text: $newUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Invia") { Task { await request() } }.disabled(newUser.isEmpty).foregroundStyle(theme.accent)
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
                let pending = contacts.filter { $0.status == "pending_in" }
                if !pending.isEmpty {
                    Section("Richieste ricevute") {
                        ForEach(pending) { c in
                            HStack {
                                ContactAvatar(contact: c, size: 36)
                                Text(c.username).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Button("Accetta") { Task { try? await SocialService.shared.acceptContact(c.username) } }.foregroundStyle(theme.accent)
                                Button("Rifiuta") { Task { try? await SocialService.shared.declineContact(c.username) } }.foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Section("Contatti") {
                    ForEach(contacts.filter { $0.status == "accepted" || $0.status == "pending_out" }) { c in
                        HStack {
                            ContactAvatar(contact: c, size: 36)
                            VStack(alignment: .leading) {
                                Text(c.username).font(.system(size: 15, weight: .semibold))
                                Text(c.status == "pending_out" ? "In attesa" : (c.birthday.map { "Compleanno \($0.suffix(5))" } ?? "Contatto")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.keyChanged { Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.danger) }
                        }
                        .swipeActions { Button("Blocca", role: .destructive) { Task { try? await SocialService.shared.setBlocked(c.username, blocked: true) } } }
                    }
                }
                let blocked = contacts.filter { $0.blocked }
                if !blocked.isEmpty {
                    Section("Bloccati") {
                        ForEach(blocked) { c in
                            HStack { Text(c.username); Spacer(); Button("Sblocca") { Task { try? await SocialService.shared.setBlocked(c.username, blocked: false) } }.foregroundStyle(theme.accent) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Contatti")
        .onAppear {
            observer = ValueObservation.tracking { db in try Contact.order(Column("username")).fetchAll(db) }
                .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { contacts = $0 })
        }
    }

    private func request() async {
        let u = newUser.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        do { try await SocialService.shared.requestContact(u); newUser = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct ContactAvatar: View {
    let contact: Contact?
    var size: CGFloat = 40
    var body: some View {
        if let path = contact?.avatarPath, let img = UIImage(contentsOfFile: path) {
            Image(uiImage: img).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
            Avatar(name: contact?.username ?? "?", size: size)
        }
    }
}
