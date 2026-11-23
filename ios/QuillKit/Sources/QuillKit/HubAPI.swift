import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The hub's address as the user types it: "mac.tailnet.ts.net:8090" means
/// HTTPS, since that's what `tailscale serve` publishes.
public enum HubAddress {
    public static func parse(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s),
            let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = c.host, !host.isEmpty
        else { return nil }
        c.scheme = scheme
        while c.path.hasSuffix("/") { c.path.removeLast() }
        c.query = nil
        c.fragment = nil
        return c.url
    }
}

/// Requests for each endpoint the app uses, built without touching the
/// network so tests can check them.
public struct HubAPI: Sendable {
    /// The contract's maximum page, sent explicitly so a full page is known.
    public static let pageLimit = 500

    public var base: URL

    public init(base: URL) {
        self.base = base
    }

    public func health() -> URLRequest {
        request("health")
    }

    /// The body is the raw file, sent from disk by the caller.
    public func upload(sessionID: String, file: String) -> URLRequest {
        var r = request("v1/uploads/\(sessionID)/\(file)", method: "PUT")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// The body is `HubCommit.body(...)`, sent from a file so the request can
    /// run in a background session.
    public func commit() -> URLRequest {
        var r = request("v1/sessions", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    public func sessions(after revision: Int, limit: Int = HubAPI.pageLimit) -> URLRequest {
        request(
            "v1/sessions",
            query: [URLQueryItem(name: "after", value: String(revision)), URLQueryItem(name: "limit", value: String(limit))])
    }

    public func session(id: String) -> URLRequest {
        request("v1/sessions/\(id)")
    }

    public func transcript(id: String) -> URLRequest {
        request("v1/sessions/\(id)/transcript")
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = c.path + "/" + path
        c.queryItems = query.isEmpty ? nil : query
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }
}

/// `POST /v1/sessions`'s body.
public struct HubCommit: Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var name: String
        public var bytes: Int64

        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }
    }

    public enum BodyError: Error { case metaIsNotAnObject }

    private struct Head: Encodable {
        var id: String
        var name: String
        var device: HubDevice
        var files: [File]
    }

    /// `meta` goes in as the bytes of meta.json, unchanged: the contract asks
    /// for the file as written, and decoding it here would drop the fields
    /// this app doesn't model.
    public static func body(id: String, name: String, device: HubDevice, files: [File], meta: Data) throws -> Data {
        guard (try? JSONSerialization.jsonObject(with: meta)) is [String: Any] else { throw BodyError.metaIsNotAnObject }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = try encoder.encode(Head(id: id, name: name, device: device, files: files))
        body.removeLast()  // the closing brace, reopened for "meta"
        body.append(Data(#","meta":"#.utf8))
        body.append(meta)
        body.append(Data("}".utf8))
        return body
    }
}

/// What the hub's answers mean to a client. Anything not listed (a 5xx, a
/// proxy's error page, an unknown code) is `retry`: the protocol is
/// idempotent, so trying the step again later is always safe.
public enum HubResponse {
    public enum Upload: Equatable, Sendable {
        case stored
        /// The session was committed before; commit again to see it.
        case alreadyCommitted
        /// The hub will never take this file; retrying can't help.
        case rejected(String)
        case retry
    }

    public enum Commit: Equatable, Sendable {
        case committed(HubSession)
        case missing([String])
        case rejected(String)
        case retry
    }

    public enum Health: Equatable, Sendable {
        case ok
        /// Something answered, but not a Quill hub.
        case notAHub
        case failed(status: Int)
    }

    /// A 200 counts only when the hub says it stored this file at this
    /// size: anything at a wrong address can answer 200.
    public static func upload(status: Int, body: Data, file: String, bytes: Int64) -> Upload {
        if status == 200 {
            guard let receipt = try? JSONDecoder().decode(HubUploadReceipt.self, from: body),
                receipt.file == file, receipt.bytes == bytes
            else { return .retry }
            return .stored
        }
        let error = try? JSONDecoder().decode(HubErrorBody.self, from: body)
        switch (status, error?.error) {
        case (409, "already_committed"): return .alreadyCommitted
        case (400, let code?): return .rejected(error?.message ?? code)
        default: return .retry
        }
    }

    /// A 200 or 201 counts only with the committed session in the body:
    /// marking a recording sent lets its audio be deleted later, so a stray
    /// 200 from something that isn't the hub must not do it.
    public static func commit(status: Int, body: Data, sessionID: String) -> Commit {
        if status == 200 || status == 201 {
            guard let session = try? JSONDecoder().decode(HubSession.self, from: body),
                session.id.caseInsensitiveCompare(sessionID) == .orderedSame
            else { return .retry }
            return .committed(session)
        }
        let error = try? JSONDecoder().decode(HubErrorBody.self, from: body)
        switch (status, error?.error) {
        case (409, "missing_files"): return .missing(error?.missing ?? [])
        case (400, let code?): return .rejected(error?.message ?? code)
        default: return .retry
        }
    }

    public static func health(status: Int, body: Data) -> Health {
        guard status == 200 else { return .failed(status: status) }
        guard let health = try? JSONDecoder().decode(HubHealth.self, from: body),
            health.ok, health.service == "quill-hub"
        else { return .notAHub }
        return .ok
    }
}
