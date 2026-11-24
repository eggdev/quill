import Foundation
import Hummingbird

/// `PUT /v1/uploads/{id}/{file}`. Recordings run to hundreds of megabytes, so
/// the body streams to a hidden temporary file in the session's staging
/// folder and takes its real name only once it is complete. A retry replaces
/// the earlier upload.
enum HubUploads {
    static func receive(_ request: Request, context: BasicRequestContext, hub: HubService) async throws -> Response {
        guard let id = context.parameters.get("id").flatMap(HubNames.sessionID) else {
            throw HubError.badRequest("the session id is not a UUID")
        }
        guard let name = context.parameters.get("file"), HubNames.isValidFile(name) else {
            throw HubError.badFileName(context.parameters.get("file") ?? "")
        }
        guard try hub.catalog.session(id: id) == nil else { throw HubError.alreadyCommitted }

        let fm = FileManager.default
        let dir = hub.staging(id: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".upload-\(UUID().uuidString).part")
        let dest = dir.appendingPathComponent(name)
        do {
            try await FileIO().writeFile(contents: request.body, path: temp.path, context: context)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        // rename(2) replaces an earlier upload of the same file in one step.
        guard rename(temp.path, dest.path) == 0 else {
            try? fm.removeItem(at: temp)
            // A commit moved the staging folder away while this body arrived.
            if try hub.catalog.session(id: id) != nil { throw HubError.alreadyCommitted }
            throw HubError.internal("couldn't store \(name): \(String(cString: strerror(errno)))")
        }
        // A commit ran while this body arrived, and the folder this upload
        // wrote into was made again after the commit moved it away.
        if try hub.catalog.session(id: id) != nil {
            try? fm.removeItem(at: dir)
            throw HubError.alreadyCommitted
        }
        return HubServer.json(["file": name, "bytes": HubService.size(of: dest) ?? 0] as [String: Any])
    }
}
