import AVFoundation
import HESHShared
import SwiftUI

/// Preferenze notifiche nell'App Group: la NSE le legge per scegliere suono e anteprima.
enum NotificationPrefs {
    static var defaults: UserDefaults? { UserDefaults(suiteName: HESHConfig.appGroup) }
    static var ringtone: String { get { defaults?.string(forKey: "notif.ringtone") ?? "pulse" } set { defaults?.set(newValue, forKey: "notif.ringtone") } }
    static var previews: Bool { get { defaults?.object(forKey: "notif.previews") as? Bool ?? true } set { defaults?.set(newValue, forKey: "notif.previews") } }
    static var messages: Bool { get { defaults?.object(forKey: "notif.messages") as? Bool ?? true } set { defaults?.set(newValue, forKey: "notif.messages") } }
    static var groups: Bool { get { defaults?.object(forKey: "notif.groups") as? Bool ?? true } set { defaults?.set(newValue, forKey: "notif.groups") } }
    static var inAppSounds: Bool { get { defaults?.object(forKey: "notif.inApp") as? Bool ?? true } set { defaults?.set(newValue, forKey: "notif.inApp") } }
}

struct NotificationSettingsView: View {
    @Environment(Theme.self) private var theme
    @State private var ringtone = NotificationPrefs.ringtone
    @State private var previews = NotificationPrefs.previews
    @State private var messages = NotificationPrefs.messages
    @State private var groups = NotificationPrefs.groups
    @State private var inApp = NotificationPrefs.inAppSounds
    @State private var player: AVAudioPlayer?

    private let tones: [(String, String)] = [("pulse", "Pulse"), ("glass", "Glass"), ("echo", "Echo"), ("silent", "Silenziosa")]

    var body: some View {
        ZStack {
            HESHBackground()
            List {
                Section("Notifiche") {
                    Toggle("Messaggi", isOn: $messages).onChange(of: messages) { _, v in NotificationPrefs.messages = v }
                    Toggle("Gruppi", isOn: $groups).onChange(of: groups) { _, v in NotificationPrefs.groups = v }
                    Toggle(isOn: $previews) { VStack(alignment: .leading) { Text("Anteprima del testo"); Text("Mai per le chat segrete").font(.system(size: 11)).foregroundStyle(.secondary) } }
                        .onChange(of: previews) { _, v in NotificationPrefs.previews = v }
                }
                Section("Suoneria") {
                    HStack(spacing: 10) {
                        ForEach(tones, id: \.0) { id, label in
                            Button {
                                ringtone = id; NotificationPrefs.ringtone = id; preview(id)
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: id == "silent" ? "speaker.slash" : "waveform").font(.system(size: 20)).foregroundStyle(ringtone == id ? theme.accent : .secondary)
                                    Text(label).font(.system(size: 12, weight: ringtone == id ? .bold : .regular))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(ringtone == id ? 0.1 : 0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ringtone == id ? theme.accent : Color.primary.opacity(0.12))))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Suoni nell'app") {
                    Toggle("Invio e ricezione", isOn: $inApp).onChange(of: inApp) { _, v in NotificationPrefs.inAppSounds = v }
                    LabeledContent("Suono SOS", value: "Sempre attivo")
                }
            }
            .scrollContentBackground(.hidden)
            .tint(theme.accent)
        }
        .navigationTitle("Notifiche e suoni")
    }

    private func preview(_ id: String) {
        guard id != "silent", let url = Bundle.main.url(forResource: id, withExtension: "wav") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
