import Foundation

/// Session folder names. The Mac names folders `yyyy.MM.dd-HHmm`; iPhone
/// sessions add `-iphone`, so they sort beside the Mac's in `~/Recordings`
/// and never collide with a Mac recording started the same minute.
public enum SessionFolder {
    public static let suffix = "-iphone"

    public static func name(startedAt date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.string(from: date) + suffix
    }

    /// The start minute a folder name encodes ("2026.10.26-1530…"), for
    /// sessions whose meta.json predates the `started` field.
    public static func date(fromName name: String, timeZone: TimeZone = .current) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.date(from: String(name.prefix(15)))
    }

    /// `base`, or `base-2`, `base-3`, … — the first name not `taken`.
    public static func unique(_ base: String, taken: (String) -> Bool) -> String {
        var candidate = base
        var n = 2
        while taken(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// A folder is finished once its meta.json exists.
    public static func isFinished(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
    }
}
