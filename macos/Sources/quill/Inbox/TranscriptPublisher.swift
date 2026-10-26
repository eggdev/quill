import Foundation

/// Publishes each transcribed session's transcript.json and meta.json to the
/// iPhone app's library folder in iCloud, so the phone can list and read every
/// recording — the Mac's as well as its own. Audio stays on the Mac.
///
/// Runs on the inbox timer and copies only what is missing or older than the
/// recordings root's copy, so it also backfills sessions transcribed before
/// the phone app existed and picks up a re-transcription.
struct TranscriptPublisher {
    let root: URL
    let library: URL

    static let files = ["transcript.json", "meta.json"]

    /// Copy what changed; returns the session names published, oldest first.
    func publish() -> [String] {
        let fm = FileManager.default
        guard
            let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        var published: [String] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source = dir.appendingPathComponent("transcript.json")
            let dest = library.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            guard fm.fileExists(atPath: source.path), isNewer(source, than: dest.appendingPathComponent("transcript.json"))
            else { continue }
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in Self.files {
                    let from = dir.appendingPathComponent(file)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    try Data(contentsOf: from).write(to: dest.appendingPathComponent(file), options: .atomic)
                }
                published.append(dir.lastPathComponent)
            } catch {
                FileHandle.standardError.write(
                    Data("warning: couldn't publish \(dir.lastPathComponent) to iPhone: \(error)\n".utf8))
            }
        }
        return published
    }

    private func isNewer(_ source: URL, than dest: URL) -> Bool {
        let fm = FileManager.default
        guard let destDate = (try? fm.attributesOfItem(atPath: dest.path))?[.modificationDate] as? Date else {
            return true
        }
        let sourceDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
        return (sourceDate ?? .distantPast) > destDate
    }
}
