import CoreLocation
import GRDB
import HESHShared
import MapKit
import SwiftUI

struct FamilyMapView: View {
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var location = LocationService.shared
    @State private var members: [MemberLocation] = []
    @State private var places: [Place] = []
    @State private var family: Chat?
    @State private var observer: DatabaseCancellable?
    @State private var placesObserver: DatabaseCancellable?
    @State private var camera: MapCameraPosition = .automatic
    @State private var showPlaces = false
    @State private var now = Date()

    private var me: String { Keychain.string(for: .username) ?? "" }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $camera) {
                    UserAnnotation()
                    ForEach(places) { p in
                        MapCircle(center: .init(latitude: p.lat, longitude: p.lon), radius: p.radiusM)
                            .foregroundStyle(theme.accent.opacity(0.12))
                            .stroke(theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        Annotation(p.name, coordinate: .init(latitude: p.lat, longitude: p.lon)) {
                            Image(systemName: "mappin").foregroundStyle(theme.accent)
                        }
                    }
                    ForEach(members.filter { $0.username != me }) { m in
                        Annotation(m.username, coordinate: .init(latitude: m.lat, longitude: m.lon)) {
                            MemberPin(member: m, stale: m.isStale)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .mapControls { MapUserLocationButton(); MapCompass() }

                sharingPanel
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Famiglia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPlaces = true } label: { Image(systemName: "mappin.and.ellipse") }
                }
            }
            .sheet(isPresented: $showPlaces) { PlacesView() }
            .onAppear { observe(); location.refreshOnce() }
            .task {
                while !Task.isCancelled { now = Date(); try? await Task.sleep(for: .seconds(30)) }
            }
        }
    }

    private var sharingPanel: some View {
        GlassCard(radius: 24, glow: location.isSharing ? theme.accent : nil) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("La tua posizione").font(.system(size: 14, weight: .semibold))
                        Text(sharingLabel).font(.system(size: 12)).foregroundStyle(location.isSharing ? theme.accent : Color.heshMuted(scheme))
                    }
                    Spacer()
                    if location.isSharing {
                        Button("Stop") { location.stopSharing() }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                    }
                }
                if family == nil {
                    Text("Crea un gruppo e segnalo come cerchio familiare per condividere la posizione.")
                        .font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                } else if location.authorization == .denied || location.authorization == .restricted {
                    Text("Permesso posizione negato. Impostazioni → HESH → Posizione.")
                        .font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else {
                    HStack(spacing: 6) {
                        durationButton("15 min", 15 * 60)
                        durationButton("1 ora", 3600)
                        durationButton("8 ore", 8 * 3600)
                        Button {
                            if location.authorization != .authorizedAlways { location.requestAlways() }
                            location.startTravelMode()
                        } label: { Label("Viaggio", systemImage: "car") }
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Capsule().fill(location.travelMode ? theme.accent : Color.primary.opacity(0.06)))
                            .foregroundStyle(location.travelMode ? Color.heshInk : .primary)
                    }
                    HStack {
                        Text(membersLabel).font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                        Spacer()
                        Button("Sono arrivato") { Task { await location.checkIn(place: nil) } }
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                    }
                }
            }
            .padding(16)
        }
    }

    private func durationButton(_ label: String, _ seconds: TimeInterval) -> some View {
        Button(label) {
            if location.authorization == .notDetermined { location.requestWhenInUse() }
            location.share(for: seconds)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(Capsule().fill(Color.primary.opacity(0.06)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.14))))
        .foregroundStyle(.primary)
    }

    private var sharingLabel: String {
        if location.travelMode { return "Modalità viaggio: condivisa finché non premi Stop" }
        if let until = location.sharingUntil, until > now {
            let min = Int(until.timeIntervalSince(now) / 60)
            return "Condivisa con \(family?.title ?? "famiglia") · ancora \(min) min"
        }
        return "Non condivisa"
    }

    private var membersLabel: String {
        let others = (family?.members ?? []).filter { $0 != me }
        let sharing = members.filter { $0.username != me && !$0.isStale }.count
        return "\(sharing) su \(others.count) condividono"
    }

    private func observe() {
        observer = ValueObservation.tracking { db in try MemberLocation.fetchAll(db) }
            .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { members = $0 })
        placesObserver = ValueObservation.tracking { db in try Place.fetchAll(db) }
            .start(in: Database.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { places = $0 })
        Task { family = try? await Database.shared.pool.read { db in try Chat.filter(Column("is_family") == true).fetchOne(db) } }
    }
}

struct MemberPin: View {
    let member: MemberLocation
    let stale: Bool
    @Environment(Theme.self) private var theme
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(stale ? Color.gray.opacity(0.5) : Theme.Original.ultraviolet.color.opacity(0.6))
                Circle().strokeBorder(stale ? Color.gray : theme.accent, lineWidth: 3)
                Text(String(member.username.prefix(1)).uppercased()).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: stale ? .clear : theme.accent.opacity(0.6), radius: 10)
            Text("\(member.username) · \(member.ts, style: .relative)")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

struct PlacesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Theme.self) private var theme
    @State private var location = LocationService.shared
    @State private var places: [Place] = []
    @State private var name = ""
    @State private var radius: Double = 200
    @State private var center: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            ZStack {
                HESHBackground()
                VStack(spacing: 12) {
                    MapReader { proxy in
                        Map(position: $camera) {
                            UserAnnotation()
                            if let c = center {
                                MapCircle(center: c, radius: radius).foregroundStyle(theme.accent.opacity(0.15)).stroke(theme.accent, lineWidth: 1.5)
                            }
                        }
                        .onTapGesture { pt in center = proxy.convert(pt, from: .local) }
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    GlassCard(radius: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Nuovo luogo · tocca la mappa per posizionarlo")
                            TextField("Casa, Scuola, Nonni", text: $name)
                                .padding(.horizontal, 14).frame(height: 44)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            HStack {
                                Text("Raggio \(Int(radius)) m").font(.system(size: 13))
                                Slider(value: $radius, in: 100...1000, step: 50).tint(theme.accent)
                            }
                            Button("Salva luogo") {
                                guard let c = center, !name.isEmpty else { return }
                                if location.authorization != .authorizedAlways { location.requestAlways() }
                                Task { await location.savePlace(name: name, coordinate: c, radius: radius); name = ""; center = nil }
                            }
                            .buttonStyle(PillButtonStyle()).disabled(center == nil || name.isEmpty)
                            Text("Gli avvisi di arrivo e uscita richiedono il permesso \"Sempre\" e partono solo verso il cerchio familiare.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                    List {
                        ForEach(places) { p in
                            HStack {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(theme.accent)
                                VStack(alignment: .leading) {
                                    Text(p.name).font(.system(size: 15, weight: .semibold))
                                    Text("raggio \(Int(p.radiusM)) m").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .swipeActions { Button("Elimina", role: .destructive) { Task { await location.deletePlace(p) } } }
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
                .padding(12)
            }
            .navigationTitle("Luoghi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .task {
                do { for try await list in ValueObservation.tracking({ db in try Place.fetchAll(db) }).values(in: Database.shared.pool) { places = list } } catch {}
            }
        }
    }
}
