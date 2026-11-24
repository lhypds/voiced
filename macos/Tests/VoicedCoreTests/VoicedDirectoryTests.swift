import XCTest
@testable import VoicedCore

final class VoicedDirectoryTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var destination: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicedTests.Migration.\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("Application Support/Voiced/History", isDirectory: true)
        destination = root.appendingPathComponent(".voiced/history", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testLayoutLivesUnderDotVoicedInHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(VoicedDirectory.root.path, home + "/.voiced")
        XCTAssertEqual(VoicedDirectory.settingsFile.path, home + "/.voiced/settings.json")
        XCTAssertEqual(VoicedDirectory.historyDirectory.path, home + "/.voiced/history")
        XCTAssertEqual(TranscriptHistoryStore.defaultDirectory, VoicedDirectory.historyDirectory)
    }

    func testLegacyRecordFilesAreMovedForConversion() throws {
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let file = legacy.appendingPathComponent("0021CD86-AC94-41CE-84B1-6371BA3CCB1E.json")
        try Data("{}".utf8).write(to: file)
        try Data("notes".utf8).write(to: legacy.appendingPathComponent("readme.txt"))

        VoicedDirectory.migrateHistory(from: legacy, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(file.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the legacy copy is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("readme.txt").path), "only records are touched")
    }

    func testFileAlreadyAtDestinationWins() throws {
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("a.json"))
        try Data("new".utf8).write(to: destination.appendingPathComponent("a.json"))

        VoicedDirectory.migrateHistory(from: legacy, to: destination)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.json"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("a.json").path))
    }

    func testMissingLegacyDirectoryIsIgnored() {
        VoicedDirectory.migrateHistory(from: legacy, to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
