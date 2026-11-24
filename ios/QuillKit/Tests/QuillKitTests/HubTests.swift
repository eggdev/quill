import XCTest

@testable import QuillKit

private let sessionJSON = """
    {
      "id": "0B5C6E0E-6E0B-4B0C-9A39-1C5B0C2E7D11",
      "name": "2026.11.21-0930-macbook",
      "device": { "id": "7F1D", "name": "MacBook Pro", "kind": "mac", "os": "macOS 27" },
      "title": "Weekly sync",
      "started": "2026-11-21T14:30:00Z",
      "duration_seconds": 1830,
      "status": "transcribed",
      "error": null,
      "engine": "nemotron",
      "model": "NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8",
      "preview": "Ideally, what I have for next week is…",
      "revision": 42,
      "updated": "2026-11-21T15:02:11Z",
      "speakers": ["me", "them"]
    }
    """

private func session(_ id: String, revision: Int, status: HubSession.Status = .queued) -> HubSession {
    HubSession(
        id: id, name: id, device: HubDevice(id: "D", name: "Mac", kind: "mac"), started: "2026-11-21T14:30:00Z",
        durationSeconds: 60, status: status, revision: revision)
}

private func json(_ s: String) -> Data { Data(s.utf8) }

final class HubModelTests: XCTestCase {
    func testDecodesTheContractSessionAndIgnoresUnknownFields() throws {
        let s = try JSONDecoder().decode(HubSession.self, from: json(sessionJSON))
        XCTAssertEqual(s.device.kind, "mac")
        XCTAssertEqual(s.title, "Weekly sync")
        XCTAssertEqual(s.durationSeconds, 1830)
        XCTAssertEqual(s.status, .transcribed)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.revision, 42)
        XCTAssertEqual(s.startedAt, ISO8601DateFormatter().date(from: "2026-11-21T14:30:00Z"))
    }

    func testToleratesNullsWhereTheContractAllowsThem() throws {
        let queued = """
            {"id":"A","name":"n","device":{"id":"D","name":"iPhone","kind":"iphone"},"title":null,
             "started":"2026-11-21T14:30:00.250Z","duration_seconds":12.6,"status":"compressing","error":null,
             "engine":null,"model":null,"preview":null,"revision":3,"updated":null}
            """
        let s = try JSONDecoder().decode(HubSession.self, from: json(queued))
        XCTAssertNil(s.title)
        XCTAssertNil(s.engine)
        XCTAssertEqual(s.preview, "")
        XCTAssertEqual(s.durationSeconds, 12)
        XCTAssertEqual(s.status, .other("compressing"))
        XCTAssertNotNil(s.startedAt)
    }

    func testSessionRoundTripsThroughTheCache() throws {
        let s = try JSONDecoder().decode(HubSession.self, from: json(sessionJSON))
        let again = try JSONDecoder().decode(HubSession.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again, s)
        let state = HubSyncState(revision: 42, sessions: [s.id: s])
        XCTAssertEqual(try JSONDecoder().decode(HubSyncState.self, from: JSONEncoder().encode(state)), state)
    }

    func testDecodesListAndErrorBodies() throws {
        let list = try JSONDecoder().decode(
            HubSessionList.self, from: json(#"{"sessions":[\#(sessionJSON)],"revision":42,"more":false}"#))
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(list.revision, 42)

        let error = try JSONDecoder().decode(
            HubErrorBody.self, from: json(#"{"error":"missing_files","message":"x","missing":["mic-002.caf"]}"#))
        XCTAssertEqual(error.missing, ["mic-002.caf"])
    }
}

final class HubAPITests: XCTestCase {
    private let api = HubAPI(base: URL(string: "https://mac.tailnet.ts.net:8090")!)

    func testAddressAssumesHTTPS() {
        XCTAssertEqual(HubAddress.parse("mac.tailnet.ts.net:8090")?.absoluteString, "https://mac.tailnet.ts.net:8090")
        XCTAssertEqual(HubAddress.parse("  https://mac.tailnet.ts.net:8090/ ")?.absoluteString, "https://mac.tailnet.ts.net:8090")
        XCTAssertEqual(HubAddress.parse("http://localhost:8090")?.absoluteString, "http://localhost:8090")
        XCTAssertEqual(HubAddress.parse("HTTPS://Mac.local")?.scheme, "https")
        XCTAssertNil(HubAddress.parse(""))
        XCTAssertNil(HubAddress.parse("ftp://mac"))
        XCTAssertNil(HubAddress.parse("not an address"))
    }

    func testRequests() {
        XCTAssertEqual(api.health().url?.absoluteString, "https://mac.tailnet.ts.net:8090/health")
        XCTAssertEqual(api.health().httpMethod, "GET")

        let upload = api.upload(sessionID: "ABC", file: "mic-002.caf")
        XCTAssertEqual(upload.url?.absoluteString, "https://mac.tailnet.ts.net:8090/v1/uploads/ABC/mic-002.caf")
        XCTAssertEqual(upload.httpMethod, "PUT")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")

        let commit = api.commit()
        XCTAssertEqual(commit.url?.absoluteString, "https://mac.tailnet.ts.net:8090/v1/sessions")
        XCTAssertEqual(commit.httpMethod, "POST")
        XCTAssertEqual(commit.value(forHTTPHeaderField: "Content-Type"), "application/json")

        XCTAssertEqual(
            api.sessions(after: 42).url?.absoluteString, "https://mac.tailnet.ts.net:8090/v1/sessions?after=42&limit=500")
        XCTAssertEqual(api.session(id: "ABC").url?.path, "/v1/sessions/ABC")
        XCTAssertEqual(api.transcript(id: "ABC").url?.path, "/v1/sessions/ABC/transcript")
    }

    func testRequestsKeepABasePath() {
        let proxied = HubAPI(base: URL(string: "https://proxy.example/quill")!)
        XCTAssertEqual(proxied.health().url?.absoluteString, "https://proxy.example/quill/health")
    }

    func testCommitBodyCarriesMetaUnchanged() throws {
        let meta = json(#"{"schema_version":2,"tracks":[],"future_field":{"kept":true}}"#)
        let device = HubDevice(id: "D", name: "iPhone", kind: "iphone")
        let body = try HubCommit.body(
            id: "ABC", name: "2026.11.21-0930-iphone", device: device,
            files: [HubCommit.File(name: "mic.caf", bytes: 3_512_345)], meta: meta)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "ABC")
        XCTAssertEqual(object["name"] as? String, "2026.11.21-0930-iphone")
        XCTAssertEqual((object["device"] as? [String: String])?["kind"], "iphone")
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["name"] as? String, "mic.caf")
        XCTAssertEqual(files.first?["bytes"] as? Int, 3_512_345)
        let sentMeta = try XCTUnwrap(object["meta"] as? [String: Any])
        XCTAssertEqual((sentMeta["future_field"] as? [String: Bool])?["kept"], true)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix(#""meta":\#(String(decoding: meta, as: UTF8.self))}"#))

        XCTAssertThrowsError(try HubCommit.body(id: "A", name: "n", device: device, files: [], meta: json("[1]")))
    }

    func testUploadAnswers() {
        func upload(_ status: Int, _ body: String) -> HubResponse.Upload {
            HubResponse.upload(status: status, body: json(body), file: "mic.caf", bytes: 3_512_345)
        }
        XCTAssertEqual(upload(200, #"{"file":"mic.caf","bytes":3512345}"#), .stored)
        XCTAssertEqual(upload(409, #"{"error":"already_committed","message":"x"}"#), .alreadyCommitted)
        XCTAssertEqual(upload(400, #"{"error":"bad_file_name","message":"no"}"#), .rejected("no"))
        XCTAssertEqual(upload(502, "<html>"), .retry)
        XCTAssertEqual(upload(400, "<html>"), .retry)
    }

    func testUploadIsStoredOnlyWhenTheHubConfirmsTheFileAndSize() {
        func upload(_ body: String) -> HubResponse.Upload {
            HubResponse.upload(status: 200, body: json(body), file: "mic.caf", bytes: 3_512_345)
        }
        XCTAssertEqual(upload("OK"), .retry)
        XCTAssertEqual(upload("{}"), .retry)
        XCTAssertEqual(upload(#"{"file":"mic.caf","bytes":100}"#), .retry)
        XCTAssertEqual(upload(#"{"file":"mic-002.caf","bytes":3512345}"#), .retry)
    }

    func testCommitAnswers() throws {
        let id = "0B5C6E0E-6E0B-4B0C-9A39-1C5B0C2E7D11"
        let s = try JSONDecoder().decode(HubSession.self, from: json(sessionJSON))
        XCTAssertEqual(HubResponse.commit(status: 201, body: json(sessionJSON), sessionID: id), .committed(s))
        XCTAssertEqual(HubResponse.commit(status: 200, body: json(sessionJSON), sessionID: id), .committed(s))
        // The hub returns ids in upper case; a lower-case local id still matches.
        XCTAssertEqual(HubResponse.commit(status: 200, body: json(sessionJSON), sessionID: id.lowercased()), .committed(s))
        XCTAssertEqual(
            HubResponse.commit(
                status: 409, body: json(#"{"error":"missing_files","missing":["system.caf"]}"#), sessionID: id),
            .missing(["system.caf"]))
        XCTAssertEqual(
            HubResponse.commit(status: 400, body: json(#"{"error":"bad_request","message":"schema"}"#), sessionID: id),
            .rejected("schema"))
        XCTAssertEqual(HubResponse.commit(status: 409, body: json(#"{"error":"busy"}"#), sessionID: id), .retry)
        XCTAssertEqual(HubResponse.commit(status: 500, body: Data(), sessionID: id), .retry)
    }

    func testCommitIsProvenOnlyByTheCommittedSession() {
        let id = "0B5C6E0E-6E0B-4B0C-9A39-1C5B0C2E7D11"
        // Something at a wrong address that answers 200 to everything.
        XCTAssertEqual(HubResponse.commit(status: 200, body: json("<html>OK</html>"), sessionID: id), .retry)
        XCTAssertEqual(HubResponse.commit(status: 201, body: json("{}"), sessionID: id), .retry)
        XCTAssertEqual(HubResponse.commit(status: 200, body: json(sessionJSON), sessionID: "SOMEONE-ELSE"), .retry)
    }

    func testHealthAnswers() {
        XCTAssertEqual(HubResponse.health(status: 200, body: json(#"{"ok":true,"service":"quill-hub","api":1}"#)), .ok)
        XCTAssertEqual(HubResponse.health(status: 200, body: json(#"{"ok":true,"service":"other"}"#)), .notAHub)
        XCTAssertEqual(HubResponse.health(status: 200, body: json("<html>")), .notAHub)
        XCTAssertEqual(HubResponse.health(status: 404, body: Data()), .failed(status: 404))
    }
}

final class HubSyncTests: XCTestCase {
    func testInsertsReplacesAndAdvances() {
        var state = HubSyncState()
        XCTAssertFalse(state.apply(HubSessionList(sessions: [session("A", revision: 1), session("B", revision: 2)], revision: 2), after: 0))
        XCTAssertEqual(state.revision, 2)
        XCTAssertEqual(state.sessions.count, 2)

        XCTAssertFalse(
            state.apply(HubSessionList(sessions: [session("A", revision: 3, status: .transcribed)], revision: 3), after: 2))
        XCTAssertEqual(state.revision, 3)
        XCTAssertEqual(state.sessions["A"]?.status, .transcribed)
        XCTAssertEqual(state.sessions.count, 2)
    }

    func testNothingChangedKeepsTheCursor() {
        var state = HubSyncState(revision: 5, sessions: ["A": session("A", revision: 5)])
        XCTAssertFalse(state.apply(HubSessionList(sessions: [], revision: 5), after: 5))
        XCTAssertEqual(state.revision, 5)
        XCTAssertEqual(state.sessions.count, 1)
    }

    func testFullPageContinuesFromItsLastSessionThenShortPageTakesTheCounter() {
        var state = HubSyncState()
        // The hub's counter (9) is past this page: more sessions follow.
        let full = HubSessionList(sessions: [session("A", revision: 1), session("B", revision: 2)], revision: 9)
        XCTAssertTrue(state.apply(full, after: 0, limit: 2))
        XCTAssertEqual(state.revision, 2)

        let short = HubSessionList(sessions: [session("C", revision: 9)], revision: 9)
        XCTAssertFalse(state.apply(short, after: 2, limit: 2))
        XCTAssertEqual(state.revision, 9)
        XCTAssertEqual(state.sessions.count, 3)
    }

    func testFullPageThatDoesNotAdvanceStops() {
        var state = HubSyncState(revision: 2)
        let page = HubSessionList(sessions: [session("A", revision: 1), session("B", revision: 2)], revision: 2)
        XCTAssertFalse(state.apply(page, after: 2, limit: 2))
        XCTAssertEqual(state.revision, 2)
    }

    func testShortPageStoresTheHubCounter() {
        // Another session changed since: the counter is past this page.
        var state = HubSyncState(revision: 4)
        XCTAssertFalse(state.apply(HubSessionList(sessions: [session("A", revision: 5)], revision: 7), after: 4))
        XCTAssertEqual(state.revision, 7)
    }

    func testOlderRevisionDoesNotOverwriteNewer() {
        var state = HubSyncState(revision: 9, sessions: ["A": session("A", revision: 9, status: .transcribed)])
        _ = state.apply(HubSessionList(sessions: [session("A", revision: 4)], revision: 9), after: 9)
        XCTAssertEqual(state.sessions["A"]?.status, .transcribed)
    }

    func testSameCatalogKeepsTheCache() {
        var state = HubSyncState(revision: 5, sessions: ["A": session("A", revision: 5)], catalog: "C1")
        XCTAssertFalse(state.apply(HubSessionList(sessions: [session("B", revision: 6)], revision: 6, catalog: "C1"), after: 5))
        XCTAssertEqual(Set(state.sessions.keys), ["A", "B"])
        XCTAssertEqual(state.revision, 6)
        XCTAssertEqual(state.catalog, "C1")
    }

    func testDifferentCatalogStartsOverFromZero() throws {
        var state = HubSyncState(revision: 500, sessions: ["A": session("A", revision: 500)], catalog: "C1")
        // A rebuilt catalog's counter can already be past the old cursor.
        let rebuilt = try JSONDecoder().decode(
            HubSessionList.self, from: json(#"{"sessions":[],"revision":900,"catalog":"C2"}"#))
        XCTAssertTrue(state.apply(rebuilt, after: 500))
        XCTAssertEqual(state, HubSyncState(catalog: "C2"))
        XCTAssertEqual(state.revision, 0)  // the next ask is after=0

        XCTAssertFalse(
            state.apply(HubSessionList(sessions: [session("B", revision: 3)], revision: 900, catalog: "C2"), after: 0))
        XCTAssertEqual(Array(state.sessions.keys), ["B"])
        XCTAssertEqual(state.revision, 900)
        XCTAssertEqual(state.catalog, "C2")
    }

    func testCacheWithoutACatalogRefetchesOnce() {
        var state = HubSyncState(revision: 9, sessions: ["A": session("A", revision: 9)])
        XCTAssertTrue(state.apply(HubSessionList(sessions: [], revision: 9, catalog: "C1"), after: 9))
        XCTAssertEqual(state, HubSyncState(catalog: "C1"))

        XCTAssertFalse(
            state.apply(HubSessionList(sessions: [session("A", revision: 9)], revision: 9, catalog: "C1"), after: 0))
        XCTAssertEqual(state.sessions.count, 1)
        // From now on the stored id matches: no more resets.
        XCTAssertFalse(state.apply(HubSessionList(sessions: [], revision: 9, catalog: "C1"), after: 9))
        XCTAssertEqual(state.sessions.count, 1)
    }

    func testFirstListOnAFreshInstallStoresTheCatalogWithoutAskingTwice() {
        var state = HubSyncState()
        XCTAssertFalse(
            state.apply(HubSessionList(sessions: [session("A", revision: 1)], revision: 1, catalog: "C1"), after: 0))
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.catalog, "C1")
    }

    func testAnswerWithoutACatalogDiscardsNothing() throws {
        var state = HubSyncState(revision: 5, sessions: ["A": session("A", revision: 5)], catalog: "C1")
        let page = try JSONDecoder().decode(HubSessionList.self, from: json(#"{"sessions":[],"revision":5}"#))
        XCTAssertNil(page.catalog)
        XCTAssertFalse(state.apply(page, after: 5))
        XCTAssertEqual(state, HubSyncState(revision: 5, sessions: ["A": session("A", revision: 5)], catalog: "C1"))
    }

    func testLowerCounterIsNoLongerARebuildSignal() {
        var state = HubSyncState(revision: 50, sessions: ["A": session("A", revision: 50)], catalog: "C1")
        XCTAssertFalse(state.apply(HubSessionList(sessions: [], revision: 3, catalog: "C1"), after: 50))
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.catalog, "C1")
    }

    func testCatalogRoundTripsThroughTheCacheAndOldCachesDecode() throws {
        let state = HubSyncState(revision: 4, sessions: [:], catalog: "C1")
        XCTAssertEqual(try JSONDecoder().decode(HubSyncState.self, from: JSONEncoder().encode(state)), state)
        let old = try JSONDecoder().decode(HubSyncState.self, from: json(#"{"revision":4,"sessions":{}}"#))
        XCTAssertNil(old.catalog)
    }
}

final class HubFolderPolicyTests: XCTestCase {
    private let folder = "2026.10.26-1530-iphone"
    private var catalogWithFolder: HubCatalog { HubCatalog([session(folder, revision: 1)]) }
    private var catalogWithout: HubCatalog { HubCatalog([session("other", revision: 1)]) }

    private func needsUpload(_ d: HubDelivery?, legacy: Bool, _ catalog: HubCatalog?) -> Bool {
        HubFolderPolicy.needsUpload(name: folder, delivery: d, legacySent: legacy, catalog: catalog)
    }

    private func mayPrune(_ d: HubDelivery?, legacy: Bool, _ catalog: HubCatalog?) -> Bool {
        HubFolderPolicy.mayPruneAudio(name: folder, delivery: d, legacySent: legacy, catalog: catalog)
    }

    func testNewRecordingUploadsUntilCommitted() {
        var d = HubDelivery(id: "A")
        XCTAssertTrue(needsUpload(nil, legacy: false, nil))
        XCTAssertTrue(needsUpload(d, legacy: false, nil))
        XCTAssertFalse(mayPrune(d, legacy: false, catalogWithFolder))
        d.committed = true
        XCTAssertFalse(needsUpload(d, legacy: false, nil))
        XCTAssertTrue(mayPrune(d, legacy: false, nil))
    }

    func testOldICloudFolderWaitsForTheHubsList() {
        XCTAssertFalse(needsUpload(nil, legacy: true, nil))
        XCTAssertFalse(mayPrune(nil, legacy: true, nil))
    }

    func testOldICloudFolderTheHubHasCountsAsSent() {
        XCTAssertFalse(needsUpload(nil, legacy: true, catalogWithFolder))
        XCTAssertTrue(mayPrune(nil, legacy: true, catalogWithFolder))
    }

    func testOldICloudFolderTheHubLacksIsUploadedAndKept() {
        XCTAssertTrue(needsUpload(nil, legacy: true, catalogWithout))
        XCTAssertFalse(mayPrune(nil, legacy: true, catalogWithout))

        // Once it has a sidecar it follows the normal path, whatever the list says.
        var d = HubDelivery(id: "NEW")
        XCTAssertTrue(needsUpload(d, legacy: true, catalogWithFolder))
        XCTAssertFalse(mayPrune(d, legacy: true, catalogWithout))
        XCTAssertTrue(mayPrune(d, legacy: true, HubCatalog([session("NEW", revision: 2)])))
        d.committed = true
        XCTAssertFalse(needsUpload(d, legacy: true, catalogWithout))
        XCTAssertTrue(mayPrune(d, legacy: true, nil))
    }

    func testRefusedFolderIsNotUploadedOrPruned() {
        var d = HubDelivery(id: "A")
        d.rejected = HubDelivery.missingFileReason
        XCTAssertFalse(needsUpload(d, legacy: false, catalogWithout))
        XCTAssertFalse(mayPrune(d, legacy: false, catalogWithout))
    }
}

final class HubDeliveryTests: XCTestCase {
    private let folder = "2026.11.21-0930-iphone"
    private let files = [HubCommit.File(name: "mic.caf", bytes: 100), HubCommit.File(name: "mic-002.caf", bytes: 200)]

    func testUploadsEveryFileThenCommits() {
        var d = HubDelivery(id: "A")
        XCTAssertEqual(
            d.tasks(folder: folder, files: files, running: []),
            [.upload(folder: folder, file: "mic.caf"), .upload(folder: folder, file: "mic-002.caf")])

        d.uploaded["mic.caf"] = 100
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: []), [.upload(folder: folder, file: "mic-002.caf")])
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: [.upload(folder: folder, file: "mic-002.caf")]), [])

        d.uploaded["mic-002.caf"] = 200
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: []), [.commit(folder: folder)])
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: [.commit(folder: folder)]), [])

        d.committed = true
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: []), [])
    }

    func testAFileWhoseSizeChangedUploadsAgain() {
        var d = HubDelivery(id: "A")
        d.uploaded = ["mic.caf": 100, "mic-002.caf": 150]
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: []), [.upload(folder: folder, file: "mic-002.caf")])
    }

    func testRejectedRecordingStops() {
        var d = HubDelivery(id: "A")
        d.rejected = "bad_request"
        XCTAssertEqual(d.tasks(folder: folder, files: files, running: []), [])
    }

    func testRecordingWithNoAudioCommitsAtOnce() {
        XCTAssertEqual(HubDelivery(id: "A").tasks(folder: folder, files: [], running: []), [.commit(folder: folder)])
    }

    func testTaskNamesRoundTrip() {
        for task in [HubTask.upload(folder: folder, file: "mic-002.caf"), .commit(folder: folder)] {
            XCTAssertEqual(HubTask(description: task.description), task)
        }
        XCTAssertNil(HubTask(description: "upload/only-folder"))
        XCTAssertNil(HubTask(description: "refresh/x"))
    }

    func testSidecarAndFileSizesOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(HubDelivery.read(in: dir))
        var d = HubDelivery()
        d.uploaded["mic.caf"] = 3
        try d.write(to: dir)
        XCTAssertEqual(HubDelivery.read(in: dir), d)

        // Fields added later default rather than lose the id.
        try json(#"{"id":"OLD"}"#).write(to: dir.appendingPathComponent(HubDelivery.fileName))
        XCTAssertEqual(HubDelivery.read(in: dir), HubDelivery(id: "OLD"))

        XCTAssertFalse(HubDelivery.isLegacySent(dir))
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".sent").path, contents: nil)
        XCTAssertTrue(HubDelivery.isLegacySent(dir))

        var t = CaptureTimeline()
        _ = t.openSegment(atMs: 0)
        t.interrupt(atMs: 1000, reason: "call")
        _ = t.openSegment(atMs: 2000)
        t.finish(atMs: 3000)
        let manifest = SessionManifest(
            started: Date(), ended: Date(), timeline: t, audio: { _ in SegmentAudio(frames: 1, sampleRateHz: 48_000, channels: 1) })
        XCTAssertNil(HubDelivery.files(of: manifest, in: dir))

        try Data(count: 5).write(to: dir.appendingPathComponent("mic.caf"))
        try Data(count: 7).write(to: dir.appendingPathComponent("mic-002.caf"))
        XCTAssertEqual(
            HubDelivery.files(of: manifest, in: dir),
            [HubCommit.File(name: "mic.caf", bytes: 5), HubCommit.File(name: "mic-002.caf", bytes: 7)])
    }
}
