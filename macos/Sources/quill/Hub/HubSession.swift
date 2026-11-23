import Foundation

/// A device in a hub setup. Property names are the JSON schema
/// (docs/hub-api.md §2).
struct HubDevice: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mac
        case iphone
    }

    var id: String
    var name: String
    var kind: Kind

    /// Owner of iPhone recordings that reached the hub before it existed,
    /// through the old iCloud hand-off. Their real device id was never kept.
    static let earlyIPhone = HubDevice(id: "00000000-0000-0000-0000-000000000000", name: "iPhone", kind: .iphone)
}

/// The session object of the hub API. Property names are the JSON schema.
struct HubSession: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued
        case transcribing
        case transcribed
        case failed
    }

    var id: String
    /// The session's folder name on the hub.
    var name: String
    var device: HubDevice
    var title: String?
    var started: String
    var duration_seconds: Int
    var status: Status
    var error: String?
    var engine: String?
    var model: String?
    var preview: String
    var revision: Int64
    var updated: String

    static let previewLength = 200

    /// The contract shows absent values as `null`, which the synthesized
    /// encoder would leave out.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(device, forKey: .device)
        try c.encode(title, forKey: .title)
        try c.encode(started, forKey: .started)
        try c.encode(duration_seconds, forKey: .duration_seconds)
        try c.encode(status, forKey: .status)
        try c.encode(error, forKey: .error)
        try c.encode(engine, forKey: .engine)
        try c.encode(model, forKey: .model)
        try c.encode(preview, forKey: .preview)
        try c.encode(revision, forKey: .revision)
        try c.encode(updated, forKey: .updated)
    }
}

/// `.hub.json` in each session folder on the hub: who sent the recording and
/// what the client called it. With meta.json and transcript.json it is enough
/// to rebuild the catalog from the folders alone.
struct HubSidecar: Codable, Equatable, Sendable {
    static let fileName = ".hub.json"

    var id: String
    var device: HubDevice
    var source_name: String

    static func read(in dir: URL) -> HubSidecar? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(HubSidecar.self, from: data)
    }

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
