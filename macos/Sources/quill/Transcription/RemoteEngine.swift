import Foundation

/// Transcription on another machine running `server/` (NVIDIA Nemotron 3.5
/// Transcribe: words, timestamps, and who spoke when from one model). quill
/// uploads a track's segment files as-is in one request, about 29 MB per hour
/// of AAC, and gets timed, speaker-tagged segments back for each file. Reach it over a private network such as Tailscale; the
/// server has no authentication of its own.
///
/// `connect` checks the server first, so an unreachable host fails before
/// any audio is sent and the coordinator can fall back to the local engine.
actor RemoteEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        /// The server can't be reached or failed on its side. The session is
        /// worth transcribing locally instead.
        case unreachable(URL, String)
        /// The server read the request and rejected its audio. Another engine
        /// would fail on it too.
        case rejected(String)

        var description: String {
            switch self {
            case .unreachable(let url, let why): return "transcription server \(url.absoluteString) unreachable: \(why)"
            case .rejected(let why): return "transcription server rejected the audio: \(why)"
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
        return RemoteEngine(base: base, name: "nemotron", model: health.model)
    }

    func prepare() async throws {}

    func transcribe(_ audio: URL, diarize: Bool) async throws -> [TranscriptSegment] {
        try await upload([audio], diarize: diarize)[0]
    }

    func transcribe(track files: [URL], diarize: Bool) async throws -> [[TranscriptSegment]]? {
        try await upload(files, diarize: diarize)
    }

    private func upload(_ files: [URL], diarize: Bool) async throws -> [[TranscriptSegment]] {
        var components = URLComponents(
            url: base.appendingPathComponent("v1/transcribe"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "diarize", value: diarize ? "true" : "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let boundary = "quill-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // The server stays silent while it works, up to a few minutes for an
        // hour-long track.
        request.timeoutInterval = 1800
        let body = try Self.multipart(files, boundary: boundary)
        let data = try await Self.send(request, base: base, checksAudio: true) {
            try await URLSession.shared.upload(for: $0, from: body)
        }
        let results = try Self.segments(from: data, base: base)
        guard results.count == files.count else {
            throw EngineError.unreachable(base, "\(results.count) results for \(files.count) files")
        }
        return results
    }

    /// Each file as an `audio` part, in track order.
    static func multipart(_ files: [URL], boundary: String) throws -> Data {
        var body = Data()
        for file in files {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(file.lastPathComponent)\"\r\n".utf8))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(try Data(contentsOf: file))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    func release() async {}

    /// Decode a /v1/transcribe response body: segments for each file.
    static func segments(from data: Data, base: URL) throws -> [[TranscriptSegment]] {
        struct Response: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
                let speaker: Int?
            }
            struct File: Decodable { let segments: [Segment] }
            let files: [File]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw EngineError.unreachable(base, "unexpected /v1/transcribe response")
        }
        return response.files.map { file in
            file.segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
        }
    }

    /// Run a request and map failures: transport errors and 5xx mean the
    /// server is unusable right now; 4xx on an audio upload means the audio
    /// is the problem.
    private static func send(
        _ request: URLRequest, base: URL, checksAudio: Bool = false,
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
        if checksAudio, (400..<500).contains(status) { throw EngineError.rejected("HTTP \(status) \(body)") }
        throw EngineError.unreachable(base, "HTTP \(status) \(body)")
    }
}
