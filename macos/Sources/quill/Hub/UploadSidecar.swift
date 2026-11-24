import Foundation

/// `.hub.json` in a session folder on a client: the session id the hub knows
/// it by (made once, before the first upload, and reused on every retry) and
/// how far sending it got.
struct UploadSidecar: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Not yet accepted by the hub: upload and commit.
        case sending
        /// The hub owns it; wait for its transcript.
        case committed
        /// The hub could not transcribe it. The user was told once; the hub
        /// tries again at its next start, so look again now and then.
        case hubFailed = "hub_failed"
        /// The hub's transcript is in the folder.
        case done
        /// The hub refused it. Not retried.
        case failed
    }

    var id: String
    var state: State
    var error: String? = nil
    /// The folder already had a transcript made on this Mac before it was
    /// sent: the hub's replaces it quietly, with no notification or hook.
    var backfill: Bool? = nil

    var isBackfill: Bool { backfill ?? false }

    static func read(in dir: URL) -> UploadSidecar? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(HubSidecar.fileName)) else { return nil }
        return try? JSONDecoder().decode(UploadSidecar.self, from: data)
    }

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(HubSidecar.fileName), options: .atomic)
    }
}
