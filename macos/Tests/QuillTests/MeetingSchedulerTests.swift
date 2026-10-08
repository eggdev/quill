import XCTest

@testable import quill

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private func meeting(_ id: String, _ start: Double, _ end: Double) -> Meeting {
    Meeting(id: id, title: id, start: at(start), end: at(end), calendar: "Work", videoLink: nil)
}

private func entry(
    _ id: String, notes: String? = "https://teams.microsoft.com/l/meetup-join/abc", start: Double = 0,
    end: Double = 30
) -> CalendarEntry {
    CalendarEntry(id: id, title: id, start: at(start), end: at(end), calendar: "Work", notes: notes)
}

final class MeetingFilterTests: XCTestCase {
    func testRequiresVideoLinkByDefault() {
        let result = MeetingFilter().meetings(from: [entry("call"), entry("focus", notes: "heads down")])
        XCTAssertEqual(result.map(\.id), ["call"])
        XCTAssertEqual(result[0].videoLink?.host, "teams.microsoft.com")
    }

    func testVideoLinkOptional() {
        var filter = MeetingFilter()
        filter.requireVideoLink = false
        XCTAssertEqual(filter.meetings(from: [entry("in-person", notes: nil)]).count, 1)
    }

    func testSkipsAllDayCanceledDeclinedAndIgnoredCalendars() {
        var allDay = entry("all-day")
        allDay.isAllDay = true
        var canceled = entry("canceled")
        canceled.isCanceled = true
        var declined = entry("declined")
        declined.declined = true
        var ignored = entry("birthday")
        ignored.calendar = "Birthdays"
        let offsite = entry("offsite", end: 10 * 60)
        var filter = MeetingFilter()
        filter.ignoredCalendars = ["Birthdays"]
        XCTAssertTrue(filter.meetings(from: [allDay, canceled, declined, ignored, offsite]).isEmpty)
    }

    func testDedupesSameInviteOnTwoCalendars() {
        var shared = entry("sync")
        shared.id = "other-calendar-copy"
        shared.calendar = "Shared"
        XCTAssertEqual(MeetingFilter().meetings(from: [entry("sync"), shared]).count, 1)
    }

    func testRecognizesVideoHostsOnly() {
        let zoom = CalendarEntry(
            id: "z", title: "z", start: t0, end: at(30), calendar: "Work", location: "https://acme.zoom.us/j/123")
        XCTAssertEqual(MeetingFilter.videoLink(in: zoom)?.host, "acme.zoom.us")
        let lookalike = CalendarEntry(
            id: "x", title: "x", start: t0, end: at(30), calendar: "Work", notes: "see https://notzoom.us/j/1")
        XCTAssertNil(MeetingFilter.videoLink(in: lookalike))
    }
}

final class MeetingSchedulerTests: XCTestCase {
    func testAutoStartsWithinLeadTimeOnce() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 10, 40)
        XCTAssertNil(s.decide(now: at(8), meetings: [m], recording: .idle, quiet: 0))
        XCTAssertEqual(s.decide(now: at(9.5), meetings: [m], recording: .idle, quiet: 0), .start(m))
        // Stopped by hand later: never restarts.
        XCTAssertNil(s.decide(now: at(20), meetings: [m], recording: .idle, quiet: 0))
    }

    func testStartsMeetingAlreadyUnderWay() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 0, 60)
        XCTAssertEqual(s.decide(now: at(25), meetings: [m], recording: .idle, quiet: 0), .start(m))
    }

    func testOffDoesNothing() {
        var s = MeetingScheduler(mode: .off)
        let m = meeting("a", 0, 30)
        XCTAssertNil(s.decide(now: at(5), meetings: [m], recording: .idle, quiet: 0))
        XCTAssertNil(s.decide(now: at(40), meetings: [m], recording: .meeting(m), quiet: 999))
    }

    func testAskPromptsUntilHandledOrOver() {
        var s = MeetingScheduler(mode: .ask)
        let m = meeting("a", 0, 30)
        XCTAssertNil(s.decide(now: at(0), meetings: [m], recording: .idle, quiet: 0))
        XCTAssertEqual(s.prompting, m)
        s.markHandled(m)
        XCTAssertNil(s.prompting)
        _ = s.decide(now: at(1), meetings: [m], recording: .idle, quiet: 0)
        XCTAssertNil(s.prompting)

        var expired = MeetingScheduler(mode: .ask)
        _ = expired.decide(now: at(0), meetings: [m], recording: .idle, quiet: 0)
        _ = expired.decide(now: at(30), meetings: [m], recording: .idle, quiet: 0)
        XCTAssertNil(expired.prompting)
    }

    func testManualRecordingIsNeverStopped() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 0, 30)
        XCTAssertNil(s.decide(now: at(200), meetings: [m], recording: .manual, quiet: 9999))
    }

    func testStopsAfterEndOnceQuiet() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 0, 30)
        // Quiet before the scheduled end is a pause, not the end.
        XCTAssertNil(s.decide(now: at(20), meetings: [m], recording: .meeting(m), quiet: 300))
        // Past the end but people are still talking.
        XCTAssertNil(s.decide(now: at(35), meetings: [m], recording: .meeting(m), quiet: 10))
        XCTAssertEqual(s.decide(now: at(35), meetings: [m], recording: .meeting(m), quiet: 120), .stop(.ended))
    }

    func testStopsAfterLongSilenceAndOverrun() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 0, 60)
        XCTAssertEqual(s.decide(now: at(25), meetings: [m], recording: .meeting(m), quiet: 600), .stop(.quiet))
        XCTAssertEqual(s.decide(now: at(120), meetings: [m], recording: .meeting(m), quiet: 0), .stop(.overrun))
    }

    func testRollsIntoBackToBackMeeting() {
        var s = MeetingScheduler(mode: .auto)
        let a = meeting("a", 0, 30)
        let b = meeting("b", 30, 60)
        s.markHandled(a)
        // b's lead time doesn't cut a short.
        XCTAssertNil(s.decide(now: at(29.5), meetings: [a, b], recording: .meeting(a), quiet: 0))
        XCTAssertEqual(s.decide(now: at(30), meetings: [a, b], recording: .meeting(a), quiet: 0), .roll(to: b))
        XCTAssertTrue(s.handled.contains("b"))
    }

    func testOverlappingMeetingDoesNotInterrupt() {
        var s = MeetingScheduler(mode: .auto)
        let a = meeting("a", 0, 60)
        let b = meeting("b", 15, 45)
        XCTAssertNil(s.decide(now: at(20), meetings: [a, b], recording: .meeting(a), quiet: 0))
    }

    func testAskModeStopsForNextMeetingThenPrompts() {
        var s = MeetingScheduler(mode: .ask)
        let a = meeting("a", 0, 30)
        let b = meeting("b", 30, 60)
        s.markHandled(a)
        XCTAssertEqual(s.decide(now: at(30), meetings: [a, b], recording: .meeting(a), quiet: 0), .stop(.nextMeeting))
        _ = s.decide(now: at(30), meetings: [a, b], recording: .idle, quiet: 0)
        XCTAssertEqual(s.prompting, b)
    }

    func testCallEndedStopsMeetingRecording() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 0, 60)
        XCTAssertEqual(
            s.decide(now: at(40), meetings: [m], recording: .meeting(m), quiet: 0, callEnded: true), .stop(.callEnded))
        XCTAssertNil(s.decide(now: at(200), meetings: [m], recording: .manual, quiet: 0, callEnded: true))
    }

    func testUserStopRetiresMeetingsUnderWay() {
        var s = MeetingScheduler(mode: .ask)
        let a = meeting("a", 0, 60)
        let later = meeting("later", 90, 120)
        s.userStopped(now: at(49), meetings: [a, later])
        // No prompt for the meeting the user just left…
        XCTAssertNil(s.decide(now: at(49), meetings: [a, later], recording: .idle, quiet: 0))
        XCTAssertNil(s.prompting)
        // …but later meetings are untouched.
        _ = s.decide(now: at(90), meetings: [a, later], recording: .idle, quiet: 0)
        XCTAssertEqual(s.prompting, later)
    }

    func testHandledSurvivesIdentifierChange() {
        var s = MeetingScheduler(mode: .auto)
        let m = meeting("a", 0, 30)
        s.markHandled(m)
        var resynced = m
        resynced.id = "new-eventkit-id"
        XCTAssertNil(s.decide(now: at(5), meetings: [resynced], recording: .idle, quiet: 0))
    }

    func testUnansweredPromptExpires() {
        var s = MeetingScheduler(mode: .ask)
        let m = meeting("a", 0, 60)
        _ = s.decide(now: at(0), meetings: [m], recording: .idle, quiet: 0)
        _ = s.decide(now: at(9), meetings: [m], recording: .idle, quiet: 0)
        XCTAssertEqual(s.prompting, m)
        _ = s.decide(now: at(10), meetings: [m], recording: .idle, quiet: 0)
        XCTAssertNil(s.prompting)
        _ = s.decide(now: at(11), meetings: [m], recording: .idle, quiet: 0)
        XCTAssertNil(s.prompting)
    }

    func testPrefersMostRecentlyStartedOverlap() {
        var s = MeetingScheduler(mode: .auto)
        let block = meeting("block", 0, 120)
        let call = meeting("call", 30, 60)
        XCTAssertEqual(s.decide(now: at(35), meetings: [block, call], recording: .idle, quiet: 0), .start(call))
    }
}

final class SessionMeetingMetaTests: XCTestCase {
    func testMeetingRoundTripsAndIsOmittedWhenAbsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var meta = SessionMeta(
            schema_version: 2, started: "s", ended: "e", duration_seconds: 1, status: .complete, tracks: [])
        try meta.write(to: dir)
        let plain = try String(contentsOf: dir.appendingPathComponent("meta.json"), encoding: .utf8)
        XCTAssertFalse(plain.contains("meeting"))
        XCTAssertNil(SessionMeta.meeting(in: dir))

        meta.meeting = SessionMeta.Meeting(
            title: "Weekly sync", calendar: "Work", scheduled_start: "a", scheduled_end: "b", video_link: nil)
        try meta.write(to: dir)
        XCTAssertEqual(SessionMeta.meeting(in: dir)?.title, "Weekly sync")
    }

    func testTranscriptTitledByMeeting() {
        let transcript = Transcript(engine: "e", model: "m", created_at: "c", segments: [])
        let md = transcript.rendered(title: "Weekly sync", session: "2026.10.05-1030")
        XCTAssertTrue(md.hasPrefix("# Weekly sync\n\nsession: 2026.10.05-1030\nengine: e (m)"))
        XCTAssertFalse(transcript.rendered(title: "t").contains("session:"))
    }
}
