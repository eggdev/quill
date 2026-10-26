import AVFoundation
import Foundation
import Observation
import QuillKit

/// Every recording the app can show: sessions recorded on this iPhone (kept
/// with their audio for a while after sending, so they can be played back),
/// joined with the transcripts the Mac publishes to iCloud — for its own
/// recordings as well as these.
@MainActor @Observable
final class Library {
    private(set) var recordings: [RecordingSummary] = []
    /// False when the app has no iCloud account to send through.
    private(set) var iCloudAvailable = true
    /// The first scan has finished, so an empty list really is empty.
    private(set) var loaded = false
    private var libraryDir: URL?

    nonisolated private static let sessionsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sessions", isDirectory: true)
    /// Sent recordings keep their audio this long, for playback.
    private static let keepAudio: TimeInterval = 30 * 24 * 3600
    /// Marks a local session as handed to iCloud.
    nonisolated private static let sentMarker = ".sent"

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

    /// The Mac's transcript, if it has published one.
    func transcript(for recording: RecordingSummary) async -> Transcript? {
        guard let libraryDir else { return nil }
        let url = libraryDir.appendingPathComponent(recording.name).appendingPathComponent("transcript.json")
        return await Task.detached { Self.readJSON(Transcript.self, at: url) }.value
    }

    func refresh() async {
        let scan = await Task.detached { Self.scan() }.value
        libraryDir = scan.libraryDir
        iCloudAvailable = scan.iCloudAvailable
        recordings = RecordingSummary.merge(local: scan.local, published: scan.published)
        loaded = true
    }

    /// Hand every unsent session to iCloud (a copy; the audio stays here for
    /// playback), clear out audio past its keep date, then rescan.
    func sendFinished() async {
        let unsent = Self.localFolders().filter { !Self.isSent($0) }
        if !unsent.isEmpty {
            let sent = await Task.detached { Outbox.send(unsent) }.value
            for dir in unsent where sent?.contains(dir.lastPathComponent) == true {
                FileManager.default.createFile(atPath: dir.appendingPathComponent(Self.sentMarker).path, contents: nil)
            }
        }
        pruneSentAudio()
        await refresh()
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

    // MARK: - Scanning

    private struct Scan: Sendable {
        var local: [LocalSession]
        var published: [PublishedSession]
        var libraryDir: URL?
        var iCloudAvailable: Bool
    }

    /// Off the main thread: the iCloud container lookup can block.
    nonisolated private static func scan() -> Scan {
        let local = localFolders().compactMap { dir -> LocalSession? in
            readJSON(SessionManifest.self, at: dir.appendingPathComponent("meta.json")).map {
                LocalSession(name: dir.lastPathComponent, manifest: $0, sent: isSent(dir))
            }
        }
        let container = FileManager.default.url(forUbiquityContainerIdentifier: Outbox.containerID)
        let library = libraryOverride ?? container?.appendingPathComponent("Documents/Library", isDirectory: true)
        return Scan(
            local: local, published: library.map(published(in:)) ?? [], libraryDir: library,
            iCloudAvailable: container != nil)
    }

    /// Transcripts the Mac published. iCloud lists folders before their files
    /// arrive; ask for anything missing and pick it up on the next scan.
    nonisolated private static func published(in library: URL) -> [PublishedSession] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir in
            let transcriptURL = dir.appendingPathComponent("transcript.json")
            let metaURL = dir.appendingPathComponent("meta.json")
            for url in [transcriptURL, metaURL] where !fm.fileExists(atPath: url.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
            }
            guard let transcript = readJSON(Transcript.self, at: transcriptURL) else { return nil }
            return PublishedSession(
                name: dir.lastPathComponent, manifest: readJSON(SessionManifest.self, at: metaURL),
                transcript: transcript)
        }
    }

    /// Debug builds can point at a local folder (`QUILL_LIBRARY_DIR`), since
    /// the Simulator has no iCloud.
    nonisolated private static var libraryOverride: URL? {
        #if DEBUG
            ProcessInfo.processInfo.environment["QUILL_LIBRARY_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
            nil
        #endif
    }

    nonisolated private static func localFolders() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter(SessionFolder.isFinished).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func isSent(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(sentMarker).path)
    }

    nonisolated private static func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func pruneSentAudio() {
        let cutoff = Date().addingTimeInterval(-Self.keepAudio)
        for dir in Self.localFolders() where Self.isSent(dir) {
            let started = SessionFolder.date(fromName: dir.lastPathComponent) ?? .distantFuture
            if started < cutoff { try? FileManager.default.removeItem(at: dir) }
        }
    }
}

/// Hands finished sessions to the Mac: a copy of each folder goes into the
/// app's iCloud container under Documents/Inbox, which iCloud Drive syncs to
/// the Mac, where quill imports and transcribes it.
enum Outbox {
    static let containerID = "iCloud.com.eggdev.quill"

    /// The names sent, or nil when iCloud isn't available to the app. Call
    /// off the main thread.
    nonisolated static func send(_ dirs: [URL]) -> [String]? {
        let fm = FileManager.default
        guard let container = fm.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let inbox = container.appendingPathComponent("Documents/Inbox", isDirectory: true)
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        var sent: [String] = []
        for dir in dirs {
            let name = SessionFolder.unique(dir.lastPathComponent) {
                fm.fileExists(atPath: inbox.appendingPathComponent($0).path)
            }
            // setUbiquitous moves its source, so hand it a copy.
            let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.copyItem(at: dir, to: staging)
                try fm.setUbiquitous(true, itemAt: staging, destinationURL: inbox.appendingPathComponent(name))
                sent.append(dir.lastPathComponent)
            } catch {
                try? fm.removeItem(at: staging)
            }
        }
        return sent
    }
}
