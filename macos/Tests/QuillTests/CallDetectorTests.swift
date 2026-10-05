import XCTest

@testable import quill

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

final class MeetingAppTests: XCTestCase {
    func testMatchesHelpersByPrefixAtDotBoundary() {
        XCTAssertEqual(MeetingApp.match(bundleID: "com.microsoft.teams2.helper", includeBrowsers: false)?.name, "Teams")
        XCTAssertEqual(MeetingApp.match(bundleID: "us.zoom.xos", includeBrowsers: false)?.name, "Zoom")
        XCTAssertNil(MeetingApp.match(bundleID: "com.microsoft.teamsfoo", includeBrowsers: false))
        XCTAssertNil(MeetingApp.match(bundleID: "com.spotify.client", includeBrowsers: false))
    }

    func testBrowsersOnlyWhenOptedIn() {
        XCTAssertNil(MeetingApp.match(bundleID: "com.google.Chrome.helper", includeBrowsers: false))
        XCTAssertEqual(MeetingApp.match(bundleID: "com.google.Chrome.helper", includeBrowsers: true)?.name, "Browser")
    }
}

final class CallDetectorTests: XCTestCase {
    func testAskPromptsAfterStartDebounce() {
        var d = CallDetector(mode: .ask)
        XCTAssertNil(d.decide(now: at(0), holding: ["Teams"], recording: .idle, meetingDue: false))
        XCTAssertNil(d.prompting)
        XCTAssertNil(d.decide(now: at(4), holding: ["Teams"], recording: .idle, meetingDue: false))
        XCTAssertNil(d.prompting)
        XCTAssertNil(d.decide(now: at(5), holding: ["Teams"], recording: .idle, meetingDue: false))
        XCTAssertEqual(d.prompting?.title, "Teams call")
        XCTAssertEqual(d.prompting?.start, at(0))
    }

    func testBriefMicGrabIsNotACall() {
        var d = CallDetector(mode: .auto)
        _ = d.decide(now: at(0), holding: ["Slack"], recording: .idle, meetingDue: false)
        XCTAssertNil(d.decide(now: at(2), holding: [], recording: .idle, meetingDue: false))
        XCTAssertNil(d.decide(now: at(10), holding: [], recording: .idle, meetingDue: false))
        XCTAssertNil(d.currentCall)
    }

    func testAutoStartsOnceAndStopsAfterRelease() {
        var d = CallDetector(mode: .auto)
        _ = d.decide(now: at(0), holding: ["Zoom"], recording: .idle, meetingDue: false)
        guard case .start(let call)? = d.decide(now: at(6), holding: ["Zoom"], recording: .idle, meetingDue: false)
        else { return XCTFail("expected start") }
        XCTAssertEqual(call.app, "Zoom")
        // A reconnect inside the end debounce keeps the call going.
        XCTAssertNil(d.decide(now: at(60), holding: [], recording: .call(call), meetingDue: false))
        XCTAssertNil(d.decide(now: at(80), holding: ["Zoom"], recording: .call(call), meetingDue: false))
        XCTAssertNil(d.decide(now: at(100), holding: [], recording: .call(call), meetingDue: false))
        XCTAssertNil(d.decide(now: at(129), holding: [], recording: .call(call), meetingDue: false))
        XCTAssertEqual(d.decide(now: at(130), holding: [], recording: .call(call), meetingDue: false), .stop)
        // Stopped: the same call never restarts.
        XCTAssertNil(d.decide(now: at(131), holding: [], recording: .idle, meetingDue: false))
    }

    func testUnansweredCallPromptExpires() {
        var d = CallDetector(mode: .ask)
        _ = d.decide(now: at(0), holding: ["Teams"], recording: .idle, meetingDue: false)
        _ = d.decide(now: at(5), holding: ["Teams"], recording: .idle, meetingDue: false)
        XCTAssertNotNil(d.prompting)
        _ = d.decide(now: at(604), holding: ["Teams"], recording: .idle, meetingDue: false)
        XCTAssertNotNil(d.prompting)
        _ = d.decide(now: at(605), holding: ["Teams"], recording: .idle, meetingDue: false)
        XCTAssertNil(d.prompting)
        _ = d.decide(now: at(700), holding: ["Teams"], recording: .idle, meetingDue: false)
        XCTAssertNil(d.prompting)
    }

    func testStoppedByHandNeverRestarts() {
        var d = CallDetector(mode: .auto)
        _ = d.decide(now: at(0), holding: ["Teams"], recording: .idle, meetingDue: false)
        XCTAssertNotNil(d.decide(now: at(6), holding: ["Teams"], recording: .idle, meetingDue: false))
        XCTAssertNil(d.decide(now: at(20), holding: ["Teams"], recording: .idle, meetingDue: false))
    }

    func testCalendarMeetingOrOtherRecordingTakesPrecedence() {
        var d = CallDetector(mode: .ask)
        _ = d.decide(now: at(0), holding: ["Teams"], recording: .idle, meetingDue: true)
        XCTAssertNil(d.decide(now: at(10), holding: ["Teams"], recording: .idle, meetingDue: true))
        XCTAssertNil(d.prompting)
        // Once the meeting window closes, the call it covered isn't offered.
        XCTAssertNil(d.decide(now: at(20), holding: ["Teams"], recording: .idle, meetingDue: false))
        XCTAssertNil(d.prompting)

        var e = CallDetector(mode: .auto)
        _ = e.decide(now: at(0), holding: ["Zoom"], recording: .other, meetingDue: false)
        XCTAssertNil(e.decide(now: at(10), holding: ["Zoom"], recording: .other, meetingDue: false))
        XCTAssertNil(e.decide(now: at(12), holding: ["Zoom"], recording: .idle, meetingDue: false))
    }

    func testSkipClearsPrompt() {
        var d = CallDetector(mode: .ask)
        _ = d.decide(now: at(0), holding: ["Webex"], recording: .idle, meetingDue: false)
        _ = d.decide(now: at(5), holding: ["Webex"], recording: .idle, meetingDue: false)
        let call = d.prompting!
        d.markHandled(call)
        XCTAssertNil(d.prompting)
        _ = d.decide(now: at(6), holding: ["Webex"], recording: .idle, meetingDue: false)
        XCTAssertNil(d.prompting)
    }

    func testOffNeverPromptsButStillTracksCalls() {
        var d = CallDetector(mode: .off)
        _ = d.decide(now: at(0), holding: ["Teams"], recording: .idle, meetingDue: false)
        XCTAssertNil(d.decide(now: at(10), holding: ["Teams"], recording: .idle, meetingDue: false))
        XCTAssertNil(d.prompting)
        // The call-ended signal for calendar recordings works in any mode.
        XCTAssertNotNil(d.currentCall)
    }

    func testNewCallReplacingRecordedOneStopsIt() {
        var d = CallDetector(mode: .auto)
        _ = d.decide(now: at(0), holding: ["Zoom"], recording: .idle, meetingDue: false)
        guard case .start(let zoom)? = d.decide(now: at(6), holding: ["Zoom"], recording: .idle, meetingDue: false)
        else { return XCTFail("expected start") }
        _ = d.decide(now: at(10), holding: ["Teams"], recording: .call(zoom), meetingDue: false)
        XCTAssertEqual(d.decide(now: at(41), holding: ["Teams"], recording: .call(zoom), meetingDue: false), .stop)
    }
}
