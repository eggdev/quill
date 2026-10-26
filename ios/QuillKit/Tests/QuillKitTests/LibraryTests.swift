import XCTest

@testable import QuillKit

private let session = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // QuillKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // QuillKit
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()
    .appendingPathComponent("fixtures/sessions/iphone-room")

private func fixture<T: Decodable>(_ type: T.Type, _ file: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: session.appendingPathComponent(file)))
}

private let utc = TimeZone(identifier: "UTC")!

final class TranscriptTests: XCTestCase {
    func testReadsTheMacTranscript() throws {
        let t = try fixture(Transcript.self, "transcript.json")
        XCTAssertEqual(t.segments.count, 3)
        XCTAssertEqual(t.segments[2].start_ms, 318_400)
        XCTAssertTrue(t.preview.hasPrefix("Okay, let's start"))
    }

    func testHighlightFollowsPlaybackAndHoldsThroughGaps() throws {
        let t = try fixture(Transcript.self, "transcript.json")
        XCTAssertNil(t.segmentIndex(at: 100))
        XCTAssertEqual(t.segmentIndex(at: 300), 0)
        XCTAssertEqual(t.segmentIndex(at: 4400), 0)  // pause between lines
        XCTAssertEqual(t.segmentIndex(at: 100_000), 1)  // inside the phone-call gap
        XCTAssertEqual(t.segmentIndex(at: 318_400), 2)
    }

    func testSpeakerNamesShowOncePerTurn() {
        let t = Transcript(
            engine: "", model: "", created_at: "",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1, text: "a"),
                .init(speaker: "me", start_ms: 1, end_ms: 2, text: "b"),
                .init(speaker: "them", start_ms: 2, end_ms: 3, text: "c"),
            ])
        XCTAssertEqual([0, 1, 2].map(t.startsTurn), [true, false, true])
        XCTAssertEqual(Transcript.displayName(for: "me"), "You")
        XCTAssertNil(Transcript.displayName(for: "room"))
    }
}

final class RecordingSummaryTests: XCTestCase {
    private var manifest: SessionManifest!
    private var transcript: Transcript!

    override func setUpWithError() throws {
        manifest = try fixture(SessionManifest.self, "meta.json")
        transcript = try fixture(Transcript.self, "transcript.json")
    }

    func testLocalSessionMovesThroughItsStages() {
        let name = "2026.10.26-1530-iphone"
        func stage(sent: Bool, published: Bool) -> RecordingSummary.Stage? {
            RecordingSummary.merge(
                local: [LocalSession(name: name, manifest: manifest, sent: sent)],
                published: published ? [PublishedSession(name: name, manifest: manifest, transcript: transcript)] : []
            ).first?.stage
        }
        XCTAssertEqual(stage(sent: false, published: false), .waiting)
        XCTAssertEqual(stage(sent: true, published: false), .transcribing)
        XCTAssertEqual(stage(sent: true, published: true), .transcribed)
    }

    func testLocalAndPublishedCopiesAreOneRowWithAudio() {
        let name = "2026.10.26-1530-iphone"
        let rows = RecordingSummary.merge(
            local: [LocalSession(name: name, manifest: manifest, sent: true)],
            published: [PublishedSession(name: name, manifest: manifest, transcript: transcript)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].hasAudio)
        XCTAssertEqual(rows[0].source, .iphone)
        XCTAssertEqual(rows[0].durationSeconds, 1205)
        XCTAssertTrue(rows[0].searchText.contains("punch list"))
    }

    func testMacSessionUsesMeetingTitleOrFolderDate() throws {
        let macMeta = """
            {"schema_version":2,"started":"2026-10-20T14:00:00Z","ended":"2026-10-20T14:30:00Z",
             "duration_seconds":1800,"status":"complete","tracks":[],
             "meeting":{"title":"Weekly sync","calendar":"Work","scheduled_start":"x","scheduled_end":"y"}}
            """
        let withMeeting = try JSONDecoder().decode(SessionManifest.self, from: Data(macMeta.utf8))
        let rows = RecordingSummary.merge(
            local: [],
            published: [
                PublishedSession(name: "2026.10.20-0900", manifest: withMeeting, transcript: transcript),
                PublishedSession(name: "2026.08.01-1015", manifest: nil, transcript: transcript),
            ])
        XCTAssertEqual(rows.map(\.title), ["Weekly sync", nil])
        XCTAssertEqual(rows.map(\.source), [.mac, .mac])
        XCTAssertEqual(rows.map(\.hasAudio), [false, false])
        // No readable meta: the date comes from the folder name, the length
        // from the transcript.
        XCTAssertEqual(rows[1].startedAt, SessionFolder.date(fromName: "2026.08.01-1015"))
        XCTAssertEqual(rows[1].durationSeconds, 321)
    }

    func testGroupsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = ISO8601DateFormatter().date(from: "2026-10-26T18:00:00Z")!
        func row(_ iso: String) -> RecordingSummary {
            RecordingSummary(
                name: iso, title: nil, startedAt: ISO8601DateFormatter().date(from: iso)!, durationSeconds: 0,
                source: .iphone, stage: .transcribed, hasAudio: false, preview: "", searchText: "")
        }
        let groups = DayGroup.group(
            [
                row("2026-10-26T15:00:00Z"), row("2026-10-26T09:00:00Z"), row("2026-10-25T09:00:00Z"),
                row("2026-10-20T09:00:00Z"), row("2025-12-01T09:00:00Z"),
            ], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.recordings.count), [2, 1, 1, 1])
        XCTAssertEqual(Array(groups.map(\.title).prefix(2)), ["Today", "Yesterday"])
        XCTAssertTrue(groups[2].title.contains("October 20"))
        XCTAssertTrue(groups[3].title.contains("2025"))
    }
}

final class PlaybackTests: XCTestCase {
    func testSegmentsPlayAtTheirSessionOffsets() throws {
        let plan = PlaybackPlan(manifest: try fixture(SessionManifest.self, "meta.json"))
        XCTAssertEqual(plan.items, [.init(file: "mic.caf", atMs: 0), .init(file: "mic-002.caf", atMs: 318_020)])
        XCTAssertEqual(plan.durationMs, 1_205_500)
    }

    func testFormats() {
        XCTAssertEqual(Format.clock(ms: 7_400), "0:07")
        XCTAssertEqual(Format.clock(ms: 3_723_000), "1:02:03")
        XCTAssertEqual(Format.duration(seconds: 45), "45 sec")
        XCTAssertEqual(Format.duration(seconds: 3900), "1 hr 5 min")
        XCTAssertEqual(Format.level(decibels: -160), 0)
        XCTAssertEqual(Format.level(decibels: -25), 0.5)
        XCTAssertEqual(Format.level(decibels: 3), 1)
    }
}
