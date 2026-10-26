import XCTest

@testable import QuillKit

/// fixtures/ at the repository root — the contract the Mac importer reads.
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // QuillKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // QuillKit
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()
    .appendingPathComponent("fixtures")

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class SessionManifestTests: XCTestCase {
    func testWritesTheSharedFixture() throws {
        var t = CaptureTimeline()
        _ = t.openSegment(atMs: 0)
        t.interrupt(atMs: 252_340, reason: "audio session interrupted")
        _ = t.openSegment(atMs: 318_020)
        t.finish(atMs: 1_205_500)
        let frames = ["mic.caf": Int64(12_112_320), "mic-002.caf": Int64(42_599_040)]

        let manifest = SessionManifest(
            started: date("2026-10-26T15:30:00Z"),
            ended: date("2026-10-26T15:50:05Z"),
            timeline: t,
            audio: { frames[$0].map { SegmentAudio(frames: $0, sampleRateHz: 48_000, channels: 1) } }
        )

        let dir = try temporaryDirectory()
        try manifest.write(to: dir)
        let written = try JSONDecoder().decode(
            SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        let fixture = try JSONDecoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("sessions/iphone-room/meta.json")))
        XCTAssertEqual(written, fixture)
    }

    func testEmptySegmentIsDroppedAndNoAudioIsIncomplete() {
        var t = CaptureTimeline()
        _ = t.openSegment(atMs: 0)
        t.finish(atMs: 200)
        let manifest = SessionManifest(
            started: Date(), ended: Date(), timeline: t,
            audio: { _ in SegmentAudio(frames: 0, sampleRateHz: 48_000, channels: 1) })

        XCTAssertEqual(manifest.tracks.first?.segments, [])
        XCTAssertEqual(manifest.status, .incomplete)
        XCTAssertEqual(manifest.tracks.first?.warnings, ["no audio was captured"])
    }

    func testRecoveredSessionLaysSurvivingSegmentsEndToEnd() {
        let manifest = SessionManifest(
            recovering: [
                ("mic.caf", SegmentAudio(frames: 96_000, sampleRateHz: 48_000, channels: 1)),
                ("mic-002.caf", SegmentAudio(frames: 0, sampleRateHz: 48_000, channels: 1)),
                ("mic-003.caf", SegmentAudio(frames: 48_000, sampleRateHz: 48_000, channels: 1)),
            ],
            started: date("2026-10-26T15:30:00Z"))

        let segments = manifest.tracks[0].segments
        XCTAssertEqual(segments.map(\.file), ["mic.caf", "mic-003.caf"])
        XCTAssertEqual(segments.map(\.start_offset_ms), [0, 2000])
        XCTAssertEqual(segments.map(\.end_offset_ms), [2000, 3000])
        XCTAssertEqual(manifest.ended, "2026-10-26T15:30:03Z")
        XCTAssertEqual(manifest.status, .incomplete)
        XCTAssertFalse(manifest.tracks[0].warnings.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

final class SessionFolderTests: XCTestCase {
    func testNameIsTheMacFormatPlusIphone() {
        let started = date("2026-10-26T15:30:59Z")
        XCTAssertEqual(
            SessionFolder.name(startedAt: started, timeZone: TimeZone(identifier: "UTC")!), "2026.10.26-1530-iphone")
    }

    func testUniqueSuffixesOnCollision() {
        let taken: Set = ["a", "a-2"]
        XCTAssertEqual(SessionFolder.unique("a", taken: taken.contains), "a-3")
        XCTAssertEqual(SessionFolder.unique("b", taken: taken.contains), "b")
    }
}
