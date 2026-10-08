import Foundation

/// How calendar meetings or detected calls drive recording.
enum AutoRecordMode: String, Sendable {
    case off, ask, auto
}

/// Ask-mode prompt bookkeeping shared by meetings and calls: what is on
/// offer, and since when, so an unanswered prompt can expire.
struct PromptTimer<Item: Sendable>: Sendable {
    private(set) var item: Item?
    private var key: String?
    private var since = Date.distantPast

    /// Offer `item` (identified by `key`) as of `now`. Returns false — and
    /// withdraws the offer — once it has stood unanswered for `timeout`; the
    /// caller then treats the item as skipped.
    mutating func offer(_ item: Item, key: String, now: Date, timeout: TimeInterval) -> Bool {
        if key != self.key {
            self.key = key
            since = now
        }
        guard now.timeIntervalSince(since) < timeout else {
            clear()
            return false
        }
        self.item = item
        return true
    }

    mutating func clear() {
        item = nil
        key = nil
    }
}

extension Meeting {
    /// A detected call as a meeting record: no calendar, and both scheduled
    /// times are when the call was detected.
    init(call: CallDetector.Call) {
        self.init(id: call.id, title: call.title, start: call.start, end: call.start, calendar: "", videoLink: nil)
    }
}

/// Everything that decides when quill records on its own, as one pure value:
/// calendar meetings (`MeetingScheduler`), ad-hoc calls (`CallDetector`), and
/// the rules between them. The app reports what happened — a tick, a session
/// starting or stopping, a click — and carries out the one action returned.
/// Nothing here touches audio, EventKit, Core Audio, or the UI, so every rule
/// is testable with plain values.
struct RecordingPolicy: Sendable {
    /// Why the current session is recording. Only `.meeting` sessions are
    /// stopped by the scheduler and only `.call` sessions by the call
    /// detector; a manual session may still carry the meeting or call it
    /// overlaps, for its title.
    enum Origin: Equatable, Sendable {
        case manual(Meeting?)
        case meeting(Meeting)
        case call(CallDetector.Call)

        /// The meeting record the session is titled and filed under.
        var meeting: Meeting? {
            switch self {
            case .manual(let m): return m
            case .meeting(let m): return m
            case .call(let c): return Meeting(call: c)
            }
        }
    }

    enum Action: Equatable, Sendable {
        case start(Origin)
        /// Stop the current recording and immediately start the next one.
        case roll(to: Origin)
        case stop(MeetingScheduler.StopReason)
        /// Keep recording, but under this meeting's title and stop rules: an
        /// ad-hoc call turned out to be a calendar meeting.
        case retitle(Origin)
    }

    /// Ask mode: what is on offer. A due meeting always wins over a call —
    /// the call is that meeting.
    enum Prompt: Equatable, Sendable {
        case meeting(Meeting)
        case call(CallDetector.Call)

        var title: String {
            switch self {
            case .meeting(let m): return m.title
            case .call(let c): return c.title
            }
        }

        /// Stable across ticks, for "is this a new prompt?".
        var key: String {
            switch self {
            case .meeting(let m): return m.key
            case .call(let c): return c.id
            }
        }
    }

    private(set) var scheduler = MeetingScheduler(mode: .off)
    private(set) var calls = CallDetector(mode: .off)
    /// What the live session records for; nil while idle.
    private(set) var origin: Origin?
    /// A meeting app held the mic during the current session, so its letting
    /// go means the call is over.
    private var sessionHadCall = false

    var prompt: Prompt? {
        scheduler.prompting.map(Prompt.meeting) ?? calls.prompting.map(Prompt.call)
    }

    mutating func configure(meetings: AutoRecordMode, calls callMode: AutoRecordMode, timing: MeetingScheduler.Timing) {
        scheduler.mode = meetings
        scheduler.timing = timing
        calls.mode = callMode
    }

    /// One pass. `holding` names the meeting apps holding the mic; `quiet`
    /// is how long both tracks have been silent (0 while idle).
    mutating func tick(now: Date, meetings: [Meeting], holding: Set<String>, quiet: TimeInterval) -> Action? {
        let meetings = calendarMeetings(meetings)
        let current = scheduler.current(now: now, meetings: meetings)

        // An ad-hoc call recording becomes the calendar meeting once one is
        // due — the user joined early, and the meeting's title and stop
        // rules are the better fit.
        if case .call = origin, let current, !scheduler.isHandled(current) {
            scheduler.markHandled(current)
            origin = .meeting(current)
            return .retitle(.meeting(current))
        }

        // Calls first: whether a meeting app let go of the mic feeds the
        // scheduler's stop decision.
        let callRecording: CallDetector.Recording
        switch origin {
        case nil: callRecording = .idle
        case .call(let c)?: callRecording = .call(c)
        default: callRecording = .other
        }
        let callAction = calls.decide(now: now, holding: holding, recording: callRecording, meetingDue: current != nil)
        if origin != nil && calls.currentCall != nil { sessionHadCall = true }

        let recording: MeetingScheduler.Recording
        switch origin {
        case nil: recording = .idle
        case .meeting(let m)?: recording = .meeting(m)
        default: recording = .manual
        }
        let callEnded = sessionHadCall && calls.currentCall == nil
        switch scheduler.decide(now: now, meetings: meetings, recording: recording, quiet: quiet, callEnded: callEnded)
        {
        case .start(let m)?: return .start(.meeting(m))
        case .roll(let m)?: return .roll(to: .meeting(m))
        case .stop(let reason)?: return .stop(reason)
        case nil: break
        }
        // The scheduler only acts on idle or meeting recordings and the
        // detector only on idle or call recordings, so at most an idle start
        // could collide — and a due meeting suppresses the call side.
        switch callAction {
        case .start(let c)?: return .start(.call(c))
        case .stop?: return .stop(.callEnded)
        case nil: return nil
        }
    }

    /// A session began recording for `origin`.
    mutating func started(_ origin: Origin) {
        self.origin = origin
        sessionHadCall = false
    }

    /// The session ended, for whatever reason.
    mutating func stopped() {
        origin = nil
    }

    /// The user started recording by hand. The recording takes the title of
    /// the meeting or call under way, and that meeting won't trigger again —
    /// but nothing ever stops a recording the user started.
    mutating func userStarting(now: Date, meetings: [Meeting]) -> Origin {
        let current = scheduler.current(now: now, meetings: calendarMeetings(meetings))
        if let current { scheduler.markHandled(current) }
        return .manual(current ?? calls.currentCall.map(Meeting.init(call:)))
    }

    /// The user stopped recording: whatever meeting or call is under way is
    /// done, so it never comes straight back as a prompt or an auto-start.
    mutating func userStopped(now: Date, meetings: [Meeting]) {
        scheduler.userStopped(now: now, meetings: calendarMeetings(meetings))
        calls.userStopped()
    }

    /// The prompt was clicked: what to record, if anything is on offer.
    mutating func acceptPrompt() -> Origin? {
        switch prompt {
        case .meeting(let m)?:
            scheduler.markHandled(m)
            return .meeting(m)
        case .call(let c)?:
            calls.markHandled(c)
            return .call(c)
        case nil:
            return nil
        }
    }

    mutating func skipPrompt() {
        switch prompt {
        case .meeting(let m)?: scheduler.markHandled(m)
        case .call(let c)?: calls.markHandled(c)
        case nil: break
        }
    }

    /// The next meeting not yet handled, for the menu.
    func upcoming(now: Date, meetings: [Meeting]) -> Meeting? {
        scheduler.upcoming(now: now, meetings: calendarMeetings(meetings))
    }

    /// With calendar recording off, meetings neither start nor title
    /// anything (the list may be stale from before it was turned off).
    private func calendarMeetings(_ meetings: [Meeting]) -> [Meeting] {
        scheduler.mode == .off ? [] : meetings
    }
}
