import Foundation

/// How far a recording on this iPhone has got on its way to the hub, kept in
/// `.hub.json` in its session folder. The session `id` is made once, before
/// the first upload, and every retry reuses it, so repeating a step is safe.
public struct HubDelivery: Codable, Equatable, Sendable {
    public static let fileName = ".hub.json"
    /// Left by the iCloud outbox this replaced: the folder was already sent.
    public static let legacySentMarker = ".sent"

    public var id: String
    /// Files the hub stored, with the size it stored. A file counts only
    /// while its size still matches.
    public var uploaded: [String: Int64]
    /// The commit returned 200 or 201: the hub owns the recording.
    public var committed: Bool
    /// The hub refused the recording (a 400); retrying can't help.
    public var rejected: String?
    /// `missing_files` answers since the last reconciliation, so a hub that
    /// keeps losing files can't keep the phone uploading forever.
    public var missingRounds: Int

    public static let maxMissingRounds = 3

    /// Why a folder whose meta.json names a file that isn't on disk is
    /// refused: the hub takes only complete recordings in version 1.
    public static let missingFileReason =
        "A part of this recording is missing on this iPhone, and the hub accepts only complete recordings."

    public init(id: String = UUID().uuidString) {
        self.id = id
        uploaded = [:]
        committed = false
        rejected = nil
        missingRounds = 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        uploaded = try c.decodeIfPresent([String: Int64].self, forKey: .uploaded) ?? [:]
        committed = try c.decodeIfPresent(Bool.self, forKey: .committed) ?? false
        rejected = try c.decodeIfPresent(String.self, forKey: .rejected)
        missingRounds = try c.decodeIfPresent(Int.self, forKey: .missingRounds) ?? 0
    }

    public var isFinished: Bool { committed || rejected != nil }

    /// The steps still to start for `folder`, given the tasks already
    /// running: upload each file the hub doesn't have, then commit once
    /// every upload is done.
    public func tasks(folder: String, files: [HubCommit.File], running: Set<HubTask>) -> [HubTask] {
        guard !isFinished else { return [] }
        let pending = files.filter { uploaded[$0.name] != $0.bytes }
        if pending.isEmpty {
            return running.contains(.commit(folder: folder)) ? [] : [.commit(folder: folder)]
        }
        return pending.map { HubTask.upload(folder: folder, file: $0.name) }.filter { !running.contains($0) }
    }

    public static func read(in dir: URL) -> HubDelivery? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(HubDelivery.self, from: data)
    }

    public func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func isLegacySent(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(legacySentMarker).path)
    }

    /// Every segment file `manifest` names, with its size on disk, as the
    /// commit lists them. Nil when one is missing: the folder is damaged
    /// and committing it would only be refused.
    public static func files(of manifest: SessionManifest, in dir: URL) -> [HubCommit.File]? {
        var seen = Set<String>()
        var files: [HubCommit.File] = []
        for segment in manifest.tracks.flatMap(\.segments) where seen.insert(segment.file).inserted {
            let path = dir.appendingPathComponent(segment.file).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
            else { return nil }
            files.append(HubCommit.File(name: segment.file, bytes: size.int64Value))
        }
        return files
    }
}

/// One background request, named so it can be matched up again after the
/// app is relaunched: the name travels as the task's `taskDescription`.
public enum HubTask: Hashable, Sendable {
    case upload(folder: String, file: String)
    case commit(folder: String)

    public var folder: String {
        switch self {
        case .upload(let folder, _), .commit(let folder): folder
        }
    }

    /// "upload/<folder>/<file>" or "commit/<folder>". Folder and file names
    /// never contain "/".
    public var description: String {
        switch self {
        case .upload(let folder, let file): "upload/\(folder)/\(file)"
        case .commit(let folder): "commit/\(folder)"
        }
    }

    public init?(description: String) {
        let parts = description.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("upload", 3): self = .upload(folder: parts[1], file: parts[2])
        case ("commit", 2): self = .commit(folder: parts[1])
        default: return nil
        }
    }
}
