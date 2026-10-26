import XCTest

@testable import quill

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // QuillTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // macos
    .deletingLastPathComponent()
    .appendingPathComponent("fixtures/sessions/iphone-room")

final class TranscriptPublisherTests: XCTestCase {
    private var root: URL!
    private var library: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("Recordings")
        library = base.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    }

    func testTheMacReadsTheSharedTranscriptFixture() throws {
        let data = try Data(contentsOf: fixture.appendingPathComponent("transcript.json"))
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(transcript.segments.map(\.speaker), ["room", "room", "room"])
    }

    func testPublishesTranscriptAndMetaButNotAudio() throws {
        try session("2026.10.26-1530-iphone", transcribed: true)

        XCTAssertEqual(publisher.publish(), ["2026.10.26-1530-iphone"])
        let published = try FileManager.default.contentsOfDirectory(
            atPath: library.appendingPathComponent("2026.10.26-1530-iphone").path)
        XCTAssertEqual(Set(published), ["transcript.json", "meta.json"])
    }

    func testSkipsUntranscribedAndAlreadyPublished() throws {
        try session("a", transcribed: true)
        try session("b", transcribed: false)

        XCTAssertEqual(publisher.publish(), ["a"])
        XCTAssertEqual(publisher.publish(), [])
    }

    func testRepublishesARetranscription() throws {
        try session("a", transcribed: true)
        _ = publisher.publish()
        let transcript = root.appendingPathComponent("a/transcript.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: transcript.path)

        XCTAssertEqual(publisher.publish(), ["a"])
    }

    private var publisher: TranscriptPublisher { TranscriptPublisher(root: root, library: library) }

    private func session(_ name: String, transcribed: Bool) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture.appendingPathComponent("meta.json"), to: dir.appendingPathComponent("meta.json"))
        try Data([0x01]).write(to: dir.appendingPathComponent("mic.caf"))
        if transcribed {
            try FileManager.default.copyItem(
                at: fixture.appendingPathComponent("transcript.json"), to: dir.appendingPathComponent("transcript.json"))
        }
    }
}
