import Foundation
import GRDB

/// Un solo database GRDB nell'App Group, aperto da app e NSE.
/// A riposo e' protetto da iOS Data Protection (completeUntilFirstUserAuthentication),
/// che e' l'unica classe compatibile con la NSE a schermo bloccato.
/// Lo store libsignal e i messaggi locali vivono qui.
public final class Database: Sendable {
    public static let shared = Database()
    public let pool: DatabasePool

    private init() {
        do {
            var config = Configuration()
            config.busyMode = .timeout(5)
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            let url = HESHConfig.databaseURL
            pool = try DatabasePool(path: url.path, configuration: config)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
            try Database.migrator.migrate(pool)
        } catch {
            fatalError("Database HESH non apribile: \(error)")
        }
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // --- store libsignal (tutti blob serializzati) ---
            try db.create(table: "signal_identity") { t in
                t.column("address", .text).primaryKey()      // "username.deviceId"
                t.column("identity_key", .blob).notNull()
                t.column("first_seen", .datetime).notNull()
            }
            try db.create(table: "signal_local") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .blob).notNull()
            }
            try db.create(table: "signal_session") { t in
                t.column("address", .text).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "signal_prekey") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "signal_signed_prekey") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "signal_kyber_prekey") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
                t.column("used", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "signal_sender_key") { t in
                t.column("key", .text).primaryKey()           // "sender.deviceId/distributionId"
                t.column("record", .blob).notNull()
            }
            // --- dati applicativi ---
            try db.create(table: "contact") { t in
                t.column("username", .text).primaryKey()
                t.column("display_name", .text)
                t.column("profile_key", .blob)
                t.column("avatar_path", .text)
                t.column("verified", .boolean).notNull().defaults(to: false)
                t.column("blocked", .boolean).notNull().defaults(to: false)
                t.column("key_changed", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "chat") { t in
                t.column("id", .text).primaryKey()            // "dm:<username>" | "g:<group_id>"
                t.column("title", .text).notNull()
                t.column("is_group", .boolean).notNull()
                t.column("is_secret", .boolean).notNull().defaults(to: false)
                t.column("ephemeral_s", .integer)
                t.column("muted", .boolean).notNull().defaults(to: false)
                t.column("is_family", .boolean).notNull().defaults(to: false)
                t.column("members_json", .text).notNull().defaults(to: "[]")
                t.column("last_activity", .datetime)
                t.column("unread", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("chat_id", .text).notNull().indexed().references("chat", onDelete: .cascade)
                t.column("sender", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("body_json", .text).notNull()
                t.column("ts", .datetime).notNull().indexed()
                t.column("status", .text).notNull()           // sending|sent|delivered|read|failed|received
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("expires_at", .datetime)
            }
            try db.create(table: "outbox") { t in
                t.column("id", .text).primaryKey()
                t.column("message_id", .text).notNull()
                t.column("payload_json", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("created", .datetime).notNull()
            }
            try db.create(table: "place") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("radius_m", .double).notNull()
                t.column("notify", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "member_location") { t in
                t.column("username", .text).primaryKey()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("acc_m", .double)
                t.column("ts", .datetime).notNull()
                t.column("live_until", .datetime)
                t.column("battery", .double)
            }
        }
        return m
    }
}
