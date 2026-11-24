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

    private let folder = "2026.10.26-1530-iphone"
    private let phone = HubDevice(id: "PHONE", name: "iPhone", kind: "iphone")
    private let mac = HubDevice(id: "MAC", name: "MacBook Pro", kind: "mac")

    override func setUpWithError() throws {
        manifest = try fixture(SessionManifest.self, "meta.json")
        transcript = try fixture(Transcript.self, "transcript.json")
    }

    private func hub(
        id: String, name: String, device: HubDevice, status: HubSession.Status = .transcribed,
        error: String? = nil, preview: String = "", title: String? = nil, started: String = "2026-10-26T15:30:00Z"
    ) -> HubSession {
        HubSession(
            id: id, name: name, device: device, title: title, started: started, durationSeconds: 1205,
            status: status, error: error, preview: preview, revision: 7)
    }

    private func delivery(_ id: String, committed: Bool = false, rejected: String? = nil) -> HubDelivery {
        var d = HubDelivery(id: id)
        d.committed = committed
        d.rejected = rejected
        return d
    }

    func testLocalSessionMovesThroughItsStages() {
        func row(_ d: HubDelivery?, legacy: Bool = false, hub sessions: [HubSession] = []) -> RecordingSummary? {
            RecordingSummary.merge(
                local: [LocalSession(name: folder, manifest: manifest, delivery: d, legacySent: legacy)], hub: sessions
            ).first
        }
        XCTAssertEqual(row(nil)?.stage, .waiting)
        XCTAssertEqual(row(delivery("A"))?.stage, .waiting)
        XCTAssertEqual(row(delivery("A", committed: true))?.stage, .transcribing)
        XCTAssertEqual(row(nil, legacy: true)?.stage, .transcribing)
        // An old iCloud folder the hub turned out not to have is sending again.
        XCTAssertEqual(row(delivery("A"), legacy: true)?.stage, .waiting)
        XCTAssertEqual(row(delivery("A"), hub: [hub(id: "A", name: folder, device: phone, status: .queued)])?.stage, .transcribing)
        XCTAssertEqual(row(delivery("A"), hub: [hub(id: "A", name: folder, device: phone, status: .transcribing)])?.stage, .transcribing)
        XCTAssertEqual(row(delivery("A"), hub: [hub(id: "A", name: folder, device: phone)])?.stage, .transcribed)

        let failed = row(delivery("A"), hub: [hub(id: "A", name: folder, device: phone, status: .failed, error: "model crashed")])
        XCTAssertEqual(failed?.stage, .failed)
        XCTAssertEqual(failed?.failure, "model crashed")

        let refused = row(delivery("A", rejected: "bad meta"))
        XCTAssertEqual(refused?.stage, .failed)
        XCTAssertEqual(refused?.failure, "bad meta")
    }

    func testLocalFolderAndHubSessionAreOneRowWithAudio() {
        let rows = RecordingSummary.merge(
            local: [LocalSession(name: folder, manifest: manifest, delivery: delivery("A", committed: true))],
            hub: [hub(id: "A", name: "\(folder)-2", device: phone, preview: "Okay, let's start")],
            transcripts: ["A": transcript.fullText], thisDevice: "PHONE")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "A")
        XCTAssertEqual(rows[0].name, folder)  // the local folder, for its audio
        XCTAssertTrue(rows[0].hasAudio)
        XCTAssertEqual(rows[0].source, .iphone)
        XCTAssertNil(rows[0].deviceName)
        XCTAssertEqual(rows[0].revision, 7)
        XCTAssertEqual(rows[0].durationSeconds, 1205)
        XCTAssertTrue(rows[0].searchText.contains("punch list"))
    }

    func testFolderWithAnIDNeverJoinsByName() {
        let rows = RecordingSummary.merge(
            local: [LocalSession(name: folder, manifest: manifest, delivery: delivery("A"))],
            hub: [hub(id: "B", name: folder, device: phone)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)), ["A", "B"])
    }

    func testOldFolderWithoutAnIDJoinsByName() {
        let rows = RecordingSummary.merge(
            local: [LocalSession(name: folder, manifest: manifest, legacySent: true)],
            hub: [hub(id: "B", name: folder, device: phone)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "B")
        XCTAssertEqual(rows[0].stage, .transcribed)
        XCTAssertTrue(rows[0].hasAudio)
    }

    func testHubSessionsFromOtherDevices() {
        let rows = RecordingSummary.merge(
            local: [],
            hub: [
                hub(id: "M", name: "2026.10.20-0900", device: mac, title: "Weekly sync", started: "2026-10-20T14:00:00Z"),
                hub(id: "P", name: "2026.10.19-0900-iphone", device: phone, started: "2026-10-19T14:00:00Z"),
            ], thisDevice: "OTHER-PHONE")
        XCTAssertEqual(rows.map(\.title), ["Weekly sync", nil])
        XCTAssertEqual(rows.map(\.source), [.mac, .iphone])
        XCTAssertEqual(rows.map(\.deviceName), ["MacBook Pro", "iPhone"])
        XCTAssertEqual(rows.map(\.hasAudio), [false, false])
        XCTAssertEqual(rows[0].startedAt, ISO8601DateFormatter().date(from: "2026-10-20T14:00:00Z"))
        XCTAssertEqual(rows.map(\.deviceDescription), ["MacBook Pro", "iPhone"])

        let mine = RecordingSummary.merge(local: [], hub: [hub(id: "P", name: "x", device: phone)], thisDevice: "PHONE")
        XCTAssertEqual(mine[0].deviceDescription, "this iPhone")
    }

    func testSearchUsesThePreviewUntilTheTranscriptIsCached() {
        let session = hub(id: "M", name: "2026.10.20-0900", device: mac, preview: "Budget review first", title: "Sync")
        let before = RecordingSummary.merge(local: [], hub: [session])
        XCTAssertTrue(before[0].searchText.contains("budget review"))
        XCTAssertTrue(before[0].searchText.contains("sync"))
        XCTAssertFalse(before[0].searchText.contains("punch list"))

        let after = RecordingSummary.merge(local: [], hub: [session], transcripts: ["M": transcript.fullText])
        XCTAssertTrue(after[0].searchText.contains("punch list"))
        XCTAssertEqual(after[0].preview, "Budget review first")
    }

    func testGroupsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = ISO8601DateFormatter().date(from: "2026-10-26T18:00:00Z")!
        func row(_ iso: String) -> RecordingSummary {
            RecordingSummary(
                id: iso, hubID: nil, name: iso, title: nil, startedAt: ISO8601DateFormatter().date(from: iso)!,
                durationSeconds: 0, source: .iphone, deviceName: nil, stage: .transcribed, failure: nil,
                hasAudio: false, preview: "", revision: nil, searchText: "")
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
