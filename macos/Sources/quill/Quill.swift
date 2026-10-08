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
/// and the elapsed-time ticker, and carries out what `RecordingPolicy`
/// decides. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private typealias Origin = RecordingPolicy.Origin

    private let root: URL
    private let menuBar = MenuBarController()
    private let indicator = RecordingIndicator()
    private let calendar = MeetingCalendar()
    private let micUsage = MicUsageMonitor()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var policy = RecordingPolicy()
    private var captureStatus = RecordingSession.CaptureStatus.allHealthy
    private var ticker: Timer?
    private var meetings: [Meeting] = []
    private var meetingsFetchedAt = Date.distantPast
    private var reloadPending = false
    private var calendarTimer: Timer?
    private var requestedCalendarAccess = false
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
        indicator.menuProvider = { [weak self] in self?.recordingMenu() ?? NSMenu() }
        indicator.onRecord = { [weak self] in self?.acceptPrompt() }
        indicator.onSkip = { [weak self] in self?.skipPrompt() }
        calendar.onChange = { [weak self] in self?.scheduleReload() }
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
            startSession(policy.userStarting(now: Date(), meetings: meetings))
        } else {
            userStop()
        }
    }

    /// A stop the user asked for (menu bar or capsule).
    private func userStop() {
        stopSession()
        policy.userStopped(now: Date(), meetings: meetings)
        updateIndicator()
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
            policy.started(origin)
            captureStatus = .allHealthy
            indicatorSuppressed = false
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
        policy.stopped()
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
        menuBar.update(display, signalWarning: captureStatus.signalWarning, meetingTitle: sessionTitle)
        updateIndicator()
    }

    private var sessionTitle: String? { policy.origin?.meeting?.title }

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

    // MARK: - Calendar and calls

    /// One pass: keep the meeting list fresh, feed the policy a snapshot,
    /// and carry out its action. Config is re-read every pass, so edits to
    /// config.json apply without a restart.
    private func calendarTick() {
        let mode = Config.calendarMode()
        let callMode = Config.adhocCallMode()
        policy.configure(meetings: mode, calls: callMode, timing: Config.calendarTiming())

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
                // EKEventStoreChanged covers edits; the slow refetch only
                // moves the 24 h window forward.
                if Date().timeIntervalSince(meetingsFetchedAt) > 600 { reloadMeetings() }
            }
        }

        // The mic scan is the one costly input; skip it when nothing would
        // use it (no call detection and no recording to end).
        let holding =
            callMode == .off && session == nil
            ? [] : micUsage.holdingApps(includeBrowsers: Config.browserCalls())
        let quiet = session.map { TimeInterval($0.quietMs()) / 1000 } ?? 0
        let previousPrompt = policy.prompt

        switch policy.tick(now: Date(), meetings: meetings, holding: holding, quiet: quiet) {
        case .start(let origin)?:
            startSession(origin)
            if session != nil, let title = origin.meeting?.title {
                notifyUser(title: "quill — recording “\(title)”", body: "Click the floating feather to stop.")
            }
        case .roll(let origin)?:
            stopSession()
            startSession(origin)
        case .stop(let reason)?:
            let title = sessionTitle ?? "recording"
            stopSession()
            let next = Config.transcriptionEnabled() ? " · transcribing now." : "."
            notifyUser(title: "quill — stopped “\(title)”", body: reason.label.capitalizedFirst + next)
        case .retitle(let origin)?:
            session?.meeting = origin.meeting.map(Self.metaMeeting)
        case nil:
            break
        }

        if let prompt = policy.prompt, prompt.key != previousPrompt?.key {
            switch prompt {
            case .meeting(let m):
                notifyUser(title: "quill — “\(m.title)” is starting", body: "Click the floating prompt to record it.")
            case .call(let c):
                notifyUser(title: "quill — \(c.title) detected", body: "Click the floating prompt to record it.")
            }
        }
        refreshCalendarMenu(mode: mode)
        updateIndicator()
    }

    /// Calendar syncs post EKEventStoreChanged in bursts; refetch once per
    /// burst, and not at all while meetings are off.
    private func scheduleReload() {
        guard !reloadPending, Config.calendarMode() != .off else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                self?.reloadMeetings()
            }
        }
    }

    private func reloadMeetings() {
        meetings = Config.calendarFilter().meetings(from: calendar.entries())
        meetingsFetchedAt = Date()
    }

    private func setCalendarMode(_ mode: AutoRecordMode) {
        do {
            try Config.setCalendarMode(mode)
        } catch {
            notifyUser(title: "quill — couldn't save setting", body: "\(error)")
            return
        }
        meetingsFetchedAt = .distantPast
        calendarTick()
    }

    private func refreshCalendarMenu(mode: AutoRecordMode) {
        let detail: String?
        if mode == .off {
            detail = nil
        } else {
            switch MeetingCalendar.access() {
            case .notDetermined:
                detail = "calendar · waiting for access"
            case .denied:
                detail = "calendar · access denied (\(MeetingCalendar.settingsPath))"
            case .granted:
                if let next = policy.upcoming(now: Date(), meetings: meetings) {
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
        } else if let prompt = policy.prompt {
            indicator.update(.prompt(title: prompt.title))
        } else {
            indicator.update(.hidden)
        }
    }

    private func acceptPrompt() {
        guard session == nil, let origin = policy.acceptPrompt() else { return }
        startSession(origin)
        updateIndicator()
    }

    private func skipPrompt() {
        policy.skipPrompt()
        updateIndicator()
    }

    private func recordingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let session {
            let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
            let header = NSMenuItem(
                title: "● \(sessionTitle ?? "recording") · \(elapsed)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Stop recording") { [weak self] in self?.userStop() })
        menu.addItem(
            ActionMenuItem("Hide until next recording") { [weak self] in
                self?.indicatorSuppressed = true
                self?.updateIndicator()
            })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Open recordings folder") { [weak self] in self?.openFolder() })
        return menu
    }

    // MARK: -

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    /// "10:30 AM" today, "Tue 10:30 AM" otherwise.
    private static func meetingTime(_ date: Date) -> String {
        let time = timeFormatter.string(from: date)
        guard !Calendar.current.isDateInToday(date) else { return time }
        return "\(weekdayFormatter.string(from: date)) \(time)"
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
