import Foundation

/// A meeting app recognized by the bundle ID of the process holding the mic.
/// Matching is by prefix because call audio often runs in a helper process
/// (`com.microsoft.teams2.helper`, `com.google.Chrome.helper`, …).
struct MeetingApp: Equatable, Sendable {
    var bundlePrefix: String
    var name: String
    /// Browsers hold the mic for many things besides calls, so they only
    /// count when the config opts in.
    var isBrowser = false

    static let known: [MeetingApp] = [
        MeetingApp(bundlePrefix: "us.zoom.xos", name: "Zoom"),
        MeetingApp(bundlePrefix: "com.microsoft.teams2", name: "Teams"),
        MeetingApp(bundlePrefix: "com.microsoft.teams", name: "Teams"),
        MeetingApp(bundlePrefix: "com.cisco.webexmeetingsapp", name: "Webex"),
        MeetingApp(bundlePrefix: "Cisco-Systems.Spark", name: "Webex"),
        MeetingApp(bundlePrefix: "com.tinyspeck.slackmacgap", name: "Slack"),
        MeetingApp(bundlePrefix: "com.apple.FaceTime", name: "FaceTime"),
        // FaceTime's call audio runs in this daemon rather than the app.
        MeetingApp(bundlePrefix: "com.apple.avconferenced", name: "FaceTime"),
        MeetingApp(bundlePrefix: "com.google.Chrome", name: "Browser", isBrowser: true),
        MeetingApp(bundlePrefix: "company.thebrowser.Browser", name: "Browser", isBrowser: true),
        MeetingApp(bundlePrefix: "com.microsoft.edgemac", name: "Browser", isBrowser: true),
        MeetingApp(bundlePrefix: "com.brave.Browser", name: "Browser", isBrowser: true),
        MeetingApp(bundlePrefix: "org.mozilla.firefox", name: "Browser", isBrowser: true),
    ]

    /// The meeting app a process belongs to, if any. A prefix must end at a
    /// dot boundary so `com.microsoft.teamsfoo` doesn't match Teams.
    static func match(bundleID: String, includeBrowsers: Bool) -> MeetingApp? {
        known.first { app in
            (includeBrowsers || !app.isBrowser)
                && (bundleID == app.bundlePrefix || bundleID.hasPrefix(app.bundlePrefix + "."))
        }
    }
}

/// Notices calls that have no calendar event: a meeting app holding the
/// microphone. Pure, like `MeetingScheduler` — the app feeds it which meeting
/// apps hold the mic right now and what is recording; it returns what to do.
///
/// A call starts once an app has held the mic for `startAfter` (joining,
/// device checks, and voice memos are brief) and ends once the app has let go
/// for `endAfter` (rides out reconnects and device switches). Each call
/// triggers at most once.
struct CallDetector: Sendable {
    enum Mode: String, Sendable, CaseIterable {
        case off, ask, auto
    }

    struct Call: Equatable, Sendable {
        /// Unique per call: app name plus when it took the mic.
        var id: String
        var app: String
        var start: Date

        var title: String { "\(app) call" }
    }

    enum Recording: Equatable, Sendable {
        case idle
        /// A manual or calendar-meeting recording: calls are part of it.
        case other
        /// A recording started for this detected call.
        case call(Call)
    }

    enum Action: Equatable, Sendable {
        case start(Call)
        /// The recorded call ended.
        case stop
    }

    struct Timing: Sendable {
        var startAfter: TimeInterval = 5
        var endAfter: TimeInterval = 30
    }

    var mode: Mode
    var timing = Timing()
    private(set) var handled: Set<String> = []
    /// Ask mode: the call currently offered for recording.
    private(set) var prompting: Call?
    /// When each app took the mic, and when it let go (while still inside
    /// the end debounce).
    private var holdingSince: [String: Date] = [:]
    private var releasedSince: [String: Date] = [:]
    /// The latest `decide` time, so `currentCall` applies the same debounce.
    private var lastNow = Date.distantPast

    init(mode: Mode, timing: Timing = Timing()) {
        self.mode = mode
        self.timing = timing
    }

    /// The ongoing call, debounced at both ends; the earliest wins when two
    /// apps hold the mic.
    var currentCall: Call? { currentCall(now: lastNow) }

    mutating func markHandled(_ call: Call) {
        handled.insert(call.id)
        if prompting?.id == call.id { prompting = nil }
    }

    /// One pass. `holding` is the set of meeting-app names holding the mic;
    /// `meetingDue` is true while a calendar meeting is in its window, which
    /// takes precedence over an ad-hoc prompt (the call is that meeting).
    mutating func decide(
        now: Date, holding: Set<String>, recording: Recording, meetingDue: Bool
    ) -> Action? {
        lastNow = now
        observe(now: now, holding: holding)
        let call = currentCall(now: now)

        if case .call(let recorded) = recording {
            prompting = nil
            // The app let go for good, or a different call took over.
            return call?.id == recorded.id ? nil : .stop
        }
        if recording == .other || meetingDue {
            // The call belongs to the running recording or to the meeting
            // the calendar is handling; never offer it separately later.
            if let call { handled.insert(call.id) }
            prompting = nil
            return nil
        }
        guard mode != .off, let call, !handled.contains(call.id) else {
            prompting = nil
            return nil
        }
        if mode == .ask {
            prompting = call
            return nil
        }
        prompting = nil
        handled.insert(call.id)
        return .start(call)
    }

    // MARK: -

    private mutating func observe(now: Date, holding: Set<String>) {
        for app in holding {
            if holdingSince[app] == nil { holdingSince[app] = now }
            releasedSince[app] = nil
        }
        for app in holdingSince.keys where !holding.contains(app) {
            let released = releasedSince[app] ?? now
            if now.timeIntervalSince(released) >= timing.endAfter {
                holdingSince[app] = nil
                releasedSince[app] = nil
            } else {
                releasedSince[app] = released
            }
        }
    }

    private func currentCall(now: Date) -> Call? {
        holdingSince
            .filter { app, since in
                // Before the start debounce elapses, a brief grab doesn't
                // count; after it, the call lasts until `observe` drops it.
                let heldFor = (releasedSince[app] ?? now).timeIntervalSince(since)
                return heldFor >= timing.startAfter
            }
            .min { $0.value < $1.value }
            .map { Call(id: "\($0.key)@\(Int($0.value.timeIntervalSince1970))", app: $0.key, start: $0.value) }
    }
}
