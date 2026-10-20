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

    func testRecordsRoundTripAndSortNewestFirst() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let older = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 100), lines: [line("a", "first")])
        let newer = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 200), lines: [line("b", "second"), line("c", "third")])

        try store.save(older)
        try store.save(newer)

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), [newer.id, older.id])
        XCTAssertEqual(loaded.last?.lines, older.lines)
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

    func testDeleteRemovesTheRecord() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(lines: [line("a", "first")])
        try store.save(record)

        try store.delete(id: record.id)
        XCTAssertEqual(store.load(), [])
        XCTAssertNoThrow(try store.delete(id: record.id))
    }

    func testUndecodableFilesAreSkipped() throws {
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(lines: [line("a", "first")])
        try store.save(record)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        XCTAssertEqual(store.load().map(\.id), [record.id])
    }

    private func line(_ id: String, _ text: String) -> TranscriptLine {
        TranscriptLine(id: id, start: 0, end: 1, recordedAt: Date(timeIntervalSince1970: 0), text: text)
    }
}
