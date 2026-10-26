import XCTest

@testable import QuillKit

final class CaptureTimelineTests: XCTestCase {
    func testUninterruptedRecordingIsOneCompleteSegment() {
        var t = CaptureTimeline()
        XCTAssertEqual(t.openSegment(atMs: 0), "mic.caf")
        XCTAssertTrue(t.isCapturing)
        t.finish(atMs: 5000)
        XCTAssertEqual(t.spans, [.init(file: "mic.caf", startMs: 0, endMs: 5000)])
        XCTAssertEqual(t.status, .complete)
        XCTAssertFalse(t.isCapturing)
    }

    func testResumeAfterInterruptionOpensANewSegmentAtItsTrueOffset() {
        var t = CaptureTimeline()
        _ = t.openSegment(atMs: 0)
        t.interrupt(atMs: 252_340, reason: "audio session interrupted")
        XCTAssertTrue(t.isInterrupted)
        XCTAssertFalse(t.isCapturing)
        XCTAssertEqual(t.openSegment(atMs: 318_020), "mic-002.caf")
        t.finish(atMs: 1_205_500)

        XCTAssertEqual(
            t.spans,
            [
                .init(file: "mic.caf", startMs: 0, endMs: 252_340),
                .init(file: "mic-002.caf", startMs: 318_020, endMs: 1_205_500),
            ])
        XCTAssertEqual(t.interruptions.first?.recovered_offset_ms, 318_020)
        XCTAssertEqual(t.interruptions.first?.attempts, 1)
        XCTAssertEqual(t.status, .recovered)
    }

    func testStoppingDuringAnInterruptionLeavesItIncomplete() {
        var t = CaptureTimeline()
        _ = t.openSegment(atMs: 0)
        t.interrupt(atMs: 1000, reason: "audio session interrupted")
        t.resumeFailed("session activation failed")
        t.finish(atMs: 4000)

        XCTAssertEqual(t.spans, [.init(file: "mic.caf", startMs: 0, endMs: 1000)])
        XCTAssertNil(t.interruptions.first?.recovered_offset_ms)
        XCTAssertEqual(t.interruptions.first?.attempts, 1)
        XCTAssertEqual(t.interruptions.first?.error, "session activation failed")
        XCTAssertEqual(t.status, .incomplete)
    }

    func testRepeatedInterruptionBeforeResumeIsOneGap() {
        var t = CaptureTimeline()
        _ = t.openSegment(atMs: 0)
        t.interrupt(atMs: 1000, reason: "a")
        t.interrupt(atMs: 1500, reason: "b")
        XCTAssertEqual(t.interruptions.count, 1)
        XCTAssertEqual(t.interruptions.first?.detected_offset_ms, 1000)
    }

    func testSegmentNamesMatchTheMac() {
        XCTAssertEqual(CaptureTimeline.fileName(index: 1), "mic.caf")
        XCTAssertEqual(CaptureTimeline.fileName(index: 2), "mic-002.caf")
        XCTAssertEqual(CaptureTimeline.fileName(index: 12), "mic-012.caf")
    }
}
