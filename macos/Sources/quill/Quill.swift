import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(
            Data(
                "quill up · recordings → \(root.path) · ^C to quit\n".utf8
            ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the floating indicator, the current recording session,
/// the calendar scheduler, the ad-hoc call detector, and the elapsed-time
/// ticker. All state transitions
/// happen on the main actor.
@MainActor
final class AppController {
    /// Why the current session is recording. Only `.meeting` sessions are
    /// stopped by the scheduler and only `.call` sessions by the call
    /// detector; a manual session may still carry the meeting or call it
    /// overlaps, for its title.
    private enum Origin {
        case manual(Meeting?)
        case meeting(Meeting)
        case call(CallDetector.Call)

        var meeting: Meeting? {
            switch self {
            case .manual(let m): return m
            case .meeting(let m): return m
            case .call(let c): return AppController.meeting(for: c)
            }
        }
    }

    private let root: URL
    private let menuBar = MenuBarController()
    private let indicator = RecordingIndicator()
    private let calendar = MeetingCalendar()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var origin = Origin.manual(nil)
    private var captureStatus = RecordingSession.CaptureStatus.allHealthy
    private var ticker: Timer?
    private var scheduler = MeetingScheduler(mode: Config.calendarMode(), timing: Config.calendarTiming())
    private var meetings: [Meeting] = []
    private var meetingsFetchedAt = Date.distantPast
    private var calendarTimer: Timer?
    private var requestedCalendarAccess = false
    private let micUsage = MicUsageMonitor()
    private var calls = CallDetector(mode: Config.adhocCallMode())
    /// A meeting app held the mic at some point during the current session,
    /// so its letting go means the call is over.
    private var sessionHadCall = false
    /// "Hide until next recording" from the indicator's menu.
    private var indicatorSuppressed = false

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onModeChange = { [weak self] in self?.setCalendarMode($0) }
        menuBar.update(.idle)

        indicator.levelSource = { [weak self] in self?.session?.levels() ?? [:] }
        indicator.menuProvider = { [weak self] state in self?.indicatorMenu(state) ?? NSMenu() }
        calendar.onChange = { [weak self] in self?.reloadMeetings() }
        micUsage.onChange = { [weak self] in self?.calendarTick() }

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }

        // A meeting can start at any moment; a 2 s pass over the cached
        // meeting list costs nothing. .common so it keeps running while a
        // menu is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        calendarTimer = timer
        calendarTick()
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        calendarTimer?.invalidate()
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            // A hand-started recording during a meeting takes the meeting's
            // title, and the meeting won't trigger again — but the scheduler
            // never stops a recording the user started.
            let current = currentMeeting()
            if let current { scheduler.markHandled(current) }
            startSession(.manual(current ?? calls.currentCall.map(Self.meeting(for:))))
        } else {
            stopSession()
        }
    }

    private func startSession(_ origin: Origin) {
        do {
            let newSession = try RecordingSession(root: root)
            newSession.meeting = origin.meeting.map(Self.metaMeeting)
            newSession.onStatus = { [weak self] status in
                self?.captureStatus = status
                self?.refreshMenu()
            }
            newSession.onDegraded = { kind in
                // The session fires this once per degradation episode, so the
                // user gets one notification, not one per watchdog tick.
                notifyUser(
                    title: "quill — \(kind.label) capture lost",
                    body: "Recovery failed; the recording will be marked incomplete."
                )
            }
            try newSession.start()
            session = newSession
            self.origin = origin
            captureStatus = .allHealthy
            indicatorSuppressed = false
            sessionHadCall = false
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        refreshMenu()
        // Explicitly .common so the elapsed counter and menu state keep
        // updating while the menu is open (event-tracking run-loop mode).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopSession() {
        guard let session else { return }
        let result = session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(
            Data(
                "○ stopped · \(elapsed) · \(result.status.rawValue) · \(session.dir.path)\n".utf8
            ))
        self.session = nil
        origin = .manual(nil)
        captureStatus = .allHealthy
        ticker?.invalidate()
        ticker = nil
        menuBar.update(.idle)
        updateIndicator()

        // Warn about a gap before the later "transcript ready" notification
        // implies everything went fine. Transcription still runs — recovered
        // and incomplete sessions keep whatever audio they have.
        switch result.status {
        case .complete:
            break
        case .recovered:
            notifyUser(
                title: "quill — recording recovered",
                body: "Capture was interrupted and resumed; see meta.json for the gap."
            )
        case .incomplete:
            notifyUser(
                title: "quill — recording incomplete",
                body: "Part of the session was not captured; see meta.json."
            )
        }
        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Rebuild the menu presentation from capture status plus elapsed time.
    private func refreshMenu() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        let display: MenuBarController.Display
        switch captureStatus.display {
        case .healthy:
            display = .recording(elapsed: elapsed)
        case .recovering(let kind):
            display = .recovering(track: kind.label, elapsed: elapsed)
        case .degraded(let kind):
            display = .degraded(track: kind.label, elapsed: elapsed)
        }
        menuBar.update(display, signalWarning: captureStatus.signalWarning, meetingTitle: origin.meeting?.title)
        updateIndicator()
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        refreshMenu()
    }

    // MARK: - Calendar

    /// One scheduling pass: keep the meeting list fresh, then let the
    /// scheduler start, roll, or stop a meeting recording. Config is re-read
    /// every pass, so edits to config.json apply without a restart.
    private func calendarTick() {
        let mode = Config.calendarMode()
        scheduler.mode = mode
        scheduler.timing = Config.calendarTiming()

        if mode != .off {
            switch MeetingCalendar.access() {
            case .notDetermined:
                if !requestedCalendarAccess {
                    requestedCalendarAccess = true
                    calendar.requestAccess { [weak self] _ in self?.reloadMeetings() }
                }
            case .denied:
                meetings = []
            case .granted:
                if Date().timeIntervalSince(meetingsFetchedAt) > 60 { reloadMeetings() }
            }
        }

        let now = Date()
        // An ad-hoc call recording becomes the calendar meeting once one is
        // due — the user joined early, and the meeting's title and stop
        // rules are the better fit.
        if session != nil, case .call = origin, let due = currentMeeting(), !scheduler.handled.contains(due.id) {
            scheduler.markHandled(due)
            origin = .meeting(due)
            session?.meeting = Self.metaMeeting(due)
        }

        // Calls first: whether a meeting app let go of the mic feeds the
        // scheduler's stop decision.
        calls.mode = Config.adhocCallMode()
        let callRecording: CallDetector.Recording
        switch (session, origin) {
        case (nil, _): callRecording = .idle
        case (_, .call(let c)): callRecording = .call(c)
        default: callRecording = .other
        }
        let wasCallPrompt = calls.prompting
        let callAction = calls.decide(
            now: now,
            holding: micUsage.holdingApps(includeBrowsers: Config.browserCalls()),
            recording: callRecording,
            meetingDue: currentMeeting() != nil
        )
        if session != nil && calls.currentCall != nil { sessionHadCall = true }
        let callEnded = sessionHadCall && calls.currentCall == nil

        let recording: MeetingScheduler.Recording
        switch (session, origin) {
        case (nil, _): recording = .idle
        case (_, .meeting(let m)): recording = .meeting(m)
        default: recording = .manual
        }
        let quiet = session.map { TimeInterval($0.quietMs()) / 1000 } ?? 0
        let wasPrompting = scheduler.prompting

        let action = scheduler.decide(
            now: now, meetings: meetings, recording: recording, quiet: quiet, callEnded: callEnded)
        switch action {
        case .start(let meeting)?:
            startSession(.meeting(meeting))
            if session != nil {
                notifyUser(title: "quill — recording “\(meeting.title)”", body: "Click the floating feather to stop.")
            }
        case .roll(let meeting)?:
            stopSession()
            startSession(.meeting(meeting))
        case .stop(let reason)?:
            let title = origin.meeting?.title ?? "meeting"
            stopSession()
            let next = Config.transcriptionEnabled() ? " · transcribing now." : "."
            notifyUser(title: "quill — stopped “\(title)”", body: reason.label.capitalizedFirst + next)
        case nil:
            break
        }

        // The two never both act on one pass (a call action needs an idle or
        // call recording the scheduler leaves alone); the guard keeps it so.
        switch action == nil ? callAction : nil {
        case .start(let call)?:
            startSession(.call(call))
            if session != nil {
                notifyUser(title: "quill — recording “\(call.title)”", body: "Click the floating feather to stop.")
            }
        case .stop?:
            let title = origin.meeting?.title ?? "call"
            stopSession()
            let next = Config.transcriptionEnabled() ? " · transcribing now." : "."
            notifyUser(title: "quill — stopped “\(title)”", body: "Call ended" + next)
        case nil:
            break
        }

        if let prompt = scheduler.prompting, prompt.id != wasPrompting?.id {
            notifyUser(title: "quill — “\(prompt.title)” is starting", body: "Click the floating feather to record it.")
        }
        if scheduler.prompting == nil, let call = calls.prompting, call.id != wasCallPrompt?.id {
            notifyUser(title: "quill — \(call.title) detected", body: "Click the floating feather to record it.")
        }
        refreshCalendarMenu(mode: mode)
        updateIndicator()
    }

    private func reloadMeetings() {
        meetings = Config.calendarFilter().meetings(from: calendar.entries())
        meetingsFetchedAt = Date()
    }

    private func setCalendarMode(_ mode: MeetingScheduler.Mode) {
        do {
            try Config.setCalendarMode(mode)
        } catch {
            notifyUser(title: "quill — couldn't save setting", body: "\(error)")
            return
        }
        meetingsFetchedAt = .distantPast
        calendarTick()
    }

    /// The meeting in progress right now (lead time included), if any.
    private func currentMeeting() -> Meeting? {
        guard scheduler.mode != .off else { return nil }
        let now = Date()
        return meetings.filter { $0.start.addingTimeInterval(-scheduler.timing.lead) <= now && now < $0.end }
            .max { $0.start < $1.start }
    }

    private func refreshCalendarMenu(mode: MeetingScheduler.Mode) {
        let detail: String?
        if mode == .off {
            detail = nil
        } else {
            switch MeetingCalendar.access() {
            case .notDetermined:
                detail = "calendar · waiting for access"
            case .denied:
                detail = "calendar · access denied (System Settings → Privacy & Security → Calendars)"
            case .granted:
                if let next = scheduler.upcoming(now: Date(), meetings: meetings) {
                    detail = "next · \(next.title) · \(Self.meetingTime(next.start))"
                } else {
                    detail = "calendar · no upcoming meetings"
                }
            }
        }
        menuBar.updateCalendar(mode: mode, detail: detail)
    }

    // MARK: - Floating indicator

    private func updateIndicator() {
        guard Config.floatingIndicator() else {
            indicator.update(.hidden)
            return
        }
        if session != nil {
            indicator.update(indicatorSuppressed ? .hidden : .recording(warning: captureStatus.display != .healthy))
        } else if scheduler.prompting != nil || calls.prompting != nil {
            indicator.update(.prompt)
        } else {
            indicator.update(.hidden)
        }
    }

    private func indicatorMenu(_ state: RecordingIndicator.State) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        switch state {
        case .prompt:
            guard let meeting = scheduler.prompting else {
                guard let call = calls.prompting else { return menu }
                header("\(call.title) · since \(Self.meetingTime(call.start))")
                menu.addItem(.separator())
                menu.addItem(
                    ActionMenuItem("Record this call") { [weak self] in
                        guard let self, self.session == nil else { return }
                        self.calls.markHandled(call)
                        self.startSession(.call(call))
                    })
                menu.addItem(
                    ActionMenuItem("Skip this call") { [weak self] in
                        self?.calls.markHandled(call)
                        self?.updateIndicator()
                    })
                break
            }
            header("\(meeting.title) · \(Self.meetingTime(meeting.start))")
            menu.addItem(.separator())
            menu.addItem(
                ActionMenuItem("Record this meeting") { [weak self] in
                    guard let self, self.session == nil else { return }
                    self.scheduler.markHandled(meeting)
                    self.startSession(.meeting(meeting))
                })
            menu.addItem(
                ActionMenuItem("Skip this meeting") { [weak self] in
                    self?.scheduler.markHandled(meeting)
                    self?.updateIndicator()
                })
        case .recording:
            if let session {
                let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
                header("● \(origin.meeting?.title ?? "recording") · \(elapsed)")
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Stop recording") { [weak self] in self?.stopSession() })
            menu.addItem(
                ActionMenuItem("Hide until next recording") { [weak self] in
                    self?.indicatorSuppressed = true
                    self?.updateIndicator()
                })
        case .hidden:
            return menu
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Open recordings folder") { [weak self] in self?.openFolder() })
        return menu
    }

    // MARK: -

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// A detected call as a meeting record: no calendar, and both scheduled
    /// times are when the call was detected.
    nonisolated fileprivate static func meeting(for call: CallDetector.Call) -> Meeting {
        Meeting(id: call.id, title: call.title, start: call.start, end: call.start, calendar: "", videoLink: nil)
    }

    private static func metaMeeting(_ m: Meeting) -> SessionMeta.Meeting {
        let iso = ISO8601DateFormatter()
        return SessionMeta.Meeting(
            title: m.title,
            calendar: m.calendar,
            scheduled_start: iso.string(from: m.start),
            scheduled_end: iso.string(from: m.end),
            video_link: m.videoLink?.absoluteString
        )
    }

    /// "10:30 AM" today, "Tue 10:30 AM" otherwise.
    private static func meetingTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let time = f.string(from: date)
        guard !Calendar.current.isDateInToday(date) else { return time }
        f.setLocalizedDateFormatFromTemplate("EEE")
        return "\(f.string(from: date)) \(time)"
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
