import Foundation
import XCTest
@testable import VoicedCore

final class MobileDataMigrationTests: XCTestCase {
    private struct LegacyRecord: Codable {
        var id: UUID
        var date: Date
        var lines: [TranscriptLine]
    }
    private var root: URL!
    private var legacy: URL { root.appendingPathComponent("history.json") }
    private var store: TranscriptHistoryStore { TranscriptHistoryStore(directory: root.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func fixture() -> LegacyRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return LegacyRecord(id: UUID(), date: date, lines: [TranscriptLine(id: "line", start: 1, end: 3,
            recordedAt: date.addingTimeInterval(1), text: "你好。", translation: TranslatedText(language: "en", text: "Hello."))])
    }

    func testImportsLegacyHistoryAndPreservesBackup() throws {
        let old = fixture()
        let data = try JSONEncoder().encode([old])
        try data.write(to: legacy)
        try MobileDataMigration.importHistory(from: legacy, into: store)
        let imported = try XCTUnwrap(store.load().first)
        XCTAssertEqual(imported.id, old.id.uuidString)
        XCTAssertEqual(imported.createdAt, old.date)
        XCTAssertEqual(imported.lines, old.lines)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathExtension("migrated")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testRepeatedImportNeverOverwritesAnUpdatedRecord() throws {
        let old = fixture()
        try JSONEncoder().encode([old]).write(to: legacy)
        try MobileDataMigration.importHistory(from: legacy, into: store)
        var record = try XCTUnwrap(store.load().first)
        record.lines = [record.lines[0].replacingText("更新后的文字。")]
        try store.save(record)
        // A backup restored by the user must not overwrite a migrated record.
        try JSONEncoder().encode([old]).write(to: legacy)
        try MobileDataMigration.importHistory(from: legacy, into: store)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.lines.first?.text, "更新后的文字。")
    }

    func testCorruptHistoryIsRetainedForRecovery() throws {
        let data = Data("broken json".utf8)
        try data.write(to: legacy)
        XCTAssertThrowsError(try MobileDataMigration.importHistory(from: legacy, into: store))
        XCTAssertEqual(try Data(contentsOf: legacy), data)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testFailedWriteDoesNotArchiveLegacyFile() throws {
        try JSONEncoder().encode([fixture()]).write(to: legacy)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        XCTAssertThrowsError(try MobileDataMigration.importHistory(from: legacy, into: TranscriptHistoryStore(directory: blocked)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testImportsMobileSettingsOnlyOnce() throws {
        let suite = "VoicedCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("accurate", forKey: "ios.engine")
        defaults.set("ja", forKey: "ios.language")
        defaults.set("relative", forKey: "ios.timestamp")
        defaults.set(false, forKey: "ios.showDate")
        let file = root.appendingPathComponent("settings.json")
        MobileDataMigration.importSettings(from: defaults, into: file)
        let settings = AppSettings(fileURL: file)
        XCTAssertEqual(settings.recognitionEngine, .accurate)
        XCTAssertEqual(settings.recognitionLanguage.code, "ja")
        XCTAssertEqual(settings.timestampMode, .relative)
        XCTAssertFalse(settings.showTimestampDate)
        settings.recognitionEngine = .kotoba
        MobileDataMigration.importSettings(from: defaults, into: file)
        XCTAssertEqual(AppSettings(fileURL: file).recognitionEngine, .kotoba)
    }
}
