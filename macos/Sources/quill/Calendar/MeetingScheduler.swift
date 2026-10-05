import Foundation

/// One calendar meeting quill may record. `id` is unique per occurrence —
/// recurring events share an EventKit identifier, so the start time is part
/// of it.
struct Meeting: Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var videoLink: URL?
}

/// The raw fields of a calendar event, decoupled from EventKit so selection
/// is testable without a calendar database.
struct CalendarEntry: Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var isAllDay = false
    var isCanceled = false
    var declined = false
    var url: URL?
    var location: String?
    var notes: String?
}

/// Which calendar events count as meetings. By default only events carrying a
/// video-call link qualify, so focus blocks, lunches, and reminders are never
/// recorded.
struct MeetingFilter: Sendable {
    var requireVideoLink = true
    var ignoredCalendars: Set<String> = []
    /// Longer events are treated like all-day blocks (offsites, OOO).
    var maxDuration: TimeInterval = 8 * 3600

    private static let videoHosts = [
        "zoom.us", "zoomgov.com", "teams.microsoft.com", "teams.live.com", "meet.google.com",
        "webex.com", "gotomeeting.com", "meet.goto.com", "whereby.com", "chime.aws",
        "bluejeans.com", "around.co", "facetime.apple.com", "app.slack.com",
    ]
    private static let linkPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)

    func meetings(from entries: [CalendarEntry]) -> [Meeting] {
        var seen = Set<String>()
        var result: [Meeting] = []
        for e in entries.sorted(by: { $0.start < $1.start }) {
            guard !e.isAllDay, !e.isCanceled, !e.declined, e.end > e.start,
                e.end.timeIntervalSince(e.start) <= maxDuration,
                !ignoredCalendars.contains(e.calendar)
            else { continue }
            let link = Self.videoLink(in: e)
            if requireVideoLink && link == nil { continue }
            // The same invite often appears on two calendars (work + a
            // delegate or shared calendar); record it once.
            guard seen.insert("\(e.title)|\(e.start.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)").inserted
            else { continue }
            result.append(
                Meeting(id: e.id, title: e.title, start: e.start, end: e.end, calendar: e.calendar, videoLink: link))
        }
        return result
    }

    /// The first video-call link in the event's URL, location, or notes.
    static func videoLink(in entry: CalendarEntry) -> URL? {
        let candidates = [entry.url?.absoluteString, entry.location, entry.notes].compactMap { $0 }
        for text in candidates {
            let range = NSRange(text.startIndex..., in: text)
            for match in linkPattern.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text), let url = URL(string: String(text[r])),
                    let host = url.host?.lowercased()
                else { continue }
                if videoHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }
}

/// Decides when calendar meetings start and stop recordings. Pure: the app
/// feeds it the current meetings, what is recording, and how long both tracks
/// have been quiet; it returns what to do. Each meeting triggers at most once —
/// after it starts, is dismissed, or is stopped by hand it is `handled`, so
/// stopping an auto-recording never restarts it on the next tick.
struct MeetingScheduler: Sendable {
    enum Mode: String, Sendable, CaseIterable {
        case off, ask, auto
    }

    enum Recording: Equatable, Sendable {
        case idle
        /// Started by hand: never auto-stopped.
        case manual
        /// Started for a meeting (automatically or from the prompt).
        case meeting(Meeting)
    }

    enum StopReason: Equatable, Sendable {
        /// The scheduled end passed and the call went quiet.
        case ended
        /// Nothing audible on either track for a long stretch.
        case quiet
        /// The meeting ran far past its scheduled end.
        case overrun
        /// The next meeting began (ask mode prompts for it next).
        case nextMeeting
        /// The meeting app that carried the call let go of the mic.
        case callEnded

        var label: String {
            switch self {
            case .ended: return "meeting ended"
            case .quiet: return "no audio for 10 minutes"
            case .overrun: return "meeting ran an hour over"
            case .nextMeeting: return "next meeting started"
            case .callEnded: return "call ended"
            }
        }
    }

    enum Action: Equatable, Sendable {
        case start(Meeting)
        /// Stop the current recording and immediately start the next one.
        case roll(to: Meeting)
        case stop(StopReason)
    }

    struct Timing: Sendable {
        /// Start this long before the scheduled start.
        var lead: TimeInterval = 60
        /// After the scheduled end, stop once both tracks are quiet this long.
        var quietAfterEnd: TimeInterval = 120
        /// Stop at any point after this long without audio.
        var quietAnytime: TimeInterval = 600
        /// Hard stop this long after the scheduled end.
        var maxOverrun: TimeInterval = 3600
    }

    var mode: Mode
    var timing = Timing()
    private(set) var handled: Set<String> = []
    /// Ask mode: the meeting currently offered for recording.
    private(set) var prompting: Meeting?

    init(mode: Mode, timing: Timing = Timing()) {
        self.mode = mode
        self.timing = timing
    }

    mutating func markHandled(_ meeting: Meeting) {
        handled.insert(meeting.id)
        if prompting?.id == meeting.id { prompting = nil }
    }

    /// One scheduling pass. `quiet` is how long both tracks have been below
    /// the activity threshold (0 when idle). `callEnded` is true once a
    /// meeting app that held the mic during this recording has let go for
    /// good — the clearest sign the meeting is over, even before its
    /// scheduled end.
    mutating func decide(
        now: Date, meetings: [Meeting], recording: Recording, quiet: TimeInterval, callEnded: Bool = false
    ) -> Action? {
        guard mode != .off else {
            prompting = nil
            return nil
        }
        switch recording {
        case .idle:
            let due = dueMeeting(now: now, meetings: meetings)
            if mode == .ask {
                prompting = due
                return nil
            }
            prompting = nil
            guard let due else { return nil }
            handled.insert(due.id)
            return .start(due)

        case .manual:
            prompting = nil
            return nil

        case .meeting(let current):
            prompting = nil
            // Back-to-back meetings: hand over once the current one is past
            // its scheduled end and the next has begun. An overlapping
            // meeting never interrupts one still in its slot.
            if now >= current.end,
                let next = meetings.last(where: {
                    $0.id != current.id && !handled.contains($0.id) && $0.start <= now && now < $0.end
                })
            {
                guard mode == .auto else { return .stop(.nextMeeting) }
                handled.insert(next.id)
                return .roll(to: next)
            }
            if callEnded { return .stop(.callEnded) }
            if now >= current.end.addingTimeInterval(timing.maxOverrun) { return .stop(.overrun) }
            if now >= current.end && quiet >= timing.quietAfterEnd { return .stop(.ended) }
            if quiet >= timing.quietAnytime { return .stop(.quiet) }
            return nil
        }
    }

    /// The unhandled meeting whose window (lead included) contains `now`.
    /// With overlaps, the most recently started wins — it is the more
    /// specific event (a call inside a longer block).
    private func dueMeeting(now: Date, meetings: [Meeting]) -> Meeting? {
        meetings
            .filter { !handled.contains($0.id) && $0.start.addingTimeInterval(-timing.lead) <= now && now < $0.end }
            .max { $0.start < $1.start }
    }

    /// The next meeting that hasn't ended or been handled, for the menu.
    func upcoming(now: Date, meetings: [Meeting]) -> Meeting? {
        meetings.first { !handled.contains($0.id) && $0.end > now }
    }
}
