import XCTest
@testable import Voiced

final class TranscriptHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicedTests.History.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testLoadFromMissingDirectoryIsEmpty() {
        XCTAssertEqual(TranscriptHistoryStore(directory: directory).load(), [])
    }

    func testRecordsLiveInDirectoriesNamedByStartTime() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 1_700_000_000.7), lines: [line("a", "first")])

        try store.save(record)

        XCTAssertEqual(record.id, "1700000000")
        XCTAssertEqual(store.recordDirectory(id: record.id).path, directory.appendingPathComponent("1700000000").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1700000000/transcript.json").path))
    }

    func testRecordsRoundTripAndSortNewestFirst() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let session = TranscriptRecord.Session(
            startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 150),
            inputDevice: "Mic", language: "ja", engine: "turbo", audioFile: "100.wav"
        )
        let older = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 100), lines: [line("a", "first")], sessions: [session])
        let newer = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 200), lines: [line("b", "second"), line("c", "third")])

        try store.save(older)
        try store.save(newer)

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), [newer.id, older.id])
        XCTAssertEqual(loaded.last, older)
        XCTAssertEqual(loaded.last?.sessions, [session])
        XCTAssertEqual(loaded.first?.preview, "second")
    }

    func testSavingAgainReplacesTheRecord() throws {
        let store = TranscriptHistoryStore(directory: directory)
        var record = TranscriptRecord(lines: [line("a", "first")])
        try store.save(record)

        record.lines.append(line("b", "second"))
        record.updatedAt = Date()
        try store.save(record)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.lines.count, 2)
    }

    func testDeleteRemovesTheDirectoryWithItsAudio() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(lines: [line("a", "first")])
        try store.save(record)
        let audio = store.recordDirectory(id: record.id).appendingPathComponent("\(record.id).wav")
        try Data([0, 1, 2]).write(to: audio)

        try store.delete(id: record.id)

        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertNoThrow(try store.delete(id: record.id))
    }

    func testDeleteIfEmptyKeepsDirectoriesWithContent() throws {
        let store = TranscriptHistoryStore(directory: directory)
        try FileManager.default.createDirectory(at: store.recordDirectory(id: "1"), withIntermediateDirectories: true)
        try store.save(TranscriptRecord(id: "2", lines: []))

        store.deleteIfEmpty(id: "1")
        store.deleteIfEmpty(id: "2")
        store.deleteIfEmpty(id: "3")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordDirectory(id: "1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordDirectory(id: "2").path))
    }

    func testUnusedIDAddsSuffixWhenTheSecondIsTaken() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(store.unusedID(startedAt: date), "1700000000")

        try store.save(TranscriptRecord(createdAt: date, lines: []))
        XCTAssertEqual(store.unusedID(startedAt: date), "1700000000-2")

        try store.save(TranscriptRecord(id: "1700000000-2", createdAt: date, lines: []))
        XCTAssertEqual(store.unusedID(startedAt: date.addingTimeInterval(0.9)), "1700000000-3")
    }

    func testDirectoryNameWinsOverTheStoredID() throws {
        let store = TranscriptHistoryStore(directory: directory)
        try store.save(TranscriptRecord(id: "renamed-later", lines: [line("a", "first")]))
        try FileManager.default.moveItem(at: store.recordDirectory(id: "renamed-later"), to: store.recordDirectory(id: "1700000000"))

        XCTAssertEqual(store.load().map(\.id), ["1700000000"])
    }

    func testUnreadableDirectoriesAndStrayFilesAreSkipped() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(lines: [line("a", "first")])
        try store.save(record)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken/transcript.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("audio-only"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: directory.appendingPathComponent("stray.txt"))

        XCTAssertEqual(store.load().map(\.id), [record.id])
    }

    func testFlatFilesAreMigratedIntoDirectories() throws {
        let store = TranscriptHistoryStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {"id": "0021CD86-AC94-41CE-84B1-6371BA3CCB1E", "createdAt": "2023-11-14T22:13:20Z", "updatedAt": "2023-11-14T22:20:00Z",
         "lines": [{"id": "a", "start": 0, "end": 1, "recordedAt": "2023-11-14T22:13:20Z", "text": "hello"}]}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("0021CD86-AC94-41CE-84B1-6371BA3CCB1E.json"))
        try Data(legacy.replacingOccurrences(of: "0021CD86", with: "11111111").utf8)
            .write(to: directory.appendingPathComponent("11111111-AC94-41CE-84B1-6371BA3CCB1E.json"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        store.migrateFlatFiles()

        let loaded = store.load()
        XCTAssertEqual(Set(loaded.map(\.id)), ["1700000000", "1700000000-2"], "same second: the second one gets a suffix")
        XCTAssertEqual(loaded.first?.lines.first?.text, "hello")
        XCTAssertEqual(loaded.first?.updatedAt, Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertEqual(loaded.first?.sessions, [])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(remaining, ["broken.json"], "migrated files are removed, undecodable ones stay")

        store.migrateFlatFiles()
        XCTAssertEqual(store.load().count, 2, "running again changes nothing")
    }

    private func line(_ id: String, _ text: String) -> TranscriptLine {
        TranscriptLine(id: id, start: 0, end: 1, recordedAt: Date(timeIntervalSince1970: 0), text: text)
    }
}
