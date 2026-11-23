import Foundation

/// The hub's side of every session: where uploads are staged, how a commit
/// becomes a session folder, and how the catalog follows the folders and the
/// transcription queue. The HTTP layer (`HubServer`) only translates.
///
/// Folders under `root` are the source of truth. Each holds a `.hub.json`
/// sidecar, so `reconcile()` can rebuild the catalog from the folders alone.
actor HubService {
    nonisolated let root: URL
    nonisolated let catalog: HubCatalog
    /// This Mac: the owner of recordings made on the hub itself.
    nonisolated let device: HubDevice
    private let enqueue: @Sendable (URL) async -> Void

    /// `enqueue` hands a committed folder to transcription.
    init(root: URL, catalog: HubCatalog, device: HubDevice, enqueue: @escaping @Sendable (URL) async -> Void) {
        self.root = root
        self.catalog = catalog
        self.device = device
        self.enqueue = enqueue
    }

    /// Where uploads wait for their commit. Hidden, so the transcription
    /// queue's rescan and `reconcile` pass over it.
    nonisolated var incoming: URL { root.appendingPathComponent(".incoming", isDirectory: true) }

    nonisolated func staging(id: String) -> URL { incoming.appendingPathComponent(id, isDirectory: true) }

    nonisolated func folder(of session: HubSession) -> URL { root.appendingPathComponent(session.name, isDirectory: true) }

    /// A client's upload: the hub does not notify about it, the client does.
    nonisolated func isUploaded(_ dir: URL) -> Bool {
        guard let sidecar = HubSidecar.read(in: dir) else { return false }
        return sidecar.device.id != device.id
    }

    // MARK: - Folders → catalog

    /// Index every session folder (one with meta.json) in the root. Returns
    /// how many there are.
    @discardableResult
    func reconcile() -> Int {
        let fm = FileManager.default
        let entries =
            (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var count = 0
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) {
            do {
                try index(dir)
                count += 1
            } catch {
                FileHandle.standardError.write(Data("hub: couldn't index \(dir.lastPathComponent): \(error)\n".utf8))
            }
        }
        return count
    }

    /// Bring one session folder into the catalog: give it a sidecar if it has
    /// none, then record what is on disk. A recording made on the hub Mac
    /// enters the catalog this way when it stops.
    @discardableResult
    func index(_ dir: URL) throws -> HubSession {
        let sidecar = try HubSidecar.read(in: dir) ?? newSidecar(for: dir)
        return try catalog.save(Self.describe(dir, sidecar: sidecar))
    }

    /// Folders from before the hub, and recordings made on the hub Mac,
    /// belong to this Mac — except the iPhone's, which the old iCloud
    /// hand-off named `…-iphone` (`…-iphone-2` after a collision).
    private func newSidecar(for dir: URL) throws -> HubSidecar {
        let name = dir.lastPathComponent
        let owner = HubNames.isIPhoneFolder(name) ? HubDevice.earlyIPhone : device
        let sidecar = HubSidecar(id: UUID().uuidString, device: owner, source_name: name)
        try sidecar.write(to: dir)
        return sidecar
    }

    /// The catalog row for a folder, from its files: meta.json for the title,
    /// start, and length; transcript.json, when present, for the result.
    static func describe(_ dir: URL, sidecar: HubSidecar) -> HubCatalog.Entry {
        let meta =
            (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let transcript = (try? Data(contentsOf: dir.appendingPathComponent("transcript.json")))
            .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        let created = (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date
        let session = HubSession(
            id: sidecar.id,
            name: dir.lastPathComponent,
            device: sidecar.device,
            title: (meta["meeting"] as? [String: Any])?["title"] as? String,
            started: meta["started"] as? String ?? ISO8601DateFormatter().string(from: created ?? Date()),
            duration_seconds: meta["duration_seconds"] as? Int ?? 0,
            status: transcript == nil ? .queued : .transcribed,
            error: nil,
            engine: transcript?.engine,
            model: transcript?.model,
            preview: transcript.map(preview) ?? "",
            revision: 0,
            updated: ""
        )
        return HubCatalog.Entry(session: session, sourceName: sidecar.source_name)
    }

    static func preview(_ transcript: Transcript) -> String {
        String(transcript.segments.map(\.text).joined(separator: " ").prefix(HubSession.previewLength))
    }

    // MARK: - Commit

    enum CommitResult: Equatable, Sendable {
        case created(HubSession)
        case existing(HubSession)
    }

    /// `POST /v1/sessions`: check the staged files against the request, make
    /// the staging folder complete (meta.json and sidecar), move it into the
    /// root in one rename, then record and queue it. A folder in the root is
    /// therefore always complete: after a crash before the catalog insert,
    /// `reconcile` (or this method, on the client's retry) finds it with the
    /// right id and device.
    func commit(_ request: CommitRequest) async throws -> CommitResult {
        guard let id = HubNames.sessionID(request.id) else { throw HubError.badRequest("id is not a UUID") }
        if let existing = try catalog.session(id: id) { return .existing(existing) }
        if !FileManager.default.fileExists(atPath: staging(id: id).path), let stored = folder(withID: id) {
            return .existing(try index(stored))
        }
        guard HubNames.isValidFolder(request.name) else { throw HubError.badRequest("name is not a plain folder name") }
        guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: request.meta) else {
            throw HubError.badRequest("meta is not a session meta.json")
        }
        guard meta.schema_version >= 2 else { throw HubError.badRequest("meta.schema_version is below 2") }

        let segments = meta.tracks.flatMap { $0.segments.map(\.file) }
        if let bad = segments.first(where: { !HubNames.isValidFile($0) }) { throw HubError.badFileName(bad) }
        let sizes = Dictionary(request.files.map { ($0.name, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        if let uncovered = segments.first(where: { sizes[$0] == nil }) {
            throw HubError.badRequest("files does not list \(uncovered)")
        }

        let staged = staging(id: id)
        let missing = segments.filter { Self.size(of: staged.appendingPathComponent($0)) != sizes[$0] }
        guard missing.isEmpty else { throw HubError.missingFiles(missing) }

        let dest = try uniqueFolder(HubNames.hubFolder(for: request.name, device: request.device))
        let fm = FileManager.default
        do {
            // Temporary files of unfinished uploads.
            for leftover in (try? fm.contentsOfDirectory(atPath: staged.path)) ?? [] where leftover.hasPrefix(".") {
                try? fm.removeItem(at: staged.appendingPathComponent(leftover))
            }
            try request.meta.write(to: staged.appendingPathComponent("meta.json"), options: .atomic)
            try HubSidecar(id: id, device: request.device, source_name: request.name).write(to: staged)
            try fm.moveItem(at: staged, to: dest)
        } catch {
            throw HubError.internal("couldn't store the session: \(error)")
        }
        let session = try index(dest)
        await enqueue(dest)
        return .created(session)
    }

    /// The session folder whose sidecar has `id`, when the catalog lost it:
    /// a commit that moved the folder but crashed before its catalog row.
    private func folder(withID id: String) -> URL? {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.first { HubSidecar.read(in: $0)?.id == id }
    }

    /// Remove uploads that were never committed: staging folders untouched
    /// for `age`. Run at startup, before serving.
    @discardableResult
    func pruneStaging(olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let folders =
            (try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed: [String] = []
        for dir in folders {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = ([dir] + files).compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max()
            guard let newest, now.timeIntervalSince(newest) > age else { continue }
            if (try? fm.removeItem(at: dir)) != nil { removed.append(dir.lastPathComponent) }
        }
        return removed
    }

    private func uniqueFolder(_ base: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let taken = try catalog.names()
        var name = base
        var n = 2
        while taken.contains(name) || FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"
            n += 1
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    static func size(of file: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Transcription → catalog

    /// Follow the transcription queue. A folder the catalog does not know yet
    /// (a recording that finished before the hub saw it) is indexed first.
    func handle(_ event: TranscriptionCoordinator.Event) {
        do {
            switch event {
            case .started(let dir):
                try ensureIndexed(dir)
                try catalog.update(named: dir.lastPathComponent) {
                    $0.status = .transcribing
                    $0.error = nil
                }
            case .finished(let dir):
                try ensureIndexed(dir)
                let transcript = (try? Data(contentsOf: dir.appendingPathComponent("transcript.json")))
                    .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
                try catalog.update(named: dir.lastPathComponent) {
                    $0.status = .transcribed
                    $0.error = nil
                    $0.engine = transcript?.engine
                    $0.model = transcript?.model
                    $0.preview = transcript.map(Self.preview) ?? ""
                }
            case .failed(let dir, let reason):
                try ensureIndexed(dir)
                try catalog.update(named: dir.lastPathComponent) {
                    $0.status = .failed
                    $0.error = reason
                }
            }
        } catch {
            FileHandle.standardError.write(Data("hub: couldn't update the catalog: \(error)\n".utf8))
        }
    }

    private func ensureIndexed(_ dir: URL) throws {
        guard try catalog.entry(named: dir.lastPathComponent) == nil else { return }
        try index(dir)
    }
}
