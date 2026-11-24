import Foundation
import QuillKit

/// The hub requests made while the app is on screen: the session list,
/// transcripts, and the connection check. Uploads go through `HubSender`
/// instead, which keeps running in the background.
enum HubClient {
    enum Failure: Error {
        case status(Int)
    }

    enum Check: Equatable {
        case ok
        case notAHub
        case httpError(Int)
        case unreachable
    }

    /// Short timeouts: when Tailscale is off the hub's name doesn't resolve,
    /// and the list should fall back to its cache rather than spin.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func sessions(_ api: HubAPI, after revision: Int) async throws -> HubSessionList {
        try await decode(HubSessionList.self, api.sessions(after: revision))
    }

    static func transcript(_ api: HubAPI, id: String) async throws -> Transcript {
        try await decode(Transcript.self, api.transcript(id: id))
    }

    static func check(_ api: HubAPI) async -> Check {
        guard let (data, response) = try? await session.data(for: api.health()),
            let http = response as? HTTPURLResponse
        else { return .unreachable }
        switch HubResponse.health(status: http.statusCode, body: data) {
        case .ok: return .ok
        case .notAHub: return .notAHub
        case .failed(let status): return .httpError(status)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        return try JSONDecoder().decode(type, from: data)
    }
}
