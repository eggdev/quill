import Foundation

/// The client end of the hub API (docs/hub-api.md), over URLSession.
struct HubClient: Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// No answer, or a 5xx: try again later.
        case unreachable(String)
        /// The hub refused the request (a 4xx it does not expect a retry
        /// to fix).
        case rejected(code: String, message: String)
        case missingFiles([String])
        case alreadyCommitted

        var description: String {
            switch self {
            case .unreachable(let why): return "hub unreachable: \(why)"
            case .rejected(let code, let message): return "hub refused (\(code)): \(message)"
            case .missingFiles(let names): return "hub is missing \(names.joined(separator: ", "))"
            case .alreadyCommitted: return "already committed"
            }
        }
    }

    let base: URL
    var session: URLSession = .shared
    var timeout: TimeInterval = 30

    func health() async throws {
        _ = try await send(request("health"), expect: [200])
    }

    /// Streams the file from disk; a recording is never loaded into memory.
    func upload(_ file: URL, id: String) async throws {
        var request = request("v1/uploads/\(id)/\(file.lastPathComponent)", method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Large files take longer than one request timeout to send.
        request.timeoutInterval = max(timeout, 600)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: file)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        _ = try check(data, response, expect: [200])
    }

    func commit(_ body: Data) async throws -> HubSession {
        var request = request("v1/sessions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try decode(try await send(request, expect: [200, 201]))
    }

    /// nil when the hub has no such session.
    func session(id: String) async throws -> HubSession? {
        do {
            return try decode(try await send(request("v1/sessions/\(id)"), expect: [200]))
        } catch Failure.rejected(code: "not_found", _) {
            return nil
        }
    }

    /// `transcript` (transcript.json) or `transcript.md`.
    func transcript(id: String, file: String) async throws -> Data {
        try await send(request("v1/sessions/\(id)/\(file)"), expect: [200])
    }

    // MARK: -

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        return request
    }

    private func send(_ request: URLRequest, expect: Set<Int>) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        return try check(data, response, expect: expect)
    }

    private func check(_ data: Data, _ response: URLResponse, expect: Set<Int>) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if expect.contains(status) { return data }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = body?["error"] as? String ?? "http_\(status)"
        let message = body?["message"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch (status, code) {
        case (409, "missing_files"): throw Failure.missingFiles(body?["missing"] as? [String] ?? [])
        case (409, "already_committed"): throw Failure.alreadyCommitted
        case (400..<500, _): throw Failure.rejected(code: code, message: message)
        default: throw Failure.unreachable("HTTP \(status) \(code)")
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.unreachable("unexpected answer: \(error)")
        }
    }
}
