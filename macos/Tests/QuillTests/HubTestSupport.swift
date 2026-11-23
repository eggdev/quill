import Foundation
import XCTest

@testable import quill

/// A temporary folder tree for one test, removed afterwards.
func makeTempDir(_ test: XCTestCase) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
}

/// A finished session folder: meta.json (v2) naming `files`, each holding
/// `bytes` bytes of fake audio.
@discardableResult
func makeSession(
    in root: URL, name: String, files: [String] = ["mic.caf", "system.caf"], bytes: Int = 4096, title: String? = nil
) throws -> URL {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (i, file) in files.enumerated() {
        try Data(repeating: UInt8(i + 1), count: bytes).write(to: dir.appendingPathComponent(file))
    }
    try sessionMeta(files: files, title: title).write(to: dir)
    return dir
}

func sessionMeta(files: [String], title: String? = nil) -> SessionMeta {
    let tracks = files.map { file in
        SessionMeta.Track(
            kind: file.hasPrefix("mic") ? .mic : .system, speaker: file.hasPrefix("mic") ? "me" : "them",
            status: .complete,
            segments: [
                .init(file: file, start_offset_ms: 0, end_offset_ms: 1000, frames_written: 48000, sample_rate_hz: 48000, channels: 1)
            ],
            interruptions: [], warnings: [])
    }
    return SessionMeta(
        schema_version: 2, started: "2026-11-21T14:30:00Z", ended: "2026-11-21T15:00:30Z", duration_seconds: 1830,
        status: .complete, tracks: tracks,
        meeting: title.map {
            .init(title: $0, calendar: "Work", scheduled_start: "2026-11-21T14:30:00Z", scheduled_end: "2026-11-21T15:00:00Z")
        })
}

/// What the transcription step would leave behind.
func writeTranscript(in dir: URL, text: String = "Ideally, what I have for next week is a plan.") throws {
    let transcript = Transcript(
        engine: "nemotron", model: "test-model", created_at: "2026-11-21T15:02:11Z",
        segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: text)])
    try transcript.write(to: dir)
}

/// Thread-safe collector for values seen in callbacks.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A hub on an ephemeral loopback port, backed by temporary folders.
/// `transcribe` stands in for the transcription queue: it gets each
/// committed folder, and the default writes a transcript and reports
/// started and finished like `TranscriptionCoordinator` does.
final class TestHub: @unchecked Sendable {
    let root: URL
    let catalogPath: URL
    let service: HubService
    let enqueued = Recorder<URL>()
    private(set) var url: URL!
    private var server: Task<Void, Error>?

    static let hubDevice = HubDevice(id: "11111111-1111-1111-1111-111111111111", name: "Mac mini", kind: .mac)

    enum Transcription {
        case none
        case succeed
        case fail(String)
    }

    init(base: URL, transcription: Transcription = .none) throws {
        root = base.appendingPathComponent("hub-recordings", isDirectory: true)
        catalogPath = base.appendingPathComponent("support/hub.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try HubCatalog(path: catalogPath)
        let enqueued = self.enqueued
        let ref = Recorder<HubService>()
        let service = HubService(root: root, catalog: catalog, device: Self.hubDevice) { dir in
            enqueued.append(dir)
            guard let hub = ref.values.first else { return }
            switch transcription {
            case .none:
                break
            case .succeed:
                Task {
                    await hub.handle(.started(dir))
                    try? writeTranscript(in: dir)
                    await hub.handle(.finished(dir))
                }
            case .fail(let reason):
                Task {
                    await hub.handle(.started(dir))
                    await hub.handle(.failed(dir, reason: reason))
                }
            }
        }
        ref.append(service)
        self.service = service
    }

    /// Serve on `port` (0 picks a free one) and wait until it listens.
    func start(port: Int = 0) async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let app = HubServer.application(hub: service, port: port) { bound in
            continuation.yield(bound)
            continuation.finish()
        }
        server = Task { try await app.run() }
        var iterator = stream.makeAsyncIterator()
        guard let bound = await iterator.next() else { throw URLError(.cannotConnectToHost) }
        url = URL(string: "http://127.0.0.1:\(bound)")!
    }

    func stop() {
        server?.cancel()
    }

    deinit { server?.cancel() }
}

/// A loopback port nothing listens on right now.
func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
    }
    guard bound else { throw URLError(.cannotConnectToHost) }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Raw HTTP for the server tests.
struct HTTP {
    let base: URL
    let session = URLSession(configuration: .ephemeral)

    struct Reply {
        let status: Int
        let data: Data
        let headers: [AnyHashable: Any]

        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.lowercased() == name.lowercased() }?.value as? String
        }
    }

    func send(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> Reply {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        return Reply(status: http.statusCode, data: data, headers: http.allHeaderFields)
    }
}

/// Wait up to `timeout` seconds for `condition`.
func eventually(timeout: TimeInterval = 10, _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}
