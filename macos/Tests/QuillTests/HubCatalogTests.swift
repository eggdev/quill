import XCTest

@testable import quill

/// The catalog's revision counter: every change gets a new, higher revision,
/// and `after` returns exactly the changes a client has not seen.
final class HubCatalogTests: XCTestCase {
    private var catalog: HubCatalog!

    override func setUpWithError() throws {
        catalog = try HubCatalog(path: try makeTempDir(self).appendingPathComponent("hub.sqlite"))
    }

    private func entry(_ name: String, id: String = UUID().uuidString) -> HubCatalog.Entry {
        HubCatalog.Entry(
            session: HubSession(
                id: id, name: name, device: TestHub.hubDevice, title: nil, started: "2026-11-21T14:30:00Z",
                duration_seconds: 60, status: .queued, error: nil, engine: nil, model: nil, preview: "", revision: 0,
                updated: ""),
            sourceName: name)
    }

    func testEveryChangeTakesTheNextRevision() throws {
        let a = try catalog.save(entry("a"))
        let b = try catalog.save(entry("b"))
        XCTAssertEqual([a.revision, b.revision], [1, 2])
        XCTAssertFalse(a.updated.isEmpty)

        let changed = try XCTUnwrap(catalog.update(named: "a") { $0.status = .transcribing })
        XCTAssertEqual(changed.revision, 3)
        XCTAssertEqual(try catalog.revision(), 3)
        XCTAssertEqual(try catalog.session(id: a.id)?.status, .transcribing)
    }

    func testAnUnchangedSaveKeepsItsRevision() throws {
        let first = try catalog.save(entry("a", id: "A"))
        let again = try catalog.save(entry("a", id: "A"))
        XCTAssertEqual(again.revision, first.revision)
        XCTAssertEqual(try catalog.revision(), 1)
        XCTAssertEqual(try catalog.update(named: "a") { $0.status = .queued }?.revision, 1)
    }

    func testAfterListsChangesInRevisionOrder() throws {
        let a = try catalog.save(entry("a"))
        try catalog.save(entry("b"))
        try catalog.save(entry("c"))
        try catalog.update(named: "a") { $0.status = .transcribed }

        XCTAssertEqual(try catalog.sessions(after: 0, limit: 500).map(\.name), ["b", "c", "a"])
        XCTAssertEqual(try catalog.sessions(after: 2, limit: 500).map(\.name), ["c", "a"])
        XCTAssertEqual(try catalog.sessions(after: 2, limit: 1).map(\.name), ["c"])
        XCTAssertEqual(try catalog.sessions(after: 4, limit: 500), [])
        XCTAssertEqual(try catalog.session(id: a.id)?.revision, 4)
    }

    func testTheCatalogSurvivesReopening() throws {
        let path = catalog.path
        let saved = try catalog.save(entry("a"))
        catalog = nil
        let reopened = try HubCatalog(path: path)
        XCTAssertEqual(try reopened.session(id: saved.id), saved)
        XCTAssertEqual(try reopened.save(entry("b")).revision, 2)
    }

    func testTheCatalogIDIsStableForOneFileAndNewForANewFile() throws {
        let path = catalog.path
        let id = catalog.id
        XCTAssertEqual(HubNames.sessionID(id), id)  // an upper-case UUID
        catalog = nil
        XCTAssertEqual(try HubCatalog(path: path).id, id)

        try FileManager.default.removeItem(at: path)
        XCTAssertNotEqual(try HubCatalog(path: path).id, id)
        let other = try HubCatalog(path: path.deletingLastPathComponent().appendingPathComponent("other.sqlite"))
        XCTAssertNotEqual(other.id, id)
    }

    func testSessionObjectSpellsOutNulls() throws {
        let data = try JSONEncoder().encode(entry("a").session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["title", "error", "engine", "model"] {
            XCTAssertTrue(object[key] is NSNull, key)
        }
        XCTAssertEqual(object["duration_seconds"] as? Int, 60)
    }
}
