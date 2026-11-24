import Foundation

/// The body of `POST /v1/sessions` (docs/hub-api.md §3).
struct CommitRequest: Sendable {
    struct File: Codable, Equatable, Sendable {
        var name: String
        var bytes: Int64
    }

    var id: String
    var name: String
    var device: HubDevice
    var files: [File]
    /// The session's meta.json as the client sent it, re-serialized. Kept as
    /// JSON so fields this Mac does not know survive.
    var meta: Data

    private struct Fields: Decodable {
        var id: String
        var name: String
        var device: HubDevice
        var files: [File]
    }

    static func decode(_ data: Data) throws -> CommitRequest {
        guard
            let fields = try? JSONDecoder().decode(Fields.self, from: data),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let meta = object["meta"] as? [String: Any],
            let metaData = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        else { throw HubError.badRequest("the body is not a commit request") }
        return CommitRequest(id: fields.id, name: fields.name, device: fields.device, files: fields.files, meta: metaData)
    }

    /// The request body a client sends: `meta` is embedded as an object.
    static func body(id: String, name: String, device: HubDevice, files: [File], meta: Data) throws -> Data {
        let encoder = JSONEncoder()
        let deviceObject = try JSONSerialization.jsonObject(with: encoder.encode(device))
        let filesObject = try JSONSerialization.jsonObject(with: encoder.encode(files))
        let metaObject = try JSONSerialization.jsonObject(with: meta)
        return try JSONSerialization.data(withJSONObject: [
            "id": id, "name": name, "device": deviceObject, "files": filesObject, "meta": metaObject,
        ])
    }
}
