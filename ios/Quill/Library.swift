import AVFoundation
import Foundation
import Observation
import QuillKit

/// Every recording the app can show: sessions recorded on this iPhone (kept
/// with their audio for a while after sending, so they can be played back),
/// joined with the sessions the hub lists — from Macs as well as iPhones.
@MainActor @Observable
final class Library {
    enum HubState: Equatable {
        /// No hub address saved.
        case notSet
        /// Not asked yet since launch or since the address changed.
        case unknown
        case reachable
        case unreachable
    }

    private(set) var recordings: [RecordingSummary] = []
    private(set) var hubState: HubState
    /// The first refresh has finished, so an empty list really is empty.
    private(set) var loaded = false

    private var local: [LocalSession] = []
    private var sync = HubSyncState()
    private var texts: [String: HubCache.Text] = [:]
    /// The hub `sync` came from; a different one starts a fresh list.
    private var syncedHub: URL?
    private var cacheLoaded = false
    private var refreshing: Task<Void, Never>?
    /// What the hub listed, once a list has been fetched from it since
    /// launch (or since the address changed). Old iCloud folders are judged
    /// against it, never against the cache.
    private var catalog: HubCatalog?
    /// Folders stuck on `missing_files` try again at launch and when the
    /// address changes, not on every refresh.
    private var resetMissingRounds = true
    private var prefetching = false

    nonisolated static let sessionsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sessions", isDirectory: true)
    /// Sent recordings keep their audio this long, for playback.
    private static let keepAudio: TimeInterval = 30 * 24 * 3600
    /// Transcripts fetched at once in the background, for search.
    private static let prefetchWidth = 3

    init() {
        hubState = HubSettings.baseURL == nil ? .notSet : .unknown
        NotificationCenter.default.addObserver(forName: HubSender.didChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLocal() }
        }
    }

    func newSessionFolder(startedAt: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.sessionsDir, withIntermediateDirectories: true)
        let name = SessionFolder.unique(SessionFolder.name(startedAt: startedAt)) {
            fm.fileExists(atPath: Self.sessionsDir.appendingPathComponent($0).path)
        }
        let dir = Self.sessionsDir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The recording's audio folder on this iPhone, if it's still here.
    func audioFolder(for recording: RecordingSummary) -> URL? {
        recording.hasAudio ? Self.sessionsDir.appendingPathComponent(recording.name, isDirectory: true) : nil
    }

    func manifest(for recording: RecordingSummary) -> SessionManifest? {
        guard let dir = audioFolder(for: recording) else { return nil }
        return Self.readJSON(SessionManifest.self, at: dir.appendingPathComponent("meta.json"))
    }

    /// The hub's transcript: from the cache when it's current, else fetched
    /// and cached. Offline, an out-of-date copy is better than none.
    func transcript(for recording: RecordingSummary) async -> Transcript? {
        guard let id = recording.hubID else { return nil }
        let cached = await Task.detached { HubCache.transcript(id: id) }.value
        if let cached, cached.revision == recording.revision { return cached.transcript }
        guard recording.stage == .transcribed, let revision = recording.revision, let api = HubSettings.api,
            let fresh = try? await HubClient.transcript(api, id: id)
        else { return cached?.transcript }
        await Task.detached { HubCache.save(fresh, id: id, revision: revision) }.value
        texts[id] = HubCache.Text(revision: revision, text: fresh.fullText)
        publish()
        return fresh
    }

    /// Show what's on disk at once, then ask the hub for what changed.
    /// Overlapping calls (the timer, pull to refresh, a finished recording)
    /// share one pass.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let pass = Task { await performRefresh() }
        refreshing = pass
        await pass.value
        refreshing = nil
    }

    /// Give every finished recording its session id and start whatever
    /// upload or commit it still needs, clear out audio past its keep date,
    /// then refresh.
    func sendFinished() async {
        let folders = await Task.detached { Self.localFolders() }.value
        let reset = resetMissingRounds
        resetMissingRounds = false
        await HubSender.shared.reconcile(folders: folders, catalog: catalog, resetMissingRounds: reset)
        pruneSentAudio()
        await refresh()
    }

    /// The address was changed in Settings: start over with the new hub.
    func hubAddressChanged() {
        hubState = HubSettings.baseURL == nil ? .notSet : .unknown
        catalog = nil
        resetMissingRounds = true
        Task { await sendFinished() }
    }

    /// A folder with audio but no meta.json was cut off by the app quitting
    /// mid-recording; give it a manifest so it isn't lost. Called at launch,
    /// before anything can be recording.
    func recoverUnfinished() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.sessionsDir, includingPropertiesForKeys: nil)
        else { return }
        for dir in dirs where !SessionFolder.isFinished(dir) {
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".caf") }
                .sorted()
                .compactMap { name in Self.audio(of: dir.appendingPathComponent(name)).map { (name, $0) } }
            guard !files.isEmpty else {
                try? fm.removeItem(at: dir)
                continue
            }
            let created = (try? fm.attributesOfItem(atPath: dir.path)[.creationDate] as? Date) ?? Date()
            try? SessionManifest(recovering: files, started: created).write(to: dir)
        }
    }

    /// Frame count and format of a finished segment file.
    nonisolated static func audio(of url: URL) -> SegmentAudio? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return SegmentAudio(
            frames: file.length, sampleRateHz: Int(file.fileFormat.sampleRate),
            channels: Int(file.fileFormat.channelCount))
    }

    // MARK: - Refreshing

    private func performRefresh() async {
        let hub = HubSettings.baseURL
        if !cacheLoaded || hub != syncedHub {
            let (state, cachedTexts) = await Task.detached { (HubCache.loadState(hub: hub), HubCache.loadTexts()) }.value
            sync = state
            texts = cachedTexts
            syncedHub = hub
            cacheLoaded = true
        }
        local = await Task.detached { Self.scanLocal() }.value
        publish()

        guard let hub else {
            hubState = .notSet
            loaded = true
            return
        }
        let api = HubAPI(base: hub)
        do {
            var state = sync
            var more = true
            while more {
                let after = state.revision
                more = state.apply(try await HubClient.sessions(api, after: after), after: after)
                // A new catalog makes what the hub listed before meaningless
                // to the old-folder decisions until the refetch completes.
                if state.catalog != sync.catalog { catalog = nil }
            }
            // The address may have changed while the pages loaded.
            guard HubSettings.baseURL == hub else { return }
            let fetched = state
            if fetched != sync {
                sync = fetched
                await Task.detached { HubCache.save(fetched, hub: hub) }.value
            }
            catalog = HubCatalog(fetched.sessions.values)
            hubState = .reachable
        } catch {
            guard HubSettings.baseURL == hub else { return }
            hubState = .unreachable
        }
        loaded = true
        publish()

        guard hubState == .reachable else { return }
        // The hub is back: anything that stalled while it was away goes now,
        // and old iCloud folders the hub doesn't have start their upload.
        let catalog = catalog
        if local.contains(where: {
            HubFolderPolicy.needsUpload(
                name: $0.name, delivery: $0.delivery, legacySent: $0.legacySent, catalog: catalog)
        }) {
            let folders = await Task.detached { Self.localFolders() }.value
            await HubSender.shared.reconcile(folders: folders, catalog: catalog, resetMissingRounds: false)
        }
        Task { await prefetchTranscripts(api: api) }
    }

    /// A delivery step finished in the background session.
    private func reloadLocal() {
        Task {
            local = await Task.detached { Self.scanLocal() }.value
            publish()
        }
    }

    private func publish() {
        recordings = RecordingSummary.merge(
            local: local, hub: Array(sync.sessions.values), transcripts: texts.mapValues(\.text),
            thisDevice: HubSettings.deviceID)
    }

    /// Search covers transcript text, so fetch the transcripts not cached
    /// yet (or changed since), a few at a time.
    private func prefetchTranscripts(api: HubAPI) async {
        guard !prefetching else { return }
        prefetching = true
        defer { prefetching = false }
        let wanted = sync.sessions.values
            .filter { $0.status == .transcribed && texts[$0.id]?.revision != $0.revision }
            .sorted { $0.revision > $1.revision }
            .map { ($0.id, $0.revision) }
        guard !wanted.isEmpty else { return }

        await withTaskGroup(of: (String, HubCache.Text)?.self) { group in
            var pending = wanted.makeIterator()
            func fetchNext() {
                guard let (id, revision) = pending.next() else { return }
                group.addTask {
                    guard let transcript = try? await HubClient.transcript(api, id: id) else { return nil }
                    HubCache.save(transcript, id: id, revision: revision)
                    return (id, HubCache.Text(revision: revision, text: transcript.fullText))
                }
            }
            for _ in 0..<Self.prefetchWidth { fetchNext() }
            var fetched = 0
            for await result in group {
                if let (id, text) = result {
                    texts[id] = text
                    fetched += 1
                    if fetched % 10 == 0 { publish() }
                }
                fetchNext()
            }
        }
        publish()
    }

    // MARK: - Local folders

    nonisolated private static func scanLocal() -> [LocalSession] {
        localFolders().compactMap { dir -> LocalSession? in
            readJSON(SessionManifest.self, at: dir.appendingPathComponent("meta.json")).map {
                LocalSession(
                    name: dir.lastPathComponent, manifest: $0, delivery: HubDelivery.read(in: dir),
                    legacySent: HubDelivery.isLegacySent(dir))
            }
        }
    }

    nonisolated private static func localFolders() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter(SessionFolder.isFinished).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Only recordings the hub has lose their audio here.
    private func pruneSentAudio() {
        let cutoff = Date().addingTimeInterval(-Self.keepAudio)
        for dir in Self.localFolders() {
            let started = SessionFolder.date(fromName: dir.lastPathComponent) ?? .distantFuture
            guard started < cutoff,
                HubFolderPolicy.mayPruneAudio(
                    name: dir.lastPathComponent, delivery: HubDelivery.read(in: dir),
                    legacySent: HubDelivery.isLegacySent(dir), catalog: catalog)
            else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
