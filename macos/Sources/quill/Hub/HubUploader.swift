import Foundation

/// A client Mac's replacement for the transcription queue: every finished
/// recording goes to the hub, and its transcript comes back from there. This
/// Mac never transcribes.
///
/// The filesystem is the queue, as for `TranscriptionCoordinator`: a session
/// folder with meta.json is pending until its `.hub.json` (`UploadSidecar`)
/// says the hub's transcript arrived or the hub refused it. A folder that
/// already had a local transcript when this Mac became a client is a
/// backfill: it goes too, so the hub keeps every recording, but only one at a
/// time and only when no other recording waits, so it never delays a new
/// one. iPhone folders from the old iCloud hand-off are skipped; the iPhone
/// sends those itself.
///
/// Each pass walks the pending folders oldest first, new recordings before
/// backfills. A pass that cannot reach the hub stops, and the next one waits
/// longer each time, up to `retryCap`.
actor HubUploader {
    enum Status: Equatable, Sendable {
        case idle
        case uploading(session: String, queued: Int)
        /// The hub can't be reached; `pending` recordings wait for it.
        case waitingForHub(pending: Int)
        case transcribingOnHub(sessions: Int)
        case failed(session: String)
    }

    struct Timing: Sendable {
        var poll: Duration = .seconds(15)
        var retryStart: Duration = .seconds(15)
        var retryCap: Duration = .seconds(300)
        /// A rescan with nothing pending, in case a folder appeared without
        /// an `enqueue`.
        var idle: Duration = .seconds(600)
        /// How often a session that failed on the hub is checked again.
        var failedRecheck: Duration = .seconds(600)
    }

    private let root: URL
    private let client: HubClient
    private let device: HubDevice
    private let timing: Timing
    private let notify: @Sendable (_ title: String, _ body: String) -> Void
    private let delivered: @Sendable (URL) -> Void
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var wakeRequested = false
    private var retryDelay: Duration?
    private var lastFailedCheck: [String: ContinuousClock.Instant] = [:]

    /// `delivered` runs once a transcript is in its folder: the on_stop hook.
    init(
        root: URL, client: HubClient, device: HubDevice, timing: Timing = Timing(),
        notify: @escaping @Sendable (String, String) -> Void = { notifyUser(title: $0, body: $1) },
        delivered: @escaping @Sendable (URL) -> Void = { OnStopHook.run(for: $0) }
    ) {
        self.root = root
        self.client = client
        self.device = device
        self.timing = timing
        self.notify = notify
        self.delivered = delivered
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Start working through every pending folder, including ones left from
    /// an earlier run.
    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    func stop() {
        loop?.cancel()
        sleeper?.cancel()
        loop = nil
    }

    /// A recording just finished. The folder is already on disk, which is
    /// the queue, so this only cuts the current wait short.
    func enqueue(_ dir: URL) {
        wakeRequested = true
        sleeper?.cancel()
    }

    // MARK: -

    enum Outcome: Equatable {
        case idle
        case waiting
        case unreachable
    }

    private func run() async {
        while !Task.isCancelled {
            let delay: Duration
            switch await pass() {
            case .unreachable:
                let next = retryDelay.map { min($0 * 2, timing.retryCap) } ?? timing.retryStart
                retryDelay = next
                delay = next
            case .waiting:
                retryDelay = nil
                delay = timing.poll
            case .idle:
                retryDelay = nil
                delay = timing.idle
            }
            if wakeRequested {
                wakeRequested = false
                continue
            }
            let sleep = Task { _ = try? await Task.sleep(for: delay) }
            sleeper = sleep
            await sleep.value
            sleeper = nil
            wakeRequested = false
        }
    }

    /// One walk over the pending folders. Internal so tests can step it.
    func pass() async -> Outcome {
        let pending = pendingFolders()
        let isBackfill = { (dir: URL) in UploadSidecar.read(in: dir)?.isBackfill ?? Self.hasTranscript(dir) }
        let recent = pending.filter { !isBackfill($0) }
        let backfills = pending.filter(isBackfill)
        // Read from the sidecars when needed: earlier steps of this pass may
        // have changed them.
        let blocksBackfill = {
            recent.contains {
                let state = UploadSidecar.read(in: $0)?.state
                return state == nil || state == .sending || state == .committed
            } || backfills.contains { UploadSidecar.read(in: $0)?.state == .committed }
        }
        var waiting = 0
        var failure: String?
        for (i, dir) in (recent + backfills).enumerated() {
            do {
                var sidecar = UploadSidecar.read(in: dir)
                if sidecar == nil || sidecar?.state == .sending {
                    if isBackfill(dir) {
                        // A new recording, or the backfill already on the hub,
                        // goes first.
                        guard !wakeRequested, !blocksBackfill() else { continue }
                    }
                    var fresh = try sidecar ?? newSidecar(for: dir)
                    publish(.uploading(session: dir.lastPathComponent, queued: pending.count - i - 1))
                    try await send(dir, id: fresh.id)
                    fresh.state = .committed
                    try fresh.write(to: dir)
                    sidecar = fresh
                }
                guard var sidecar else { continue }
                if sidecar.state == .hubFailed, let last = lastFailedCheck[sidecar.id],
                    ContinuousClock.now - last < timing.failedRecheck
                {
                    continue
                }
                let remote = try await client.session(id: sidecar.id)
                switch remote?.status {
                case nil:
                    // The hub lost it (its folder is gone); this Mac still has
                    // the audio, so send it again.
                    sidecar.state = .sending
                    try sidecar.write(to: dir)
                    waiting += 1
                case .transcribed?:
                    try await deliver(dir, &sidecar)
                case .failed?:
                    lastFailedCheck[sidecar.id] = .now
                    if sidecar.state != .hubFailed {
                        hubFailed(dir, &sidecar, remote?.error ?? "unknown error")
                        failure = dir.lastPathComponent
                    }
                case .queued?, .transcribing?:
                    if sidecar.state == .hubFailed {
                        // The hub is trying again.
                        sidecar.state = .committed
                        try sidecar.write(to: dir)
                    }
                    waiting += 1
                }
            } catch HubClient.Failure.unreachable(let why) {
                // Once per outage, not once per retry.
                if retryDelay == nil {
                    FileHandle.standardError.write(Data("hub: \(client.base.absoluteString) unreachable: \(why)\n".utf8))
                }
                publish(.waitingForHub(pending: pending.count))
                return .unreachable
            } catch {
                var sidecar = UploadSidecar.read(in: dir) ?? UploadSidecar(id: UUID().uuidString, state: .sending)
                refused(dir, &sidecar, "couldn't send to the hub: \(error)")
                failure = dir.lastPathComponent
            }
        }
        if waiting > 0 {
            publish(.transcribingOnHub(sessions: waiting))
        } else {
            publish(failure.map { .failed(session: $0) } ?? .idle)
        }
        return waiting > 0 ? .waiting : .idle
    }

    /// Session folders whose transcript has not come back from the hub and
    /// that the hub did not refuse, oldest first.
    private func pendingFolders() -> [URL] {
        let fm = FileManager.default
        let entries =
            (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return
            entries
            .filter { dir in
                guard fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path),
                    !HubNames.isIPhoneFolder(dir.lastPathComponent)
                else { return false }
                let state = UploadSidecar.read(in: dir)?.state
                return state != .done && state != .failed
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func hasTranscript(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
    }

    /// The folder's sidecar, made (with a new session id) before its first
    /// upload.
    private func newSidecar(for dir: URL) throws -> UploadSidecar {
        let sidecar = UploadSidecar(id: UUID().uuidString, state: .sending, backfill: Self.hasTranscript(dir) ? true : nil)
        try sidecar.write(to: dir)
        return sidecar
    }

    /// Upload every segment, then commit. The hub answers a commit with the
    /// files it lacks; send those again, a few times at most.
    private func send(_ dir: URL, id: String) async throws {
        let metaData = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let (inputs, _) = try SessionMeta.readInputs(from: dir)
        var files: [CommitRequest.File] = []
        for name in inputs.map(\.file) {
            guard let bytes = HubService.size(of: dir.appendingPathComponent(name)) else {
                throw HubClient.Failure.rejected(code: "missing_segment", message: "\(name) is not in the folder")
            }
            files.append(.init(name: name, bytes: bytes))
        }
        let body = try CommitRequest.body(id: id, name: dir.lastPathComponent, device: device, files: files, meta: metaData)

        var toUpload = files.map(\.name)
        for _ in 0..<3 {
            do {
                for name in toUpload {
                    try await client.upload(dir.appendingPathComponent(name), id: id)
                }
            } catch HubClient.Failure.alreadyCommitted {
                // A commit this Mac never saw the answer to; the commit
                // below returns the session.
            }
            do {
                _ = try await client.commit(body)
                return
            } catch HubClient.Failure.missingFiles(let names) {
                toUpload = names
            }
        }
        throw HubClient.Failure.rejected(code: "missing_files", message: "the hub kept asking for \(toUpload)")
    }

    /// Fetch both transcript files, replacing any local ones. transcript.json
    /// goes last, then the sidecar is marked done.
    private func deliver(_ dir: URL, _ sidecar: inout UploadSidecar) async throws {
        let markdown = try await client.transcript(id: sidecar.id, file: "transcript.md")
        let json = try await client.transcript(id: sidecar.id, file: "transcript")
        try markdown.write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try json.write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        sidecar.state = .done
        sidecar.error = nil
        try sidecar.write(to: dir)
        SessionLog.append(dir, "transcript received from the hub")
        lastFailedCheck[sidecar.id] = nil
        guard !sidecar.isBackfill else { return }
        notify("quill — transcript ready", SessionMeta.meeting(in: dir)?.title ?? dir.lastPathComponent)
        delivered(dir)
    }

    /// The hub could not transcribe it: tell the user once, keep watching.
    private func hubFailed(_ dir: URL, _ sidecar: inout UploadSidecar, _ reason: String) {
        SessionLog.append(dir, "hub transcription failed: \(reason)")
        sidecar.state = .hubFailed
        sidecar.error = TranscriptionCoordinator.oneLine(reason)
        try? sidecar.write(to: dir)
        if !sidecar.isBackfill {
            notify("quill — transcription failed", "\(dir.lastPathComponent) — see transcribe.log")
        }
    }

    /// The hub refused it (a 4xx), or it can't be sent at all. Permanent.
    private func refused(_ dir: URL, _ sidecar: inout UploadSidecar, _ reason: String) {
        SessionLog.append(dir, reason)
        sidecar.state = .failed
        sidecar.error = TranscriptionCoordinator.oneLine(reason)
        try? sidecar.write(to: dir)
        if !sidecar.isBackfill {
            notify("quill — transcription failed", "\(dir.lastPathComponent) — see transcribe.log")
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
