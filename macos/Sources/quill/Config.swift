import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook",
///       "calendar": { "mode": "auto", "require_video_link": true },
///       "floating_indicator": true
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// How calendar meetings drive recording: `off` (default), `ask` (show
    /// the floating indicator as a prompt when a meeting starts), or `auto`
    /// (start recording on its own). Unknown values read as off.
    static func calendarMode() -> AutoRecordMode {
        (calendar()?["mode"] as? String).flatMap(AutoRecordMode.init(rawValue:)) ?? .off
    }

    /// How calls without a calendar event (a meeting app holding the mic) are
    /// handled: `off`, `ask`, or `auto`. Defaults to `ask` whenever calendar
    /// meetings are on, and `off` otherwise.
    static func adhocCallMode() -> AutoRecordMode {
        if let raw = calendar()?["adhoc_calls"] as? String, let mode = AutoRecordMode(rawValue: raw) {
            return mode
        }
        return calendarMode() == .off ? .off : .ask
    }

    /// Whether a browser holding the mic counts as a call (Meet, browser
    /// Teams). Default off — browsers use the mic for many other things.
    static func browserCalls() -> Bool {
        calendar()?["browser_calls"] as? Bool ?? false
    }

    /// Calendar meeting selection and auto-stop tuning. Every key is optional.
    static func calendarFilter() -> MeetingFilter {
        let c = calendar() ?? [:]
        var filter = MeetingFilter()
        if let v = c["require_video_link"] as? Bool { filter.requireVideoLink = v }
        if let v = c["ignore_calendars"] as? [String] { filter.ignoredCalendars = Set(v) }
        return filter
    }

    static func calendarTiming() -> MeetingScheduler.Timing {
        let c = calendar() ?? [:]
        var timing = MeetingScheduler.Timing()
        if let v = c["lead_seconds"] as? Double { timing.lead = v }
        if let v = c["stop_after_quiet_seconds"] as? Double { timing.quietAfterEnd = v }
        return timing
    }

    /// Persist a new calendar mode (the menu's Meetings submenu). Other keys
    /// survive; formatting and key order are normalized.
    /// A malformed file is left alone rather than replaced.
    static func setCalendarMode(_ mode: AutoRecordMode) throws {
        let exists = FileManager.default.fileExists(atPath: path.path)
        guard var json = load() ?? (exists ? nil : [:]) else { throw ConfigError.malformed(path) }
        var c = json["calendar"] as? [String: Any] ?? [:]
        c["mode"] = mode.rawValue
        json["calendar"] = c
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
    }

    /// Whether the floating recording indicator is shown. Default on.
    static func floatingIndicator() -> Bool {
        load()?["floating_indicator"] as? Bool ?? true
    }

    private static func calendar() -> [String: Any]? {
        load()?["calendar"] as? [String: Any]
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning. The calendar scheduler reads config every few
    /// seconds, so the parse is cached until the file's modification date
    /// changes (which also keeps a malformed file to one warning per edit).
    private static func load() -> [String: Any]? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        guard let modified else { return nil }
        return cache.value(modified: modified) {
            guard
                let data = try? Data(contentsOf: path),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                FileHandle.standardError.write(
                    Data(
                        "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
                    ))
                return nil
            }
            return json
        }
    }

    private static let cache = ParseCache()

    /// Last parse of the config file, keyed by its modification date. Read
    /// from the main actor and the transcription actor, hence the lock.
    private final class ParseCache: @unchecked Sendable {
        private let lock = NSLock()
        private var modified: Date?
        private var json: [String: Any]?

        func value(modified: Date, parse: () -> [String: Any]?) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            if modified != self.modified {
                json = parse()
                self.modified = modified
            }
            return json
        }
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case malformed(URL)

    var description: String {
        switch self {
        case .malformed(let url): return "\(url.path) is not valid JSON — fix it before changing settings"
        }
    }
}
