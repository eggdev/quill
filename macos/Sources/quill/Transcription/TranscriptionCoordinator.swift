import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    /// One session's progress, for the hub catalog.
    enum Event: Sendable {
        case started(URL)
        case finished(URL)
        /// `reason` is one line, fit for a status field.
        case failed(URL, reason: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    /// Set when the remote engine stayed down through every retry during this
    /// drain; the rest of the queue goes to the local engine instead of
    /// waiting on a dead host again.
    private var remoteDown = false
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var eventHandler: (@Sendable (Event) async -> Void)?
    private var notifies: @Sendable (URL) -> Bool = { _ in true }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Awaited before the coordinator moves on, so the catalog sees
    /// `started` before `finished` for every session.
    func setEventHandler(_ handler: @escaping @Sendable (Event) async -> Void) {
        eventHandler = handler
    }

    /// Which sessions get a "transcript ready" or "transcription failed"
    /// notification. The hub turns them off for sessions a client uploaded:
    /// the client tells its own user.
    func setNotificationFilter(_ predicate: @escaping @Sendable (URL) -> Bool) {
        notifies = predicate
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            OnStopHook.run(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort. Hidden folders are skipped: the hub stages
    /// uploads in `.incoming`.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        else { return }

        let fm = FileManager.default
        let pending =
            entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "resuming \(pending.count) untranscribed session(s)\n".utf8
                ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            await eventHandler?(.started(dir))
            do {
                let meeting = SessionMeta.meeting(in: dir)
                try await transcribePreferringRemote(dir, meeting: meeting)
                await eventHandler?(.finished(dir))
                if notifies(dir) {
                    notifyUser(title: "quill — transcript ready", body: meeting?.title ?? dir.lastPathComponent)
                }
                OnStopHook.run(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                await eventHandler?(.failed(dir, reason: Self.oneLine("\(error)")))
                if notifies(dir) {
                    notifyUser(
                        title: "quill — transcription failed",
                        body: "\(dir.lastPathComponent) — see transcribe.log"
                    )
                }
            }
        }
        await engine?.release()
        engine = nil
        remoteDown = false
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    /// Waits before another try at the remote engine after it failed on its
    /// side. A server that restarts, or that had its model unloaded during a
    /// request, is usually back within these. After the last wait fails too,
    /// the session goes to the local engine.
    static let remoteRetryDelays: [Duration] = [.seconds(30), .seconds(120), .seconds(300)]

    /// Transcribe with the configured engine. When the remote engine fails
    /// on its side, wait and try it again before giving the session to the
    /// local engine: a local transcript has no speaker labels, and nothing
    /// replaces it later.
    private func transcribePreferringRemote(_ dir: URL, meeting: SessionMeta.Meeting?) async throws {
        var delays = Self.remoteRetryDelays[...]
        while true {
            do {
                return try await transcribe(dir, meeting: meeting)
            } catch let error as RemoteEngine.EngineError {
                guard case .unreachable = error else { throw error }
                await engine?.release()
                engine = nil
                if let delay = delays.popFirst() {
                    log(dir, "\(error) — trying again in \(delay.components.seconds) s")
                    try? await Task.sleep(for: delay)
                } else {
                    log(dir, "\(error) — transcribing locally")
                    remoteDown = true
                }
            }
        }
    }

    private func transcribe(_ dir: URL, meeting: SessionMeta.Meeting?) async throws {
        // Both metadata schemas normalize to ordered (file, speaker, offset)
        // inputs — one per segment under v2, one per track under v1. Each
        // segment shifts onto the session clock, so timing gaps around a
        // capture recovery stay visible.
        let (inputs, captureStatus) = try SessionMeta.readInputs(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in Self.tracks(inputs) {
            let present = track.filter { input in
                let found = FileManager.default.fileExists(atPath: dir.appendingPathComponent(input.file).path)
                if !found { log(dir, "skipping missing segment \(input.file)") }
                return found
            }
            guard let speaker = present.first?.speaker else { continue }
            // One voice on the mic is the user; any other track may hold
            // several people.
            let diarize = speaker != "me"
            let files = present.map { dir.appendingPathComponent($0.file) }
            log(dir, "transcribing \(present.map(\.file).joined(separator: ", ")) (\(engine.name))")
            var results: [[TranscriptSegment]]?
            do {
                results = try await engine.transcribe(track: files, diarize: diarize)
            } catch RemoteEngine.EngineError.rejected(let why) where files.count > 1 {
                // One bad file shouldn't cost the rest of the track; retry
                // file by file below.
                log(dir, "track rejected (\(why)) — retrying file by file")
            }
            for (i, input) in present.enumerated() {
                let segments: [TranscriptSegment]
                if let results {
                    segments = results[i]
                } else {
                    // One bad segment (empty, truncated) shouldn't cost us the
                    // rest — log it and keep going.
                    do {
                        segments = try await engine.transcribe(files[i], diarize: diarize)
                    } catch RemoteEngine.EngineError.unreachable(let url, let why) {
                        throw RemoteEngine.EngineError.unreachable(url, why)
                    } catch {
                        log(dir, "skipping \(input.file): \(error)")
                        continue
                    }
                }
                merged += Transcript.shifted(segments, speaker: input.speaker, offsetMs: input.offsetMs)
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir, captureStatus: captureStatus, meeting: meeting)
        log(dir, "done — \(merged.count) segments")
    }

    /// Consecutive inputs of one track. Segment files of a track are listed
    /// together and in order in both metadata schemas.
    static func tracks(_ inputs: [SessionMeta.TrackInput]) -> [[SessionMeta.TrackInput]] {
        var out: [[SessionMeta.TrackInput]] = []
        for input in inputs {
            if let last = out.last?.last, last.speaker == input.speaker {
                out[out.count - 1].append(input)
            } else {
                out.append([input])
            }
        }
        return out
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        switch Config.transcriptionEngine() {
        case "remote" where !remoteDown:
            if let url = Config.transcriptionURL() {
                let engine = try await RemoteEngine.connect(url)
                self.engine = engine
                return engine
            }
            FileHandle.standardError.write(Data("warning: transcription.url missing or invalid — using parakeet\n".utf8))
        case "parakeet", "remote":
            break
        case let configured:
            FileHandle.standardError.write(
                Data(
                    "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
                ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    private func log(_ dir: URL, _ message: String) {
        SessionLog.append(dir, message)
    }

    /// First line of an error description, at most 300 characters.
    static func oneLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(first.prefix(300))
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized. Internal (not private) so the offset-preserving
/// merge math is unit-testable.
struct Transcript: Codable {
    struct Segment: Codable, Equatable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Shift one audio file's transcript segments onto the session clock by
    /// the file's start offset. Segments are never collapsed against a
    /// previous file's end — a capture gap stays visible as a timestamp gap.
    static func shifted(
        _ segments: [TranscriptSegment], speaker: String, offsetMs: Int
    ) -> [Segment] {
        segments.map {
            Segment(
                speaker: label(track: speaker, index: $0.speaker),
                start_ms: Int($0.start * 1000) + offsetMs,
                end_ms: Int($0.end * 1000) + offsetMs,
                text: $0.text
            )
        }
    }

    /// A diarized voice within one track: "speaker 2" on the iPhone's room
    /// track, "them 2" on a call.
    static func label(track: String, index: Int?) -> String {
        guard let index else { return track }
        return "\(track == "room" ? "speaker" : track) \(index + 1)"
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    /// `captureStatus` (v2 sessions only) is persisted in the readable header
    /// so an incomplete recording stays visibly incomplete after the
    /// transient notification disappears. A calendar `meeting` titles the
    /// readable transcript; the folder name stays on its own line.
    func write(to dir: URL, captureStatus: TrackStatus? = nil, meeting: SessionMeta.Meeting? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        let title = meeting?.title ?? dir.lastPathComponent
        let session = meeting == nil ? nil : dir.lastPathComponent
        try Data(rendered(title: title, session: session, captureStatus: captureStatus).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func rendered(title: String, session: String? = nil, captureStatus: TrackStatus? = nil) -> String {
        var lines = ["# \(title)", ""]
        if let session { lines.append("session: \(session)") }
        lines.append("engine: \(engine) (\(model))")
        if let captureStatus, captureStatus != .complete {
            lines.append("capture: \(captureStatus.rawValue)")
        }
        lines.append("")
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
