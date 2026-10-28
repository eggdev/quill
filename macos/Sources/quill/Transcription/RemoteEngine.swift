import Foundation

/// Transcription on another machine running `server/` (NVIDIA Parakeet for
/// the words, Sortformer for who spoke when). quill uploads each segment file
/// as-is, about 29 MB per hour of AAC, and gets timed, speaker-tagged
/// segments back. Reach it over a private network such as Tailscale; the
/// server has no authentication of its own.
///
/// `connect` checks the server first, so an unreachable host fails before
/// any audio is sent and the coordinator can fall back to the local engine.
actor RemoteEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        /// The server can't be reached or failed on its side. The session is
        /// worth transcribing locally instead.
        case unreachable(URL, String)
        /// The server read the request and rejected this file. Another engine
        /// would fail on it too.
        case rejected(URL, String)

        var description: String {
            switch self {
            case .unreachable(let url, let why): return "transcription server \(url.absoluteString) unreachable: \(why)"
            case .rejected(let url, let why): return "transcription server rejected \(url.lastPathComponent): \(why)"
            }
        }
    }

    nonisolated let name: String
    nonisolated let model: String
    private let base: URL

    private init(base: URL, name: String, model: String) {
        self.base = base
        self.name = name
        self.model = model
    }

    static func connect(_ base: URL) async throws -> RemoteEngine {
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 5
        let data = try await send(request, base: base) { try await URLSession.shared.data(for: $0) }
        struct Health: Decodable { let model: String }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else {
            throw EngineError.unreachable(base, "unexpected /health response")
        }
        return RemoteEngine(base: base, name: "nemo", model: health.model)
    }

    func prepare() async throws {}

    func transcribe(_ audio: URL, diarize: Bool) async throws -> [TranscriptSegment] {
        var components = URLComponents(
            url: base.appendingPathComponent("v1/transcribe"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "diarize", value: diarize ? "true" : "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // The server stays silent while it works: about 15 s per 10 minutes
        // of audio on a DGX Spark.
        request.timeoutInterval = 900
        let data = try await Self.send(request, base: base, file: audio) {
            try await URLSession.shared.upload(for: $0, fromFile: audio)
        }
        return try Self.segments(from: data, base: base)
    }

    func release() async {}

    /// Decode a /v1/transcribe response body.
    static func segments(from data: Data, base: URL) throws -> [TranscriptSegment] {
        struct Response: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
                let speaker: Int?
            }
            let segments: [Segment]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw EngineError.unreachable(base, "unexpected /v1/transcribe response")
        }
        return response.segments.map {
            TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
        }
    }

    /// Run a request and map failures: transport errors and 5xx mean the
    /// server is unusable right now, 4xx means this file is the problem.
    private static func send(
        _ request: URLRequest, base: URL, file: URL? = nil,
        _ perform: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw EngineError.unreachable(base, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(500), as: UTF8.self)
        if (200..<300).contains(status) { return data }
        if let file, (400..<500).contains(status) { throw EngineError.rejected(file, "HTTP \(status) \(body)") }
        throw EngineError.unreachable(base, "HTTP \(status) \(body)")
    }
}
