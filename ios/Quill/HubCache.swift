import Foundation
import QuillKit

/// The hub's session list and the transcripts fetched so far, kept in
/// Application Support so the list shows at once on launch and offline.
/// Call off the main thread.
enum HubCache {
    /// The session list, cursor and catalog id, tagged with the hub they
    /// came from: a different hub has different sessions.
    struct Library: Codable, Sendable {
        var hub: String
        var state: HubSyncState
    }

    /// A transcript, with the session revision it was fetched at.
    struct CachedTranscript: Codable, Sendable {
        var revision: Int
        var transcript: Transcript
    }

    /// What search needs of a cached transcript.
    struct Text: Sendable {
        var revision: Int
        var text: String
    }

    private static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hub", isDirectory: true)
    private static let libraryURL = dir.appendingPathComponent("library.json")
    private static let transcriptsDir = dir.appendingPathComponent("Transcripts", isDirectory: true)

    /// The cached sessions for `hub`, or a fresh start if they came from
    /// another one.
    static func loadState(hub: URL?) -> HubSyncState {
        guard let hub, let data = try? Data(contentsOf: libraryURL),
            let library = try? JSONDecoder().decode(Library.self, from: data), library.hub == hub.absoluteString
        else { return HubSyncState() }
        return library.state
    }

    static func save(_ state: HubSyncState, hub: URL) {
        write(Library(hub: hub.absoluteString, state: state), to: libraryURL)
    }

    /// Every cached transcript's text, by session id.
    static func loadTexts() -> [String: Text] {
        let files = (try? FileManager.default.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: nil)) ?? []
        var texts: [String: Text] = [:]
        for url in files where url.pathExtension == "json" {
            guard let cached = read(url) else { continue }
            texts[url.deletingPathExtension().lastPathComponent] = Text(
                revision: cached.revision, text: cached.transcript.fullText)
        }
        return texts
    }

    static func transcript(id: String) -> CachedTranscript? {
        transcriptURL(id: id).flatMap(read)
    }

    static func save(_ transcript: Transcript, id: String, revision: Int) {
        guard let url = transcriptURL(id: id) else { return }
        write(CachedTranscript(revision: revision, transcript: transcript), to: url)
    }

    /// Ids are UUIDs; anything else is not trusted as a file name.
    private static func transcriptURL(id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return transcriptsDir.appendingPathComponent("\(id).json")
    }

    private static func read(_ url: URL) -> CachedTranscript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedTranscript.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
