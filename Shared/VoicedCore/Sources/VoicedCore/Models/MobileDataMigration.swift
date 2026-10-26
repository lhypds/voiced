import Foundation

/// Imports the first iOS version's data into the same settings and record format as macOS.
/// URL/defaults injection also lets migration be tested without touching the user's data.
public enum MobileDataMigration {
    private struct LegacyRecord: Decodable {
        let id: UUID
        let date: Date
        let lines: [TranscriptLine]
    }

    public static func importHistory(from file: URL, into store: TranscriptHistoryStore) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return }
        let legacy = try JSONDecoder().decode([LegacyRecord].self, from: Data(contentsOf: file))
        let existing = Set(store.load().map(\.id))
        for old in legacy where !existing.contains(old.id.uuidString) {
            try store.save(TranscriptRecord(id: old.id.uuidString, createdAt: old.date, lines: old.lines))
        }
        // Keep the original as a backup, and only archive it after every record was saved.
        let backup = file.appendingPathExtension("migrated")
        if !manager.fileExists(atPath: backup.path) { try manager.moveItem(at: file, to: backup) }
    }

    public static func importSettings(from defaults: UserDefaults, into file: URL) {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let settings = AppSettings(fileURL: file)
        settings.recognitionEngine = RecognitionEngine(rawValue: defaults.string(forKey: "ios.engine") ?? "") ?? .turbo
        settings.recognitionLanguage = RecognitionLanguage.choice(id: defaults.string(forKey: "ios.language"))
        settings.timestampMode = TimestampMode(rawValue: defaults.string(forKey: "ios.timestamp") ?? "") ?? .current
        settings.showTimestampDate = defaults.object(forKey: "ios.showDate") as? Bool ?? true
    }
}
