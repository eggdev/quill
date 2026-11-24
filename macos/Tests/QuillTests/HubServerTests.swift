import XCTest

@testable import quill

/// The hub API over real HTTP on an ephemeral loopback port, against the
/// contract in docs/hub-api.md.
final class HubServerTests: XCTestCase {
    private var base: URL!
    private var hub: TestHub!
    private var http: HTTP!
    private var client: URL!  // a client's recordings root

    private let id = "0B5C6E0E-6E0B-4B0C-9A39-1C5B0C2E7D11"
    private let device = HubDevice(id: "7F1D0000-0000-0000-0000-000000000001", name: "Sam's MacBook Pro", kind: .mac)

    override func setUp() async throws {
        base = try makeTempDir(self)
        hub = try TestHub(base: base)
        try await hub.start()
        http = HTTP(base: hub.url)
        client = base.appendingPathComponent("client", isDirectory: true)
    }

    override func tearDown() async throws {
        hub.stop()
    }

    private func upload(_ dir: URL, _ file: String, id: String? = nil) async throws -> HTTP.Reply {
        try await http.send("PUT", "/v1/uploads/\(id ?? self.id)/\(file)", body: try Data(contentsOf: dir.appendingPathComponent(file)))
    }

    private func commitBody(_ dir: URL, files: [String]? = nil, id: String? = nil) throws -> Data {
        let meta = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let names = try files ?? SessionMeta.readInputs(from: dir).inputs.map(\.file)
        let listed = names.map { CommitRequest.File(name: $0, bytes: HubService.size(of: dir.appendingPathComponent($0)) ?? 0) }
        return try CommitRequest.body(id: id ?? self.id, name: dir.lastPathComponent, device: device, files: listed, meta: meta)
    }

    // MARK: -

    func testHealth() async throws {
        let reply = try await http.send("GET", "/health")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.json["ok"] as? Bool, true)
        XCTAssertEqual(reply.json["service"] as? String, "quill-hub")
        XCTAssertEqual(reply.json["api"] as? Int, 1)
        XCTAssertEqual(reply.json["catalog"] as? String, hub.service.catalog.id)
    }

    func testUploadAndCommitCreateASession() async throws {
        let dir = try makeSession(in: client, name: "2026.11.21-0930", bytes: 3_000_000, title: "Weekly sync")

        let put = try await upload(dir, "mic.caf")
        XCTAssertEqual(put.status, 200)
        XCTAssertEqual(put.json["file"] as? String, "mic.caf")
        XCTAssertEqual(put.json["bytes"] as? Int, 3_000_000)
        _ = try await upload(dir, "system.caf")

        let commit = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))
        XCTAssertEqual(commit.status, 201, String(decoding: commit.data, as: UTF8.self))
        let session = try JSONDecoder().decode(HubSession.self, from: commit.data)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.name, "2026.11.21-0930-macbook-pro")
        XCTAssertEqual(session.device, device)
        XCTAssertEqual(session.title, "Weekly sync")
        XCTAssertEqual(session.status, .queued)
        XCTAssertNil(session.error)

        let folder = hub.root.appendingPathComponent(session.name)
        XCTAssertEqual(hub.enqueued.values, [folder])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("mic.caf")), try Data(contentsOf: dir.appendingPathComponent("mic.caf")))
        XCTAssertEqual(try SessionMeta.readInputs(from: folder).inputs.map(\.file), ["mic.caf", "system.caf"])
        XCTAssertEqual(HubSidecar.read(in: folder), HubSidecar(id: id, device: device, source_name: "2026.11.21-0930"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub.service.staging(id: id).path))
        XCTAssertTrue(hub.service.isUploaded(folder))

        let fetched = try await http.send("GET", "/v1/sessions/\(id.lowercased())")
        XCTAssertEqual(fetched.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(HubSession.self, from: fetched.data), session)

        let meta = try await http.send("GET", "/v1/sessions/\(id)/meta")
        XCTAssertEqual(meta.status, 200)
        XCTAssertEqual(meta.json["schema_version"] as? Int, 2)
    }

    func testCommitNamesTheFilesStillMissing() async throws {
        let dir = try makeSession(in: client, name: "2026.11.21-0930")
        _ = try await upload(dir, "mic.caf")

        let first = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))
        XCTAssertEqual(first.status, 409)
        XCTAssertEqual(first.json["error"] as? String, "missing_files")
        XCTAssertEqual(first.json["missing"] as? [String], ["system.caf"])

        // A size that differs from the request counts as missing too.
        try Data("short".utf8).write(to: hub.service.staging(id: id).appendingPathComponent("system.caf"))
        let second = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))
        XCTAssertEqual(second.json["missing"] as? [String], ["system.caf"])

        _ = try await upload(dir, "system.caf")
        let third = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))
        XCTAssertEqual(third.status, 201)
    }

    func testASecondCommitReturnsTheSameSession() async throws {
        let dir = try makeSession(in: client, name: "2026.11.21-0930")
        _ = try await upload(dir, "mic.caf")
        _ = try await upload(dir, "system.caf")
        let first = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))
        let second = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))

        XCTAssertEqual(first.status, 201)
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(HubSession.self, from: second.data).name, "2026.11.21-0930-macbook-pro")
        XCTAssertEqual(hub.enqueued.values.count, 1)

        let late = try await upload(dir, "mic.caf")
        XCTAssertEqual(late.status, 409)
        XCTAssertEqual(late.json["error"] as? String, "already_committed")
    }

    func testCollidingNamesGetACounter() async throws {
        for n in 0..<2 {
            let sessionID = UUID().uuidString
            let dir = try makeSession(in: client.appendingPathComponent("\(n)"), name: "2026.11.21-0930")
            _ = try await upload(dir, "mic.caf", id: sessionID)
            _ = try await upload(dir, "system.caf", id: sessionID)
            _ = try await http.send("POST", "/v1/sessions", body: try commitBody(dir, id: sessionID))
        }
        let list = try await http.send("GET", "/v1/sessions")
        let names = (list.json["sessions"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["2026.11.21-0930-macbook-pro", "2026.11.21-0930-macbook-pro-2"])
    }

    func testBadNamesAndIdsAreRefused() async throws {
        let body = Data("x".utf8)
        for file in ["meta.json", ".hidden.caf", "..%2Fescape.caf", "mic.txt", "a%20b.caf"] {
            let reply = try await http.send("PUT", "/v1/uploads/\(id)/\(file)", body: body)
            XCTAssertEqual(reply.status, 400, file)
            XCTAssertEqual(reply.json["error"] as? String, "bad_file_name", file)
        }
        let badID = try await http.send("PUT", "/v1/uploads/not-a-uuid/mic.caf", body: body)
        XCTAssertEqual(badID.status, 400)
        XCTAssertEqual(badID.json["error"] as? String, "bad_request")
        let traversal = try await http.send("PUT", "/v1/uploads/..%2F..%2Fetc/mic.caf", body: body)
        XCTAssertEqual(traversal.status, 400)

        let contents = try FileManager.default.contentsOfDirectory(atPath: hub.root.path)
        XCTAssertFalse(contents.contains("etc"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted(), ["hub-recordings", "support"])

        let unknownReply = try await http.send("GET", "/v1/sessions/not-a-uuid")
        XCTAssertEqual(unknownReply.json["error"] as? String, "not_found")
        let missingReply = try await http.send("GET", "/v1/sessions/\(UUID().uuidString)")
        XCTAssertEqual(missingReply.status, 404)
    }

    func testMalformedCommitsAreBadRequests() async throws {
        let dir = try makeSession(in: client, name: "2026.11.21-0930")
        let notJSON = try await http.send("POST", "/v1/sessions", body: Data("{".utf8))
        XCTAssertEqual(notJSON.status, 400)
        XCTAssertEqual(notJSON.json["error"] as? String, "bad_request")

        let uncovered = try await http.send("POST", "/v1/sessions", body: try commitBody(dir, files: ["mic.caf"]))
        XCTAssertEqual(uncovered.json["error"] as? String, "bad_request")

        var meta = sessionMeta(files: ["mic.caf"])
        meta.schema_version = 1
        let old = try CommitRequest.body(
            id: id, name: "x", device: device, files: [.init(name: "mic.caf", bytes: 1)], meta: try JSONEncoder().encode(meta))
        let oldReply = try await http.send("POST", "/v1/sessions", body: old)
        XCTAssertEqual(oldReply.json["error"] as? String, "bad_request")

        let escape = try CommitRequest.body(
            id: id, name: "../outside", device: device, files: [.init(name: "mic.caf", bytes: 1)],
            meta: try JSONEncoder().encode(sessionMeta(files: ["mic.caf"])))
        let escapedReply = try await http.send("POST", "/v1/sessions", body: escape)
        XCTAssertEqual(escapedReply.json["error"] as? String, "bad_request")
    }

    func testTranscriptIsNotReadyUntilTranscribed() async throws {
        let dir = try makeSession(in: client, name: "2026.11.21-0930")
        _ = try await upload(dir, "mic.caf")
        _ = try await upload(dir, "system.caf")
        let commit = try await http.send("POST", "/v1/sessions", body: try commitBody(dir))
        let folder = hub.root.appendingPathComponent(try JSONDecoder().decode(HubSession.self, from: commit.data).name)

        for path in ["transcript", "transcript.md"] {
            let reply = try await http.send("GET", "/v1/sessions/\(id)/\(path)")
            XCTAssertEqual(reply.status, 404)
            XCTAssertEqual(reply.json["error"] as? String, "not_ready")
        }

        await hub.service.handle(.started(folder))
        try writeTranscript(in: folder)
        // Written but not yet reported: still not ready.
        let earlyReply = try await http.send("GET", "/v1/sessions/\(id)/transcript")
        XCTAssertEqual(earlyReply.status, 404)
        await hub.service.handle(.finished(folder))

        let json = try await http.send("GET", "/v1/sessions/\(id)/transcript")
        XCTAssertEqual(json.status, 200)
        XCTAssertEqual(json.json["engine"] as? String, "nemotron")
        let md = try await http.send("GET", "/v1/sessions/\(id)/transcript.md")
        XCTAssertEqual(md.status, 200)
        XCTAssertTrue(md.header("Content-Type")?.hasPrefix("text/markdown") ?? false)
        XCTAssertTrue(String(decoding: md.data, as: UTF8.self).contains("Ideally"))

        let session = try JSONDecoder().decode(HubSession.self, from: try await http.send("GET", "/v1/sessions/\(id)").data)
        XCTAssertEqual(session.status, .transcribed)
        XCTAssertEqual(session.preview, "Ideally, what I have for next week is a plan.")
    }

    func testAudioDownloadsSupportASingleRange() async throws {
        let dir = try makeSession(in: hub.root, name: "2026.11.21-0930", files: ["mic.caf"], bytes: 0)
        let audio = Data((0..<1000).map { UInt8($0 % 256) })
        try audio.write(to: dir.appendingPathComponent("mic.caf"))
        let session = try await hub.service.index(dir)
        let path = "/v1/sessions/\(session.id)/audio/mic.caf"

        let whole = try await http.send("GET", path)
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.data, audio)
        XCTAssertEqual(whole.header("Accept-Ranges"), "bytes")
        XCTAssertEqual(whole.header("Content-Type"), "audio/x-caf")

        let part = try await http.send("GET", path, headers: ["Range": "bytes=100-199"])
        XCTAssertEqual(part.status, 206)
        XCTAssertEqual(part.data, audio[100...199])
        XCTAssertEqual(part.header("Content-Range"), "bytes 100-199/1000")
        XCTAssertEqual(part.header("Accept-Ranges"), "bytes")

        let tail = try await http.send("GET", path, headers: ["Range": "bytes=-10"])
        XCTAssertEqual(tail.status, 206)
        XCTAssertEqual(tail.data, audio[990...])

        let open = try await http.send("GET", path, headers: ["Range": "bytes=900-"])
        XCTAssertEqual(open.data, audio[900...])
        XCTAssertEqual(open.header("Content-Range"), "bytes 900-999/1000")

        let beyond = try await http.send("GET", path, headers: ["Range": "bytes=5000-"])
        XCTAssertEqual(beyond.status, 416)
        XCTAssertEqual(beyond.header("Content-Range"), "bytes */1000")

        let otherReply = try await http.send("GET", "/v1/sessions/\(session.id)/audio/other.caf")
        XCTAssertEqual(otherReply.status, 404)
    }

    func testListingPagesByRevision() async throws {
        for name in ["2026.11.21-0900", "2026.11.21-1000", "2026.11.21-1100"] {
            try await hub.service.index(try makeSession(in: hub.root, name: name))
        }
        let all = try await http.send("GET", "/v1/sessions")
        XCTAssertEqual((all.json["sessions"] as? [Any])?.count, 3)
        XCTAssertEqual(all.json["revision"] as? Int, 3)
        XCTAssertEqual(all.json["catalog"] as? String, hub.service.catalog.id)
        XCTAssertNotNil(HubNames.sessionID(hub.service.catalog.id))

        // A full page: the next `after` is the page's last revision; the
        // top-level revision is the hub's counter.
        let page = try await http.send("GET", "/v1/sessions?after=1&limit=1")
        let first = (page.json["sessions"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["name"] as? String, "2026.11.21-1000")
        XCTAssertEqual(first?["revision"] as? Int, 2)
        XCTAssertEqual(page.json["revision"] as? Int, 3)
        let next = try await http.send("GET", "/v1/sessions?after=2&limit=1")
        XCTAssertEqual((next.json["sessions"] as? [[String: Any]])?.first?["name"] as? String, "2026.11.21-1100")

        let none = try await http.send("GET", "/v1/sessions?after=3")
        XCTAssertEqual((none.json["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual(none.json["revision"] as? Int, 3)

        // A cursor above the counter: the catalog was rebuilt, start over.
        let rebuilt = try await http.send("GET", "/v1/sessions?after=40")
        XCTAssertEqual((rebuilt.json["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual(rebuilt.json["revision"] as? Int, 3)

        let badAfterReply = try await http.send("GET", "/v1/sessions?after=x")
        XCTAssertEqual(badAfterReply.status, 400)
    }

    /// `HubSetup` reports this error once; it must arrive, not hang.
    func testAPortInUseFailsToRun() async throws {
        let port = try XCTUnwrap(hub.url.port)
        let second = HubServer.application(hub: hub.service, port: port)
        do {
            try await second.run()
            XCTFail("a second server ran on a busy port")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("address already in use"), "\(error)")
        }
    }

    func testRangeParsing() {
        XCTAssertEqual(ByteRange.parse(nil, size: 10), .whole)
        XCTAssertEqual(ByteRange.parse("bytes=0-4", size: 10), .part(0...4))
        XCTAssertEqual(ByteRange.parse("bytes=5-100", size: 10), .part(5...9))
        XCTAssertEqual(ByteRange.parse("bytes=-3", size: 10), .part(7...9))
        XCTAssertEqual(ByteRange.parse("bytes=-30", size: 10), .part(0...9))
        XCTAssertEqual(ByteRange.parse("bytes=10-", size: 10), .unsatisfiable)
        XCTAssertEqual(ByteRange.parse("bytes=0-1,4-5", size: 10), .whole)
        XCTAssertEqual(ByteRange.parse("bytes=5-1", size: 10), .whole)
        XCTAssertEqual(ByteRange.parse("items=0-1", size: 10), .whole)
        XCTAssertEqual(ByteRange.parse("bytes=0-0", size: 0), .unsatisfiable)
    }
}
