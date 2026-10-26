import Foundation

/// Brings sessions recorded on the iPhone into the recordings root. The phone
/// moves each finished session folder into its iCloud container's Inbox, and
/// iCloud syncs it here file by file — so a folder is imported only once its
/// meta.json and every segment it names are on disk and downloaded. Moving it
/// out of iCloud Drive also removes it from iCloud: the Mac keeps the one
/// copy, beside its own recordings.
struct InboxImporter {
    let inbox: URL
    let root: URL
    /// Whether a file's contents are on disk. iCloud lists files before it
    /// downloads them; tests substitute their own answer.
    var isDownloaded: (URL) -> Bool = InboxImporter.isDownloaded

    /// Move every finished session from the inbox into the root, oldest
    /// first, and return where each one landed.
    func importReady() -> [URL] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        var imported: [URL] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isReady(dir) {
            let base = dir.lastPathComponent
            var dest = root.appendingPathComponent(base, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
                n += 1
            }
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try fm.moveItem(at: dir, to: dest)
                imported.append(dest)
            } catch {
                FileHandle.standardError.write(Data("warning: couldn't import \(base) from iPhone: \(error)\n".utf8))
            }
        }
        return imported
    }

    /// meta.json (v2) and every segment it names are downloaded.
    func isReady(_ dir: URL) -> Bool {
        let metaURL = dir.appendingPathComponent("meta.json")
        guard
            isDownloaded(metaURL),
            let data = try? Data(contentsOf: metaURL),
            let meta = try? JSONDecoder().decode(SessionMeta.self, from: data),
            meta.schema_version >= 2
        else { return false }
        // Check every file, not just the first missing one, so iCloud starts
        // downloading all of them at once.
        let files = meta.tracks.flatMap { $0.segments.map { dir.appendingPathComponent($0.file) } }
        return files.map(isDownloaded).allSatisfy { $0 }
    }

    /// A local file is always downloaded. An iCloud file is once its status
    /// is current; until then, ask iCloud to fetch it.
    static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if FileManager.default.fileExists(atPath: url.path), values?.isUbiquitousItem != true { return true }
        if values?.ubiquitousItemDownloadingStatus == .current { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }
}
