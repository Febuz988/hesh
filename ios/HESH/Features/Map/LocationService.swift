import CoreLocation
import GRDB
import HESHShared
import SwiftUI
import UIKit

/// Condivisione posizione a tempo, geofence sui luoghi salvati, check-in.
/// Mai tracciamento continuo senza una condivisione attiva: fuori dalla finestra
/// restano solo le region (eventi di ingresso/uscita, decisi da iOS).
@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let db = Database.shared.pool

    var authorization: CLAuthorizationStatus = .notDetermined
    var current: CLLocation?
    var sharingUntil: Date? {
        didSet { UserDefaults.standard.set(sharingUntil?.timeIntervalSince1970 ?? 0, forKey: "location.sharingUntil") }
    }
    var travelMode = false
    private var lastSent: CLLocation?
    private var lastSentAt: Date = .distantPast

    var isSharing: Bool { travelMode || (sharingUntil.map { $0 > Date() } ?? false) }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
        let t = UserDefaults.standard.double(forKey: "location.sharingUntil")
        if t > 0, Date(timeIntervalSince1970: t) > Date() { sharingUntil = Date(timeIntervalSince1970: t) }
        authorization = manager.authorizationStatus
    }

    // MARK: Permessi

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            manager.requestLocation()
            Task { await syncGeofences() }
        }
    }

    // MARK: Condivisione a tempo

    func share(for duration: TimeInterval) {
        sharingUntil = Date().addingTimeInterval(duration)
        startUpdates()
        Task { await sendNow(force: true, event: "start") }
    }

    func startTravelMode() {
        travelMode = true
        startUpdates()
        Task { await sendNow(force: true, event: "start") }
    }

    func stopSharing() {
        sharingUntil = nil
        travelMode = false
        manager.stopUpdatingLocation()
        Task { await sendStop() }
    }

    private func startUpdates() {
        if authorization == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func refreshOnce() {
        if authorization == .notDetermined { requestWhenInUse() } else { manager.requestLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            current = l
            guard isSharing else { manager.stopUpdatingLocation(); return }
            await sendNow(force: false)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// Invia al gruppo famiglia ogni 60 s o 100 m.
    private var pendingStartEvent = false

    private func sendNow(force: Bool, event: String? = nil) async {
        guard let family = await familyChat() else { Diagnostics.record("posizione: nessun gruppo segnato come cerchio familiare"); return }
        if event == "start" { pendingStartEvent = true }
        guard let l = current else {
            if authorization == .denied || authorization == .restricted { Diagnostics.record("posizione: permesso negato in Impostazioni") }
            return  // arrivera' da didUpdateLocations
        }
        let moved = lastSent.map { $0.distance(from: l) } ?? .infinity
        guard force || pendingStartEvent || moved > 100 || Date().timeIntervalSince(lastSentAt) > 60 else { return }
        if let until = sharingUntil, until < Date(), !travelMode { stopSharing(); return }
        lastSent = l; lastSentAt = Date()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel >= 0 ? Double(UIDevice.current.batteryLevel) : nil
        var c = Content.location(chat: family.id, lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                 accM: l.horizontalAccuracy, liveUntil: travelMode ? Date().addingTimeInterval(8 * 3600) : sharingUntil, battery: battery)
        if pendingStartEvent { c.event = travelMode ? "travel" : "start"; pendingStartEvent = false }
        do { try await MessageService.shared.send(c) } catch { Diagnostics.record("posizione: invio fallito: \(error)") }
    }

    private func sendStop() async {
        guard let family = await familyChat() else { return }
        var c = Content(kind: .location, chat: family.id)
        c.liveUntilTs = 0
        c.event = "stop"
        try? await MessageService.shared.send(c)
    }

    func checkIn(place: String?) async {
        guard let family = await familyChat() else { return }
        var c = Content(kind: .checkin, chat: family.id)
        c.place = place
        if let l = current { c.lat = l.coordinate.latitude; c.lon = l.coordinate.longitude; c.accM = l.horizontalAccuracy }
        try? await MessageService.shared.send(c)
    }

    private func familyChat() async -> Chat? {
        try? await db.read { db in try Chat.filter(Column("is_family") == true).fetchOne(db) }
    }

    // MARK: Geofence

    func syncGeofences() async {
        guard authorization == .authorizedAlways else { return }
        for r in manager.monitoredRegions { manager.stopMonitoring(for: r) }
        let places = (try? await db.read { db in try Place.filter(Column("notify") == true).fetchAll(db) }) ?? []
        for p in places.prefix(20) {
            let region = CLCircularRegion(center: .init(latitude: p.lat, longitude: p.lon), radius: max(100, p.radiusM), identifier: p.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { await geofence(region.identifier, event: "enter") }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { await geofence(region.identifier, event: "exit") }
    }

    private func geofence(_ placeId: String, event: String) async {
        guard let place = try? await db.read({ db in try Place.fetchOne(db, key: placeId) }), let family = await familyChat() else { return }
        var c = Content(kind: .geofence, chat: family.id)
        c.place = place.name
        c.event = event
        try? await MessageService.shared.send(c)
    }

    // MARK: Luoghi

    func savePlace(name: String, coordinate: CLLocationCoordinate2D, radius: Double) async {
        let p = Place(id: ULID.new(), name: name, lat: coordinate.latitude, lon: coordinate.longitude, radiusM: radius)
        try? await db.write { db in try p.save(db) }
        await syncGeofences()
    }

    func deletePlace(_ p: Place) async {
        _ = try? await db.write { db in try p.delete(db) }
        await syncGeofences()
    }
}
