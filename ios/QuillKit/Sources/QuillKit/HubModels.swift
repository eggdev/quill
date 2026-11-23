import Foundation

// The hub API's JSON objects (docs/hub-api.md). Decoding ignores fields it
// doesn't know, since the contract lets new ones appear in any version.

/// The device a session was recorded on.
public struct HubDevice: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// `mac` or `iphone`; kept as text so a new kind still decodes.
    public var kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public static let iphoneKind = "iphone"
}

/// One session as the hub lists it.
public struct HubSession: Codable, Hashable, Sendable {
    public enum Status: Hashable, Sendable, Codable {
        case queued, transcribing, transcribed, failed
        /// A status added after version 1.
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "queued": self = .queued
            case "transcribing": self = .transcribing
            case "transcribed": self = .transcribed
            case "failed": self = .failed
            default: self = .other(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(raw)
        }

        public var raw: String {
            switch self {
            case .queued: "queued"
            case .transcribing: "transcribing"
            case .transcribed: "transcribed"
            case .failed: "failed"
            case .other(let s): s
            }
        }
    }

    public var id: String
    public var name: String
    public var device: HubDevice
    public var title: String?
    /// ISO 8601, as sent; `startedAt` parses it.
    public var started: String
    public var durationSeconds: Int
    public var status: Status
    public var error: String?
    public var engine: String?
    public var model: String?
    public var preview: String
    public var revision: Int
    public var updated: String?

    enum CodingKeys: String, CodingKey {
        case id, name, device, title, started, status, error, engine, model, preview, revision, updated
        case durationSeconds = "duration_seconds"
    }

    public init(
        id: String, name: String, device: HubDevice, title: String? = nil, started: String,
        durationSeconds: Int, status: Status, error: String? = nil, engine: String? = nil, model: String? = nil,
        preview: String = "", revision: Int, updated: String? = nil
    ) {
        self.id = id
        self.name = name
        self.device = device
        self.title = title
        self.started = started
        self.durationSeconds = durationSeconds
        self.status = status
        self.error = error
        self.engine = engine
        self.model = model
        self.preview = preview
        self.revision = revision
        self.updated = updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        device = try c.decode(HubDevice.self, forKey: .device)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        started = try c.decode(String.self, forKey: .started)
        // Whole seconds in the contract; accept a fraction rather than drop
        // the session over it.
        if let whole = try? c.decodeIfPresent(Int.self, forKey: .durationSeconds) {
            durationSeconds = whole
        } else {
            durationSeconds = Int(try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0)
        }
        status = try c.decode(Status.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        revision = try c.decode(Int.self, forKey: .revision)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
    }

    public var startedAt: Date? { HubTime.parse(started) }
}

/// `GET /v1/sessions`: sessions in ascending revision order, the hub's
/// current counter, and the id of the hub's catalog.
public struct HubSessionList: Codable, Equatable, Sendable {
    public var sessions: [HubSession]
    public var revision: Int
    /// Changes when the hub rebuilds its catalog. Nil from a hub that
    /// doesn't send it, which means unknown, not changed.
    public var catalog: String?

    public init(sessions: [HubSession], revision: Int, catalog: String? = nil) {
        self.sessions = sessions
        self.revision = revision
        self.catalog = catalog
    }
}

/// Every error response. `missing` comes only with `missing_files`.
public struct HubErrorBody: Decodable, Equatable, Sendable {
    public var error: String
    public var message: String?
    public var missing: [String]?
}

/// `PUT /v1/uploads/{id}/{file}`'s answer: what the hub stored.
public struct HubUploadReceipt: Decodable, Equatable, Sendable {
    public var file: String
    public var bytes: Int64
}

/// `GET /health`.
public struct HubHealth: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var service: String?
    public var api: Int?
    public var catalog: String?
}

public enum HubTime {
    /// The hub sends whole seconds; a fraction is accepted too.
    public static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
