import XCTest

@testable import quill

/// fixtures/ at the repository root — the session the iPhone app writes.
private let phoneMeta = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // QuillTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // macos
    .deletingLastPathComponent()
    .appendingPathComponent("fixtures/sessions/iphone-room/meta.json")

private let name = "2026.10.26-1530-iphone"

final class InboxImporterTests: XCTestCase {
    private var inbox: URL!
    private var root: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        inbox = base.appendingPathComponent("Inbox")
        root = base.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    }

    func testImportsAFinishedPhoneSessionAsTranscribable() throws {
        try phoneSession(files: ["mic.caf", "mic-002.caf"])

        let imported = InboxImporter(inbox: inbox, root: root).importReady()

        XCTAssertEqual(imported.map(\.lastPathComponent), [name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(name).path))
        let (inputs, status) = try SessionMeta.readInputs(from: imported[0])
        XCTAssertEqual(
            inputs,
            [
                .init(file: "mic.caf", speaker: "room", offsetMs: 0),
                .init(file: "mic-002.caf", speaker: "room", offsetMs: 318_020),
            ])
        XCTAssertEqual(status, .recovered)
    }

    func testWaitsForEverySegmentToArrive() throws {
        try phoneSession(files: ["mic.caf"])
        XCTAssertEqual(InboxImporter(inbox: inbox, root: root).importReady(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(name).path))
    }

    func testWaitsForICloudToDownloadTheAudio() throws {
        try phoneSession(files: ["mic.caf", "mic-002.caf"])
        var importer = InboxImporter(inbox: inbox, root: root)
        importer.isDownloaded = { $0.lastPathComponent != "mic-002.caf" }
        XCTAssertEqual(importer.importReady(), [])
    }

    func testIgnoresFoldersWithoutMeta() throws {
        try FileManager.default.createDirectory(
            at: inbox.appendingPathComponent("half-synced"), withIntermediateDirectories: true)
        XCTAssertEqual(InboxImporter(inbox: inbox, root: root).importReady(), [])
    }

    func testSuffixesWhenTheNameIsTaken() throws {
        try phoneSession(files: ["mic.caf", "mic-002.caf"])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name), withIntermediateDirectories: true)

        let imported = InboxImporter(inbox: inbox, root: root).importReady()
        XCTAssertEqual(imported.map(\.lastPathComponent), ["\(name)-2"])
    }

    func testMissingInboxImportsNothing() {
        let importer = InboxImporter(inbox: inbox.appendingPathComponent("nope"), root: root)
        XCTAssertEqual(importer.importReady(), [])
    }

    /// The fixture session in the inbox, with these audio files present.
    private func phoneSession(files: [String]) throws {
        let dir = inbox.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: phoneMeta, to: dir.appendingPathComponent("meta.json"))
        for file in files {
            try Data([0x01]).write(to: dir.appendingPathComponent(file))
        }
    }
}
