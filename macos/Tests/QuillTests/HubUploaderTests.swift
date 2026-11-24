import XCTest

@testable import quill

private func hasTranscript(_ dir: URL) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
}

/// A client Mac's uploader against an in-process hub whose transcription
/// step is faked: it writes a transcript and reports started and finished.
final class HubUploaderTests: XCTestCase {
    private var base: URL!
    private var client: URL!
    private let device = HubDevice(id: "7F1D0000-0000-0000-0000-000000000001", name: "Work MacBook", kind: .mac)
    private let fast = HubUploader.Timing(
        poll: .milliseconds(50), retryStart: .milliseconds(50), retryCap: .milliseconds(200), idle: .seconds(30))
    private let notifications = Recorder<String>()
    private let delivered = Recorder<URL>()

    override func setUpWithError() throws {
        base = try makeTempDir(self)
        client = base.appendingPathComponent("client", isDirectory: true)
    }

    private func uploader(_ url: URL, timing: HubUploader.Timing? = nil) -> HubUploader {
        let notifications = self.notifications
        let delivered = self.delivered
        return HubUploader(
            root: client, client: HubClient(base: url, session: URLSession(configuration: .ephemeral), timeout: 5),
            device: device, timing: timing ?? fast,
            notify: { title, _ in notifications.append(title) },
            delivered: { delivered.append($0) })
    }

    func testARecordingTravelsToTheHubAndItsTranscriptComesBack() async throws {
        let hub = try TestHub(base: base, transcription: .succeed)
        try await hub.start()
        defer { hub.stop() }
        let dir = try makeSession(in: client, name: "2026.11.21-0930", bytes: 2_000_000, title: "Weekly sync")
        let statuses = Recorder<HubUploader.Status>()

        let uploader = uploader(hub.url)
        await uploader.setStatusHandler { statuses.append($0) }
        await uploader.start()
        await uploader.enqueue(dir)
        let arrived = await eventually { hasTranscript(dir) }
        await uploader.stop()

        XCTAssertTrue(arrived)
        let sidecar = try XCTUnwrap(UploadSidecar.read(in: dir))
        XCTAssertEqual(sidecar.state, .done)
        let session = try XCTUnwrap(try hub.service.catalog.session(id: sidecar.id))
        XCTAssertEqual(session.name, "2026.11.21-0930-work-macbook")
        XCTAssertEqual(session.device, device)
        XCTAssertEqual(session.status, .transcribed)
        let hubFolder = hub.root.appendingPathComponent(session.name)
        XCTAssertEqual(
            try Data(contentsOf: dir.appendingPathComponent("transcript.json")), try Data(contentsOf: hubFolder.appendingPathComponent("transcript.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
        // The client keeps its audio.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertEqual(notifications.values, ["quill — transcript ready"])
        XCTAssertEqual(delivered.values.map(\.lastPathComponent), [dir.lastPathComponent])
        XCTAssertTrue(statuses.values.contains(.uploading(session: "2026.11.21-0930", queued: 0)))
        XCTAssertEqual(statuses.values.last, .idle)
    }

    /// Pass until nothing waits on the hub any more.
    private func settle(_ uploader: HubUploader) async throws -> HubUploader.Outcome {
        var outcome = await uploader.pass()
        for _ in 0..<200 where outcome == .waiting {
            try await Task.sleep(for: .milliseconds(20))
            outcome = await uploader.pass()
        }
        return outcome
    }

    func testAHubFailureIsReportedOnceAndWatchedUntilTheHubSucceeds() async throws {
        let hub = try TestHub(base: base, transcription: .fail("engine exploded"))
        try await hub.start()
        defer { hub.stop() }
        let dir = try makeSession(in: client, name: "2026.11.21-0930")

        var timing = fast
        timing.failedRecheck = .milliseconds(300)
        let uploader = uploader(hub.url, timing: timing)
        let outcome = try await settle(uploader)

        XCTAssertEqual(outcome, .idle)
        let sidecar = try XCTUnwrap(UploadSidecar.read(in: dir))
        XCTAssertEqual(sidecar.state, .hubFailed)
        XCTAssertEqual(sidecar.error, "engine exploded")
        XCTAssertFalse(hasTranscript(dir))
        XCTAssertEqual(notifications.values, ["quill — transcription failed"])

        // Within the recheck interval nothing is asked or repeated.
        _ = await uploader.pass()
        _ = await uploader.pass()
        XCTAssertEqual(notifications.values.count, 1)
        let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "engine exploded").count - 1, 1)

        // The hub retries at its next start, and this time it works.
        let folder = hub.root.appendingPathComponent(try XCTUnwrap(try hub.service.catalog.session(id: sidecar.id)).name)
        await hub.service.handle(.started(folder))
        try writeTranscript(in: folder)
        await hub.service.handle(.finished(folder))
        try await Task.sleep(for: .milliseconds(350))
        _ = await uploader.pass()

        XCTAssertTrue(hasTranscript(dir))
        XCTAssertEqual(UploadSidecar.read(in: dir)?.state, .done)
        XCTAssertEqual(notifications.values, ["quill — transcription failed", "quill — transcript ready"])
        XCTAssertEqual(delivered.values.count, 1)
        XCTAssertEqual(hub.enqueued.values.count, 1)
    }

    func testARefusalIsPermanent() async throws {
        let hub = try TestHub(base: base)
        try await hub.start()
        defer { hub.stop() }
        // A folder name the hub refuses.
        let dir = try makeSession(in: client, name: "bad name")

        let outcome = await uploader(hub.url).pass()

        XCTAssertEqual(outcome, .idle)
        XCTAssertEqual(UploadSidecar.read(in: dir)?.state, .failed)
        XCTAssertEqual(notifications.values, ["quill — transcription failed"])
        let again = await uploader(hub.url).pass()
        XCTAssertEqual(again, .idle)
        XCTAssertEqual(notifications.values.count, 1)
    }

    func testBackfillReplacesALocalTranscriptQuietly() async throws {
        let hub = try TestHub(base: base, transcription: .succeed)
        try await hub.start()
        defer { hub.stop() }
        let dir = try makeSession(in: client, name: "2026.11.01-0900")
        try writeTranscript(in: dir, text: "made locally by parakeet")
        let phone = try makeSession(in: client, name: "2026.11.01-1000-iphone-2", files: ["mic.caf"])

        let outcome = try await settle(uploader(hub.url))

        XCTAssertEqual(outcome, .idle)
        let sidecar = try XCTUnwrap(UploadSidecar.read(in: dir))
        XCTAssertEqual(sidecar.state, .done)
        XCTAssertTrue(sidecar.isBackfill)
        let json = try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("Ideally"))
        XCTAssertFalse(json.contains("parakeet"))
        XCTAssertNotNil(try hub.service.catalog.session(id: sidecar.id))
        XCTAssertEqual(notifications.values, [])
        XCTAssertEqual(delivered.values, [])
        // iPhone folders from the old iCloud path are the iPhone's to send.
        XCTAssertNil(UploadSidecar.read(in: phone))
        XCTAssertEqual(hub.enqueued.values.count, 1)
    }

    func testBackfillWaitsForNewRecordingsAndGoesOneAtATime() async throws {
        let hub = try TestHub(base: base)  // transcribes only when told to
        try await hub.start()
        defer { hub.stop() }
        let oldest = try makeSession(in: client, name: "2026.11.01-0900")
        try writeTranscript(in: oldest)
        let older = try makeSession(in: client, name: "2026.11.02-0900")
        try writeTranscript(in: older)
        let recent = try makeSession(in: client, name: "2026.11.21-0930")
        let uploader = uploader(hub.url)

        // The new recording goes first; no backfill while it waits.
        _ = await uploader.pass()
        XCTAssertEqual(UploadSidecar.read(in: recent)?.state, .committed)
        XCTAssertNil(UploadSidecar.read(in: oldest))
        XCTAssertNil(UploadSidecar.read(in: older))

        func finish(_ dir: URL) async throws {
            let id = try XCTUnwrap(UploadSidecar.read(in: dir)?.id)
            let folder = hub.root.appendingPathComponent(try XCTUnwrap(try hub.service.catalog.session(id: id)).name)
            try writeTranscript(in: folder)
            await hub.service.handle(.finished(folder))
        }

        // Once it is done, the oldest backfill goes, and only that one.
        try await finish(recent)
        _ = await uploader.pass()
        XCTAssertEqual(UploadSidecar.read(in: recent)?.state, .done)
        XCTAssertEqual(UploadSidecar.read(in: oldest)?.state, .committed)
        XCTAssertNil(UploadSidecar.read(in: older))
        _ = await uploader.pass()
        XCTAssertNil(UploadSidecar.read(in: older))

        try await finish(oldest)
        _ = await uploader.pass()
        XCTAssertEqual(UploadSidecar.read(in: oldest)?.state, .done)
        XCTAssertEqual(UploadSidecar.read(in: older)?.state, .committed)
        XCTAssertEqual(hub.enqueued.values.count, 3)
    }

    func testRecordingsWaitWhileTheHubIsDownAndGoOnceItIsBack() async throws {
        let port = try freePort()
        let dir = try makeSession(in: client, name: "2026.11.21-0930")
        let uploader = uploader(URL(string: "http://127.0.0.1:\(port)")!)

        let first = await uploader.pass()
        XCTAssertEqual(first, .unreachable)
        let sidecar = try XCTUnwrap(UploadSidecar.read(in: dir))
        XCTAssertEqual(sidecar.state, .sending)
        XCTAssertFalse(hasTranscript(dir))

        await uploader.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(hasTranscript(dir))

        let hub = try TestHub(base: base, transcription: .succeed)
        try await hub.start(port: port)
        defer { hub.stop() }
        let arrived = await eventually { hasTranscript(dir) }
        await uploader.stop()

        XCTAssertTrue(arrived)
        // The id made before the first attempt is the one the hub knows.
        XCTAssertEqual(UploadSidecar.read(in: dir)?.id, sidecar.id)
        XCTAssertNotNil(try hub.service.catalog.session(id: sidecar.id))
    }

    func testCommitResendsTheFilesTheHubLacks() async throws {
        let hub = try TestHub(base: base)
        try await hub.start()
        defer { hub.stop() }
        let dir = try makeSession(in: client, name: "2026.11.21-0930")
        let id = UUID().uuidString
        try UploadSidecar(id: id, state: .sending).write(to: dir)
        // An earlier attempt left a truncated mic.caf on the hub.
        let staged = hub.service.staging(id: id)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staged.appendingPathComponent("mic.caf"))

        let outcome = await uploader(hub.url).pass()

        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(UploadSidecar.read(in: dir)?.state, .committed)
        let session = try XCTUnwrap(try hub.service.catalog.session(id: id))
        XCTAssertEqual(
            HubService.size(of: hub.root.appendingPathComponent(session.name).appendingPathComponent("mic.caf")), 4096)
    }
}
