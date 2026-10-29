import XCTest

@testable import quill

/// Offset-preserving merge: each segment file's transcript shifts by its
/// session-clock offset, and recovery gaps stay visible as timestamp gaps.
final class TranscriptionCoordinatorTests: XCTestCase {
    func testShiftedPreservesSegmentOffsets() {
        let raw = [
            TranscriptSegment(start: 0.5, end: 2.0, text: "hello"),
            TranscriptSegment(start: 3.0, end: 4.5, text: "world"),
        ]
        let shifted = Transcript.shifted(raw, speaker: "me", offsetMs: 1_691_120)
        XCTAssertEqual(
            shifted,
            [
                Transcript.Segment(speaker: "me", start_ms: 1_691_620, end_ms: 1_693_120, text: "hello"),
                Transcript.Segment(speaker: "me", start_ms: 1_694_120, end_ms: 1_695_620, text: "world"),
            ])
    }

    func testShiftedLabelsDiarizedVoicesWithinTheTrack() {
        let raw = [
            TranscriptSegment(start: 0, end: 1, text: "hi", speaker: 0),
            TranscriptSegment(start: 1, end: 2, text: "hey", speaker: 1),
            TranscriptSegment(start: 2, end: 3, text: "so"),
        ]
        XCTAssertEqual(
            Transcript.shifted(raw, speaker: "room", offsetMs: 0).map(\.speaker),
            ["speaker 1", "speaker 2", "room"])
        XCTAssertEqual(
            Transcript.shifted(raw, speaker: "them", offsetMs: 0).map(\.speaker),
            ["them 1", "them 2", "them"])
    }

    func testRemoteResponseDecodesOneResultPerFile() throws {
        let body = Data(
            """
            {"engine": "nemo", "model": "m",
             "files": [{"duration": 3.5,
                        "segments": [{"start": 0.16, "end": 1.2, "text": "Alright.", "speaker": 1},
                                     {"start": 1.9, "end": 2.1, "text": "Okay.", "speaker": null}]},
                       {"duration": 1.0, "segments": []}]}
            """.utf8)
        let files = try RemoteEngine.segments(from: body, base: URL(string: "http://spark:8091")!)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].map(\.text), ["Alright.", "Okay."])
        XCTAssertEqual(files[0].map(\.speaker), [1, nil])
        XCTAssertEqual(files[0][0].start, 0.16)
        XCTAssertTrue(files[1].isEmpty)
    }

    func testTracksGroupConsecutiveSegmentFiles() {
        let inputs = [
            SessionMeta.TrackInput(file: "mic.caf", speaker: "me", offsetMs: 0),
            SessionMeta.TrackInput(file: "mic-2.caf", speaker: "me", offsetMs: 25000),
            SessionMeta.TrackInput(file: "system.caf", speaker: "them", offsetMs: 0),
        ]
        XCTAssertEqual(
            TranscriptionCoordinator.tracks(inputs).map { $0.map(\.file) },
            [["mic.caf", "mic-2.caf"], ["system.caf"]])
    }

    func testMultipartCarriesEachFileInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.caf")
        let b = dir.appendingPathComponent("b.caf")
        try Data("AAA".utf8).write(to: a)
        try Data("BBB".utf8).write(to: b)
        let body = String(decoding: try RemoteEngine.multipart([a, b], boundary: "x"), as: UTF8.self)
        XCTAssertEqual(
            body,
            "--x\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"a.caf\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\nAAA\r\n"
                + "--x\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"b.caf\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\nBBB\r\n--x--\r\n")
    }

    func testRemoteGarbageIsUnreachable() {
        XCTAssertThrowsError(try RemoteEngine.segments(from: Data("<html>".utf8), base: URL(string: "http://x")!)) {
            guard case RemoteEngine.EngineError.unreachable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMergeInterleavesSegmentsAndRetainsGap() {
        // First mic segment ends at 10 s; the second starts at 25 s after a
        // 15 s capture gap. The system track spans the whole session.
        var merged: [Transcript.Segment] = []
        merged += Transcript.shifted(
            [TranscriptSegment(start: 1, end: 9, text: "before the gap")],
            speaker: "me", offsetMs: 0
        )
        merged += Transcript.shifted(
            [TranscriptSegment(start: 0, end: 5, text: "after the gap")],
            speaker: "me", offsetMs: 25000
        )
        merged += Transcript.shifted(
            [
                TranscriptSegment(start: 12, end: 14, text: "they talk"),
                TranscriptSegment(start: 31, end: 33, text: "they answer"),
            ],
            speaker: "them", offsetMs: 0
        )
        merged.sort { $0.start_ms < $1.start_ms }

        XCTAssertEqual(
            merged.map(\.text),
            [
                "before the gap", "they talk", "after the gap", "they answer",
            ])
        // The gap survives the merge: nothing from "me" between 10 s and 25 s,
        // and the second segment is not collapsed against the first's end.
        XCTAssertEqual(merged[2].start_ms, 25000)
    }

    func testRenderedHeaderCarriesCaptureStatus() {
        let transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-08-03T20:09:35Z",
            segments: [
                Transcript.Segment(speaker: "me", start_ms: 0, end_ms: 1000, text: "hi")
            ]
        )
        XCTAssertTrue(
            transcript.rendered(title: "t", captureStatus: .recovered)
                .contains("capture: recovered")
        )
        XCTAssertTrue(
            transcript.rendered(title: "t", captureStatus: .incomplete)
                .contains("capture: incomplete")
        )
        XCTAssertFalse(
            transcript.rendered(title: "t", captureStatus: .complete).contains("capture:")
        )
        XCTAssertFalse(transcript.rendered(title: "t").contains("capture:"))
    }
}
