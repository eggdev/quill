import XCTest

@testable import quill

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func meeting(_ id: String, from start: Double, to end: Double) -> Meeting {
    Meeting(id: id, title: id, start: at(start), end: at(end), calendar: "Work", videoLink: nil)
}

private func policy(meetings: AutoRecordMode, calls: AutoRecordMode) -> RecordingPolicy {
    var p = RecordingPolicy()
    p.configure(meetings: meetings, calls: calls, timing: MeetingScheduler.Timing())
    return p
}

/// The rules between calendar meetings, detected calls, and user actions —
/// the layer the app used to hand-wire.
final class RecordingPolicyTests: XCTestCase {
    func testStoppingDoesNotOfferAMeetingThatBeganMidRecording() {
        var p = policy(meetings: .ask, calls: .ask)
        let sync = meeting("sync", from: 0, to: 3600)
        // Recording by hand before the meeting's window opens…
        let origin = p.userStarting(now: at(-600), meetings: [sync])
        XCTAssertEqual(origin, .manual(nil))
        p.started(origin)
        XCTAssertNil(p.tick(now: at(30), meetings: [sync], holding: [], quiet: 0))
        // …and stopping partway through it: the meeting isn't offered.
        p.stopped()
        p.userStopped(now: at(1200), meetings: [sync])
        XCTAssertNil(p.tick(now: at(1202), meetings: [sync], holding: [], quiet: 0))
        XCTAssertNil(p.prompt)
    }

    func testAcceptedMeetingIsNotReofferedAfterTheCalendarResyncs() {
        var p = policy(meetings: .ask, calls: .ask)
        let sync = meeting("sync", from: 0, to: 3600)
        _ = p.tick(now: at(0), meetings: [sync], holding: [], quiet: 0)
        let origin = p.acceptPrompt()
        XCTAssertEqual(origin, .meeting(sync))
        p.started(origin!)
        p.stopped()
        // Exchange re-syncs and hands the occurrence a new identifier.
        var resynced = sync
        resynced.id = "sync-after-resync"
        XCTAssertNil(p.tick(now: at(2902), meetings: [resynced], holding: [], quiet: 0))
        XCTAssertNil(p.prompt)
    }

    func testManualRecordingTakesMeetingTitleAndIsNeverStopped() {
        var p = policy(meetings: .auto, calls: .ask)
        let sync = meeting("sync", from: 0, to: 1800)
        let origin = p.userStarting(now: at(30), meetings: [sync])
        XCTAssertEqual(origin, .manual(sync))
        p.started(origin)
        XCTAssertNil(p.tick(now: at(9000), meetings: [sync], holding: [], quiet: 5000))
    }

    func testMeetingRecordingStopsWhenTheCallAppLetsGo() {
        var p = policy(meetings: .auto, calls: .ask)
        let sync = meeting("sync", from: 0, to: 3600)
        guard case .start(let origin)? = p.tick(now: at(0), meetings: [sync], holding: [], quiet: 0) else {
            return XCTFail("expected the meeting to start")
        }
        p.started(origin)
        _ = p.tick(now: at(10), meetings: [sync], holding: ["Teams"], quiet: 0)
        XCTAssertNil(p.tick(now: at(20), meetings: [sync], holding: ["Teams"], quiet: 0))
        // Left the call well before the scheduled end.
        XCTAssertNil(p.tick(now: at(1200), meetings: [sync], holding: [], quiet: 0))
        XCTAssertEqual(p.tick(now: at(1230), meetings: [sync], holding: [], quiet: 0), .stop(.callEnded))
    }

    func testDueMeetingWinsOverTheCallItIs() {
        var p = policy(meetings: .ask, calls: .ask)
        let sync = meeting("sync", from: 0, to: 1800)
        _ = p.tick(now: at(0), meetings: [sync], holding: ["Teams"], quiet: 0)
        _ = p.tick(now: at(10), meetings: [sync], holding: ["Teams"], quiet: 0)
        XCTAssertEqual(p.prompt, .meeting(sync))
        p.skipPrompt()
        // Skipping the meeting doesn't resurface it as an ad-hoc call.
        _ = p.tick(now: at(20), meetings: [sync], holding: ["Teams"], quiet: 0)
        XCTAssertNil(p.prompt)
    }

    func testCallRecordingBecomesTheMeetingWhenOneComesDue() {
        var p = policy(meetings: .ask, calls: .ask)
        let sync = meeting("sync", from: 600, to: 2400)
        _ = p.tick(now: at(0), meetings: [sync], holding: ["Zoom"], quiet: 0)
        _ = p.tick(now: at(6), meetings: [sync], holding: ["Zoom"], quiet: 0)
        guard case .call(let call)? = p.prompt, let origin = p.acceptPrompt() else {
            return XCTFail("expected a call prompt")
        }
        XCTAssertEqual(origin, .call(call))
        p.started(origin)

        // Joined early; at the lead time the recording takes the meeting.
        XCTAssertEqual(p.tick(now: at(540), meetings: [sync], holding: ["Zoom"], quiet: 0), .retitle(.meeting(sync)))
        XCTAssertEqual(p.origin, .meeting(sync))
    }

    func testMeetingsOffIgnoresAStaleMeetingList() {
        var p = policy(meetings: .off, calls: .ask)
        let sync = meeting("sync", from: 0, to: 1800)
        XCTAssertEqual(p.userStarting(now: at(30), meetings: [sync]), .manual(nil))
        XCTAssertNil(p.tick(now: at(30), meetings: [sync], holding: [], quiet: 0))
        XCTAssertNil(p.upcoming(now: at(30), meetings: [sync]))
    }
}
