import CoreLocation
import GRDB
import HESHShared
import SwiftUI

/// Pressione prolungata di 3 secondi: anelli che si espandono, haptic a ogni
/// secondo, rilascio anticipato = annullato. Avvisa il gruppo famiglia.
/// Non chiama servizi di emergenza (vedi SPEC 10 e DPLA 3.3.3 F(i)).
struct SOSView: View {
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var family: Chat?
    @State private var progress: Double = 0
    @State private var holding = false
    @State private var sent: Message?
    @State private var error: String?
    @State private var location = LocationSnapshot()
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                VStack(spacing: 22) {
                    GlassCard(radius: 20) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill").foregroundStyle(Theme.danger)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gruppo destinatario").font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                                Text(family.map { "\($0.title) · \($0.members.count) persone" } ?? "Nessun gruppo famiglia")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Spacer()
                        }
                        .padding(14)
                    }

                    Spacer()

                    ZStack {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1)
                                .frame(width: 220 + CGFloat(i) * 60 * progress, height: 220 + CGFloat(i) * 60 * progress)
                                .opacity(progress * (1 - Double(i) * 0.3))
                        }
                        Circle()
                            .fill(Theme.danger)
                            .frame(width: 220, height: 220)
                            .shadow(color: Theme.danger.opacity(0.5 + 0.4 * progress), radius: 40 + 30 * progress)
                            .overlay(Circle().strokeBorder(Theme.danger.opacity(0.3), lineWidth: 10))
                            .overlay {
                                VStack(spacing: 6) {
                                    Text("SOS").font(.system(size: 44, weight: .bold, design: .rounded)).tracking(4)
                                    Text(holding ? "\(max(0, 3 - Int(progress * 3))) s" : "tieni premuto 3 s").font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(Color.heshInk)
                            }
                            .scaleEffect(1 + 0.08 * progress)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in if !holding { beginHold() } }
                                    .onEnded { _ in endHold() }
                            )
                            .accessibilityLabel("Tieni premuto 3 secondi per avvisare la famiglia")
                    }
                    .animation(.easeOut(duration: 0.15), value: progress)

                    Label(location.available ? "Posizione disponibile · verrà inclusa" : "Posizione non disponibile · avviso comunque inviato", systemImage: "location")
                        .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))

                    Spacer()

                    if let sent {
                        GlassCard(radius: 24) {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel("Ultimo SOS · \(sent.ts.formatted(date: .abbreviated, time: .shortened))")
                                Label("Inviato al gruppo", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(theme.accent)
                                Button("Comunica che è tutto a posto") { Task { await resolve(sent) } }
                                    .buttonStyle(PillButtonStyle(filled: false))
                            }
                            .padding(16)
                        }
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    Text("L'SOS avvisa il tuo gruppo. Non contatta i servizi di emergenza e non garantisce ricezione immediata.")
                        .font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)).multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .navigationTitle("SOS")
            .task { await load() }
        }
    }

    private func load() async {
        family = try? await Database.shared.pool.read { db in try Chat.filter(Column("is_family") == true).fetchOne(db) }
        sent = try? await Database.shared.pool.read { db in
            try Message.filter(Column("kind") == "sos").order(Column("ts").desc).fetchOne(db)
        }
        location.refresh()
    }

    private func beginHold() {
        holding = true
        progress = 0
        let start = Date()
        holdTask = Task { @MainActor in
            var lastTick = 0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                progress = min(1, elapsed / 3)
                let tick = Int(elapsed)
                if tick != lastTick { lastTick = tick; UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                if elapsed >= 3 {
                    holding = false
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    await fire()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func endHold() {
        holdTask?.cancel()
        if holding { holding = false; progress = 0 }
    }

    private func fire() async {
        guard let family else { error = "Crea prima un gruppo e segnalo come cerchio familiare"; progress = 0; return }
        do {
            let c = Content.sos(chat: family.id, lat: location.lat, lon: location.lon, accM: location.acc)
            sent = try await MessageService.shared.send(c, priority: "high")
            error = nil
        } catch { self.error = error.localizedDescription }
        progress = 0
    }

    private func resolve(_ sos: Message) async {
        guard let family else { return }
        var c = Content(kind: .sosResolved, chat: family.id)
        c.sosId = sos.id
        _ = try? await MessageService.shared.send(c)
        sent = nil
    }
}

/// Ultima posizione nota, senza avviare tracciamento continuo.
@Observable
final class LocationSnapshot: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var available: Bool { lat != nil }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func refresh() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        lat = l.coordinate.latitude; lon = l.coordinate.longitude; acc = l.horizontalAccuracy
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
