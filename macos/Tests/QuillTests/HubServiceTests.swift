import XCTest

@testable import quill

/// The hub's folders-to-catalog rules: reconcile, folder naming, and status
/// from transcription events.
final class HubServiceTests: XCTestCase {
    private var hub: TestHub!

    override func setUpWithError() throws {
        hub = try TestHub(base: try makeTempDir(self))
    }

    func testReconcileIndexesEverySessionFolder() async throws {
        let own = try makeSession(in: hub.root, name: "2026.11.20-0900", title: "Weekly sync")
        try writeTranscript(in: own)
        let phone = try makeSession(in: hub.root, name: "2026.11.20-1000-iphone", files: ["mic.caf"])
        try FileManager.default.createDirectory(at: hub.root.appendingPathComponent("not-a-session"), withIntermediateDirectories: true)
        try makeSession(in: hub.service.incoming, name: UUID().uuidString)

        let count = await hub.service.reconcile()

        XCTAssertEqual(count, 2)
        let sessions = try hub.service.catalog.sessions(after: 0, limit: 500)
        XCTAssertEqual(sessions.map(\.name), ["2026.11.20-0900", "2026.11.20-1000-iphone"])

        let ownSession = sessions[0]
        XCTAssertEqual(ownSession.device, TestHub.hubDevice)
        XCTAssertEqual(ownSession.status, .transcribed)
        XCTAssertEqual(ownSession.title, "Weekly sync")
        XCTAssertEqual(ownSession.engine, "nemotron")
        XCTAssertEqual(ownSession.model, "test-model")
        XCTAssertEqual(ownSession.preview, "Ideally, what I have for next week is a plan.")
        XCTAssertEqual(ownSession.started, "2026-11-21T14:30:00Z")
        XCTAssertEqual(ownSession.duration_seconds, 1830)

        let phoneSession = sessions[1]
        XCTAssertEqual(phoneSession.device.kind, .iphone)
        XCTAssertEqual(phoneSession.device.name, "iPhone")
        XCTAssertEqual(phoneSession.status, .queued)
        XCTAssertNil(phoneSession.engine)

        // Sidecars make ids stable: a second reconcile, even with a new
        // catalog, finds the same ids and changes nothing.
        XCTAssertEqual(HubSidecar.read(in: phone)?.id, phoneSession.id)
        XCTAssertEqual(HubSidecar.read(in: own)?.source_name, "2026.11.20-0900")
        let revision = try hub.service.catalog.revision()
        await hub.service.reconcile()
        XCTAssertEqual(try hub.service.catalog.revision(), revision)

        try FileManager.default.removeItem(at: hub.catalogPath)
        let rebuilt = HubService(root: hub.root, catalog: try HubCatalog(path: hub.catalogPath), device: TestHub.hubDevice) { _ in }
        await rebuilt.reconcile()
        XCTAssertEqual(try rebuilt.catalog.sessions(after: 0, limit: 500).map(\.id), sessions.map(\.id))
    }

    func testReconcileTreatsNumberedIPhoneFoldersAsIPhone() async throws {
        try makeSession(in: hub.root, name: "2026.11.20-1000-iphone-2", files: ["mic.caf"])
        await hub.service.reconcile()
        let session = try XCTUnwrap(try hub.service.catalog.entry(named: "2026.11.20-1000-iphone-2")?.session)
        XCTAssertEqual(session.device, HubDevice.earlyIPhone)
    }

    /// A commit that crashed after its folder reached the root but before
    /// its catalog row: restart, reconcile, and the client's retry must give
    /// one session with the client's id.
    func testACommitInterruptedBeforeItsRowRecoversWithTheSameID() async throws {
        let id = UUID().uuidString
        let device = HubDevice(id: "7F1D0000-0000-0000-0000-000000000001", name: "Work MacBook", kind: .mac)
        let client = hub.root.deletingLastPathComponent().appendingPathComponent("client")
        let source = try makeSession(in: client, name: "2026.11.21-0930")
        // What the commit leaves in the root before the insert: complete.
        let landed = hub.root.appendingPathComponent("2026.11.21-0930-work-macbook")
        try FileManager.default.copyItem(at: source, to: landed)
        try HubSidecar(id: id, device: device, source_name: "2026.11.21-0930").write(to: landed)
        let request = CommitRequest(
            id: id, name: "2026.11.21-0930", device: device,
            files: ["mic.caf", "system.caf"].map { .init(name: $0, bytes: 4096) },
            meta: try Data(contentsOf: source.appendingPathComponent("meta.json")))

        // Restarted hub.
        let restarted = HubService(root: hub.root, catalog: try HubCatalog(path: hub.catalogPath), device: TestHub.hubDevice) { _ in }
        await restarted.reconcile()
        let retry = try await restarted.commit(request)

        guard case .existing(let session) = retry else { return XCTFail("\(retry)") }
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.device, device)
        XCTAssertEqual(session.name, "2026.11.21-0930-work-macbook")
        XCTAssertEqual(try restarted.catalog.sessions(after: 0, limit: 500).count, 1)

        // Without the reconcile, the retry itself finds the folder.
        try FileManager.default.removeItem(at: hub.catalogPath)
        let fresh = HubService(root: hub.root, catalog: try HubCatalog(path: hub.catalogPath), device: TestHub.hubDevice) { _ in }
        guard case .existing(let found) = try await fresh.commit(request) else { return XCTFail("duplicate") }
        XCTAssertEqual(found.id, id)
        XCTAssertEqual(try fresh.catalog.sessions(after: 0, limit: 500).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: hub.root.path).filter { !$0.hasPrefix(".") }.count, 1)
    }

    func testCommitStagesEverythingBeforeOneRename() async throws {
        let id = UUID().uuidString
        let device = HubDevice(id: "x", name: "Work MacBook", kind: .mac)
        let staged = hub.service.staging(id: id)
        try makeSession(in: staged.deletingLastPathComponent(), name: id)
        try FileManager.default.removeItem(at: staged.appendingPathComponent("meta.json"))
        try Data("partial".utf8).write(to: staged.appendingPathComponent(".upload-abc.part"))
        let request = CommitRequest(
            id: id, name: "2026.11.21-0930", device: device,
            files: ["mic.caf", "system.caf"].map { .init(name: $0, bytes: 4096) },
            meta: try JSONEncoder().encode(sessionMeta(files: ["mic.caf", "system.caf"])))

        guard case .created(let session) = try await hub.service.commit(request) else { return XCTFail() }

        let folder = hub.root.appendingPathComponent(session.name)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, [".hub.json", "meta.json", "mic.caf", "system.caf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testOldStagingFoldersAreRemoved() async throws {
        let old = hub.service.staging(id: UUID().uuidString)
        let recent = hub.service.staging(id: UUID().uuidString)
        for dir in [old, recent] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("mic.caf"))
        }
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        for url in [old, old.appendingPathComponent("mic.caf")] {
            try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: url.path)
        }

        let removed = await hub.service.pruneStaging()

        XCTAssertEqual(removed, [old.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testTranscriptionEventsMoveTheStatus() async throws {
        let dir = try makeSession(in: hub.root, name: "2026.11.21-0930")
        let queued = try await hub.service.index(dir)
        XCTAssertEqual(queued.status, .queued)

        await hub.service.handle(.started(dir))
        let started = try XCTUnwrap(try hub.service.catalog.session(id: queued.id))
        XCTAssertEqual(started.status, .transcribing)
        XCTAssertGreaterThan(started.revision, queued.revision)

        await hub.service.handle(.failed(dir, reason: "engine exploded"))
        let failed = try XCTUnwrap(try hub.service.catalog.session(id: queued.id))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "engine exploded")

        await hub.service.handle(.started(dir))
        try writeTranscript(in: dir, text: String(repeating: "word ", count: 100))
        await hub.service.handle(.finished(dir))
        let done = try XCTUnwrap(try hub.service.catalog.session(id: queued.id))
        XCTAssertEqual(done.status, .transcribed)
        XCTAssertNil(done.error)
        XCTAssertEqual(done.engine, "nemotron")
        XCTAssertEqual(done.preview.count, 200)
    }

    func testAnEventForAnUnknownFolderIndexesIt() async throws {
        let dir = try makeSession(in: hub.root, name: "2026.11.21-1100")
        await hub.service.handle(.started(dir))
        let session = try XCTUnwrap(try hub.service.catalog.entry(named: "2026.11.21-1100")?.session)
        XCTAssertEqual(session.status, .transcribing)
        XCTAssertEqual(session.device, TestHub.hubDevice)
        XCTAssertFalse(hub.service.isUploaded(dir))
    }

    func testHubFolderNamesCarryADeviceTag() {
        let mac = HubDevice(id: "x", name: "Sam's MacBook Pro", kind: .mac)
        let phone = HubDevice(id: "y", name: "Sam’s iPhone", kind: .iphone)
        XCTAssertEqual(HubNames.hubFolder(for: "2026.11.21-0930", device: mac), "2026.11.21-0930-macbook-pro")
        XCTAssertEqual(HubNames.hubFolder(for: "2026.11.21-0930-macbook-pro", device: mac), "2026.11.21-0930-macbook-pro")
        XCTAssertEqual(HubNames.hubFolder(for: "2026.11.21-0930-iphone", device: phone), "2026.11.21-0930-iphone")
        XCTAssertEqual(HubNames.hubFolder(for: "2026.11.21-0930", device: phone), "2026.11.21-0930-iphone")
        XCTAssertEqual(HubNames.hubFolder(for: "2026.11.21-0930-iphone-2", device: phone), "2026.11.21-0930-iphone-2")
        XCTAssertEqual(HubNames.hubFolder(for: "2026.11.21-0930-iphone-2", device: mac), "2026.11.21-0930-iphone-2")
        XCTAssertFalse(HubNames.isIPhoneFolder("2026.11.21-0930-iphone-x"))
        XCTAssertFalse(HubNames.isIPhoneFolder("2026.11.21-0930-iphones"))
        XCTAssertEqual(HubNames.slug("Studio"), "studio")
        XCTAssertEqual(HubNames.slug("Mac mini (2024)"), "mac-mini-2024")
        XCTAssertEqual(HubNames.slug("Zoë’s Mac"), "mac")
        XCTAssertEqual(HubNames.slug("💻"), "mac")
    }

    func testDoctorReportsTheHubCatalog() throws {
        let check = DoctorReport.checkHub(role: .hub(port: 8090), catalogPath: hub.catalogPath)
        guard case .ok = check.status else { return XCTFail("\(check.status)") }
        XCTAssertTrue(check.detail?.contains("127.0.0.1:8090") ?? false)
        XCTAssertTrue(check.detail?.contains(hub.catalogPath.path) ?? false)

        // A folder where the database file should be can't be opened.
        let blocked = hub.root.deletingLastPathComponent().appendingPathComponent("blocked.sqlite")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        guard case .fail = DoctorReport.checkHub(role: .hub(port: 8090), catalogPath: blocked).status else {
            return XCTFail("a blocked catalog passed")
        }
        guard case .ok = DoctorReport.checkHub(role: .standalone).status else { return XCTFail("standalone") }

        // A hub that won't transcribe leaves uploads queued forever.
        let off = DoctorReport.checkHub(role: .hub(port: 8090), catalogPath: hub.catalogPath, transcriptionEnabled: false)
        guard case .fail = off.status else { return XCTFail("\(off.status)") }
        XCTAssertNotNil(off.remediation)
    }

    func testOnlyPlainAudioFileNamesPass() {
        for good in ["mic.caf", "system-002.caf", "mic.wav", "room_1.m4a", "MIC.CAF"] {
            XCTAssertTrue(HubNames.isValidFile(good), good)
        }
        for bad in ["", "..", "../mic.caf", ".mic.caf", "mic.txt", "mic", "a/b.caf", "mic caf.caf", "mïc.caf", "meta.json"] {
            XCTAssertFalse(HubNames.isValidFile(bad), bad)
        }
        XCTAssertEqual(HubNames.sessionID("0b5c6e0e-6e0b-4b0c-9a39-1c5b0c2e7d11"), "0B5C6E0E-6E0B-4B0C-9A39-1C5B0C2E7D11")
        XCTAssertNil(HubNames.sessionID("../etc"))
    }
}
