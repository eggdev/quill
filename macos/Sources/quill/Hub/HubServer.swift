import Foundation
import Hummingbird
import Logging

/// The hub API (docs/hub-api.md) over HTTP/1.1 on 127.0.0.1. `tailscale
/// serve` publishes it to the tailnet with HTTPS; the hub itself never
/// listens on another interface.
enum HubServer {
    static let apiVersion = 1

    /// `onRunning` gets the bound port, which tests ask for with port 0.
    static func application(
        hub: HubService, port: Int, onRunning: @escaping @Sendable (Int) async -> Void = { _ in }
    ) -> some ApplicationProtocol {
        var logger = Logger(label: "quill.hub")
        logger.logLevel = .warning
        return Application(
            router: router(hub),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "quill-hub"),
            onServerRunning: { await onRunning($0.localAddress?.port ?? port) },
            logger: logger
        )
    }

    static func router(_ hub: HubService) -> Router<BasicRequestContext> {
        let router = Router()
        router.get("health") { _, _ in
            json(["ok": true, "service": "quill-hub", "api": apiVersion, "catalog": hub.catalog.id] as [String: Any])
        }
        router.put("v1/uploads/:id/:file") { request, context in
            await respond { try await HubUploads.receive(request, context: context, hub: hub) }
        }
        router.post("v1/sessions") { request, _ in
            await respond {
                var request = request
                let body = try await request.collectBody(upTo: 16 * 1024 * 1024)
                switch try await hub.commit(CommitRequest.decode(Data(body.readableBytesView))) {
                case .created(let session): return try json(session, status: .created)
                case .existing(let session): return try json(session)
                }
            }
        }
        router.get("v1/sessions") { request, _ in
            await respond {
                let query = request.uri.queryParameters
                guard let after = Int64(query.get("after") ?? "0"), let limit = Int(query.get("limit") ?? "500"),
                    after >= 0, limit > 0
                else { throw HubError.badRequest("after and limit must be whole numbers") }
                // The current counter, not the page's last revision: a client
                // whose cursor is above it knows the catalog was rebuilt.
                let page = try hub.catalog.page(after: after, limit: min(limit, 500))
                return try json(SessionList(sessions: page.sessions, revision: page.revision, catalog: hub.catalog.id))
            }
        }
        router.get("v1/sessions/:id") { _, context in
            await respond { try json(try session(context, hub)) }
        }
        router.get("v1/sessions/:id/meta") { _, context in
            await respond {
                let dir = hub.folder(of: try session(context, hub))
                return try file(dir.appendingPathComponent("meta.json"), type: "application/json")
            }
        }
        router.get("v1/sessions/:id/transcript") { _, context in
            await respond { try transcriptFile("transcript.json", type: "application/json", context, hub) }
        }
        router.get("v1/sessions/:id/transcript.md") { _, context in
            await respond { try transcriptFile("transcript.md", type: "text/markdown; charset=utf-8", context, hub) }
        }
        router.get("v1/sessions/:id/audio/:file") { request, context in
            await respond { try await HubDownloads.audio(request, context: context, hub: hub) }
        }
        return router
    }

    // MARK: -

    struct SessionList: Encodable {
        var sessions: [HubSession]
        var revision: Int64
        var catalog: String
    }

    static func session(_ context: BasicRequestContext, _ hub: HubService) throws -> HubSession {
        guard let id = context.parameters.get("id").flatMap(HubNames.sessionID), let session = try hub.catalog.session(id: id)
        else { throw HubError.notFound }
        return session
    }

    private static func transcriptFile(
        _ name: String, type: String, _ context: BasicRequestContext, _ hub: HubService
    ) throws -> Response {
        let session = try session(context, hub)
        let url = hub.folder(of: session).appendingPathComponent(name)
        guard session.status == .transcribed, FileManager.default.fileExists(atPath: url.path) else {
            throw HubError.notReady
        }
        return try file(url, type: type)
    }

    /// Small files only (meta and transcripts); audio streams through
    /// `HubDownloads`.
    private static func file(_ url: URL, type: String) throws -> Response {
        guard let data = try? Data(contentsOf: url) else { throw HubError.notFound }
        return Response(status: .ok, headers: [.contentType: type], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// Every handler answers through here, so any failure is the contract's
    /// error object rather than an empty 500.
    static func respond(_ body: () async throws -> Response) async -> Response {
        do {
            return try await body()
        } catch let error as HubError {
            return errorResponse(error)
        } catch {
            return errorResponse(.internal("\(error)"))
        }
    }

    static func errorResponse(_ error: HubError) -> Response {
        var object: [String: Any] = ["error": error.code, "message": error.message]
        if let missing = error.missing { object["missing"] = missing }
        return json(object, status: .init(code: error.status))
    }

    static func json(_ object: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Response(
            status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Response(
            status: status, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: try encoder.encode(value))))
    }
}
