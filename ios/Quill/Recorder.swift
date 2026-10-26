import ActivityKit
import AVFoundation
import Foundation
import Observation
import QuillKit
import UIKit

/// Records the microphone into a session folder the Mac can transcribe. There
/// is one recorder: the screen, the Action Button intent, and the Live
/// Activity's Stop button all drive this instance.
///
/// A phone call or Siri takes the microphone mid-recording. The segment in
/// progress is closed there, and when the microphone comes back a new one
/// opens at its true offset on the session clock (`CaptureTimeline`).
@MainActor @Observable
final class Recorder {
    static let shared = Recorder()

    enum State: Equatable {
        case idle
        case recording(since: Date)
        /// Another app has the microphone; recording resumes when it's back.
        case paused(since: Date)
    }

    private(set) var state: State = .idle
    /// Why the last start or stop didn't go as asked, for the screen.
    private(set) var problem: Problem?
    /// Recent input levels (0...1), oldest first, for the live meter.
    private(set) var levels = [Float](repeating: 0, count: Recorder.meterBars)
    static let meterBars = 40
    private var meterTimer: Timer?
    let library = Library()

    enum Problem: Equatable {
        case micDenied
        case failed(String)
    }

    private struct Live {
        var dir: URL
        var startedAt: Date
        var clockStart: ContinuousClock.Instant
        var timeline = CaptureTimeline()
        var file: AVAudioRecorder?
        var activityID: String?

        var elapsedMs: Int { Int((ContinuousClock.now - clockStart) / .milliseconds(1)) }
    }

    private var live: Live?

    /// AAC in CAF, mono, like the Mac's mic track.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                switch raw.flatMap(AVAudioSession.InterruptionType.init) {
                case .began?: self?.pause()
                case .ended?: self?.resume()
                default: break
                }
            }
        }
        library.recoverUnfinished()
        Task { await library.sendFinished() }
    }

    var isRecording: Bool { state != .idle }

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
        guard live == nil else { return }
        problem = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = .micDenied
            return
        }
        let startedAt = Date()
        var dir: URL?
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
            dir = try library.newSessionFolder(startedAt: startedAt)
            var session = Live(dir: dir!, startedAt: startedAt, clockStart: .now)
            try openSegment(&session)
            session.activityID = startActivity(startedAt: startedAt)
            live = session
            state = .recording(since: startedAt)
            startMeter()
        } catch {
            if let dir { try? FileManager.default.removeItem(at: dir) }
            try? AVAudioSession.sharedInstance().setActive(false)
            problem = .failed("Couldn't start recording. \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard var session = live else { return }
        session.file?.stop()
        session.timeline.finish(atMs: session.elapsedMs)
        let manifest = SessionManifest(
            started: session.startedAt, ended: Date(), timeline: session.timeline,
            audio: { Library.audio(of: session.dir.appendingPathComponent($0)) })
        do {
            try manifest.write(to: session.dir)
        } catch {
            problem = .failed("Couldn't save the recording. \(error.localizedDescription)")
        }
        live = nil
        stopMeter()
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let id = session.activityID { await Self.endActivity(id: id) }
        await library.sendFinished()
    }

    /// The app came to the foreground: retry a resume the system refused,
    /// and send anything still waiting for iCloud.
    func becameActive() async {
        // Back from Settings with the microphone allowed.
        if problem == .micDenied, AVAudioApplication.shared.recordPermission == .granted { problem = nil }
        if case .paused = state { resume() }
        if live == nil { await library.sendFinished() }
    }

    // MARK: - Segments and interruptions

    /// Start writing the next segment file. The timeline records it only once
    /// audio is actually being written.
    private func openSegment(_ session: inout Live) throws {
        let name = CaptureTimeline.fileName(index: session.timeline.spans.count + 1)
        let file = try AVAudioRecorder(url: session.dir.appendingPathComponent(name), settings: Self.settings)
        file.isMeteringEnabled = true
        guard file.prepareToRecord() else { throw RecorderError.micDidNotStart }
        // Session time zero is when the first audio is written, not when the
        // button was pressed — the recorder can take seconds to spin up, and
        // that delay would shift every transcript timestamp.
        if session.timeline.spans.isEmpty { session.clockStart = .now }
        guard file.record() else { throw RecorderError.micDidNotStart }
        _ = session.timeline.openSegment(atMs: session.elapsedMs)
        session.file = file
    }

    private func pause() {
        guard var session = live, case .recording(let since) = state else { return }
        session.file?.stop()
        session.file = nil
        session.timeline.interrupt(atMs: session.elapsedMs, reason: "audio session interrupted")
        live = session
        state = .paused(since: since)
        updateActivity(paused: true)
    }

    private func resume() {
        guard var session = live, case .paused(let since) = state else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try openSegment(&session)
            state = .recording(since: since)
            updateActivity(paused: false)
        } catch {
            session.timeline.resumeFailed(error.localizedDescription)
        }
        live = session
    }

    // MARK: - Level meter

    private func startMeter() {
        levels = [Float](repeating: 0, count: Self.meterBars)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLevel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// Nobody sees the meter in the background, so don't redraw it there.
    private func sampleLevel() {
        guard UIApplication.shared.applicationState == .active else { return }
        var level: Float = 0
        if let file = live?.file {
            file.updateMeters()
            level = Format.level(decibels: file.averagePower(forChannel: 0))
        }
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: - Live Activity

    /// Activity isn't Sendable, so only its ID leaves this file's helpers;
    /// each async call looks the activity up again off the main actor.
    private func startActivity(startedAt: Date) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let state = RecordingActivityAttributes.ContentState(startedAt: startedAt, paused: false)
        return try? Activity.request(
            attributes: RecordingActivityAttributes(), content: ActivityContent(state: state, staleDate: nil)
        ).id
    }

    private func updateActivity(paused: Bool) {
        guard let session = live, let id = session.activityID else { return }
        let state = RecordingActivityAttributes.ContentState(startedAt: session.startedAt, paused: paused)
        Task { await Self.updateActivity(id: id, state: state) }
    }

    private nonisolated static func activity(id: String) -> Activity<RecordingActivityAttributes>? {
        Activity<RecordingActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func updateActivity(
        id: String, state: RecordingActivityAttributes.ContentState
    ) async {
        await activity(id: id)?.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func endActivity(id: String) async {
        await activity(id: id)?.end(nil, dismissalPolicy: .immediate)
    }
}

enum RecorderError: LocalizedError {
    case micDidNotStart

    var errorDescription: String? {
        switch self {
        case .micDidNotStart: return "The microphone didn't start."
        }
    }
}
