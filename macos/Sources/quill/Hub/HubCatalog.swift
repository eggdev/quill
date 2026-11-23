import Foundation
import GRDB

/// The hub's index of sessions, in SQLite. The session folders are the source
/// of truth; this is what makes "what changed since revision N" one query, and
/// it can always be rebuilt from the folders (`HubService.reconcile`).
///
/// Every change takes the next value of one hub-wide revision counter, in the
/// same transaction, so a client that remembers the highest revision it saw
/// never misses a change.
final class HubCatalog: Sendable {
    /// A catalog row: the API's session object plus the client's own folder
    /// name.
    struct Entry: Equatable, Sendable {
        var session: HubSession
        var sourceName: String
    }

    static let defaultPath = Config.supportDir.appendingPathComponent("hub.sqlite")

    let path: URL
    /// Made when the database file is created and never changed. A client
    /// that sees a different id knows the catalog was rebuilt (the file
    /// deleted) and reads everything again: revisions of different catalogs
    /// can't be compared.
    let id: String
    private let db: DatabaseQueue
    private let now: @Sendable () -> Date

    init(path: URL = HubCatalog.defaultPath, now: @escaping @Sendable () -> Date = Date.init) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.path = path
        self.now = now
        db = try DatabaseQueue(path: path.path)
        try Self.migrator.migrate(db)
        id = try db.read { try String.fetchOne($0, sql: "SELECT value FROM hub_meta WHERE key = 'catalog_id'") } ?? ""
    }

    /// Append a migration for each schema change; never edit a shipped one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-sessions") { db in
            try db.create(table: "hub_state") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("revision", .integer).notNull()
            }
            try db.execute(sql: "INSERT INTO hub_state (id, revision) VALUES (1, 0)")
            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("source_name", .text).notNull()
                t.column("device_id", .text).notNull()
                t.column("device_name", .text).notNull()
                t.column("device_kind", .text).notNull()
                t.column("title", .text)
                t.column("started", .text).notNull()
                t.column("duration_seconds", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("error", .text)
                t.column("engine", .text)
                t.column("model", .text)
                t.column("preview", .text).notNull()
                t.column("revision", .integer).notNull().unique()
                t.column("updated", .text).notNull()
            }
        }
        migrator.registerMigration("v2-catalog-id") { db in
            try db.create(table: "hub_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.execute(
                sql: "INSERT INTO hub_meta (key, value) VALUES ('catalog_id', ?)", arguments: [UUID().uuidString])
        }
        return migrator
    }

    // MARK: - Reads

    func session(id: String) throws -> HubSession? {
        try db.read { try Self.fetchOne($0, "id = ?", [id])?.session }
    }

    func entry(named name: String) throws -> Entry? {
        try db.read { try Self.fetchOne($0, "name = ?", [name]) }
    }

    /// Sessions changed after `revision`, oldest change first.
    func sessions(after revision: Int64, limit: Int) throws -> [HubSession] {
        try db.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM sessions WHERE revision > ? ORDER BY revision LIMIT ?",
                arguments: [revision, limit]
            ).map { try Self.entry(from: $0).session }
        }
    }

    /// One page of `GET /v1/sessions`: the sessions after `revision` and the
    /// hub's current counter, read together so they agree.
    func page(after revision: Int64, limit: Int) throws -> (sessions: [HubSession], revision: Int64) {
        try db.read { db in
            let sessions = try Row.fetchAll(
                db, sql: "SELECT * FROM sessions WHERE revision > ? ORDER BY revision LIMIT ?",
                arguments: [revision, limit]
            ).map { try Self.entry(from: $0).session }
            let current = try Int64.fetchOne(db, sql: "SELECT revision FROM hub_state WHERE id = 1") ?? 0
            return (sessions, current)
        }
    }

    func names() throws -> Set<String> {
        try db.read { Set(try String.fetchAll($0, sql: "SELECT name FROM sessions")) }
    }

    func revision() throws -> Int64 {
        try db.read { try Int64.fetchOne($0, sql: "SELECT revision FROM hub_state WHERE id = 1") ?? 0 }
    }

    // MARK: - Writes

    /// Insert or replace the row with `entry.session.id`. An unchanged row
    /// keeps its revision, so a restart does not make every client refetch
    /// everything. `revision` and `updated` in `entry` are ignored.
    @discardableResult
    func save(_ entry: Entry) throws -> HubSession {
        try db.write { db in
            let existing = try Self.fetchOne(db, "id = ?", [entry.session.id])
            if let existing, Self.sameContent(existing, entry) { return existing.session }
            return try self.store(entry, in: db)
        }
    }

    /// Change the row of the folder `name` in place; nil when there is none.
    @discardableResult
    func update(named name: String, _ change: @Sendable (inout HubSession) -> Void) throws -> HubSession? {
        try db.write { db in
            guard var entry = try Self.fetchOne(db, "name = ?", [name]) else { return nil }
            let before = entry
            change(&entry.session)
            if Self.sameContent(before, entry) { return before.session }
            return try self.store(entry, in: db)
        }
    }

    private func store(_ entry: Entry, in db: Database) throws -> HubSession {
        try db.execute(sql: "UPDATE hub_state SET revision = revision + 1 WHERE id = 1")
        var session = entry.session
        session.revision = try Int64.fetchOne(db, sql: "SELECT revision FROM hub_state WHERE id = 1") ?? 0
        session.updated = ISO8601DateFormatter().string(from: now())
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO sessions
                (id, name, source_name, device_id, device_name, device_kind, title, started, duration_seconds,
                 status, error, engine, model, preview, revision, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                session.id, session.name, entry.sourceName, session.device.id, session.device.name,
                session.device.kind.rawValue, session.title, session.started, session.duration_seconds,
                session.status.rawValue, session.error, session.engine, session.model, session.preview,
                session.revision, session.updated,
            ])
        return session
    }

    // MARK: -

    private static func fetchOne(_ db: Database, _ condition: String, _ arguments: StatementArguments) throws -> Entry? {
        try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE \(condition)", arguments: arguments).map(entry(from:))
    }

    private static func entry(from row: Row) throws -> Entry {
        let kind: String = row["device_kind"]
        let status: String = row["status"]
        guard let deviceKind = HubDevice.Kind(rawValue: kind), let sessionStatus = HubSession.Status(rawValue: status)
        else { throw DatabaseError(message: "unknown device kind \(kind) or status \(status)") }
        return Entry(
            session: HubSession(
                id: row["id"],
                name: row["name"],
                device: HubDevice(id: row["device_id"], name: row["device_name"], kind: deviceKind),
                title: row["title"],
                started: row["started"],
                duration_seconds: row["duration_seconds"],
                status: sessionStatus,
                error: row["error"],
                engine: row["engine"],
                model: row["model"],
                preview: row["preview"],
                revision: row["revision"],
                updated: row["updated"]
            ),
            sourceName: row["source_name"]
        )
    }

    private static func sameContent(_ a: Entry, _ b: Entry) -> Bool {
        var a = a
        a.session.revision = b.session.revision
        a.session.updated = b.session.updated
        return a == b
    }
}
