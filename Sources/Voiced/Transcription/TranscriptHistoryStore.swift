import Foundation

/// Persists transcript records as one directory per record inside the history directory.
///
/// ```
/// history/
///   1760950000/              record id: unix time of its start
///     transcript.json        lines and sessions
///     1760950000.wav         raw audio of each session, named by the session's start
///     summary.txt            the transcript summarized by the AI service, once asked for
/// ```
///
/// The default directory is `~/.voiced/history`. Directories without a readable transcript are
/// skipped rather than failing the whole load.
struct TranscriptHistoryStore {
    static let transcriptFileName = "transcript.json"
    static let summaryFileName = "summary.txt"

    let directory: URL

    init(directory: URL = TranscriptHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL { VoicedDirectory.historyDirectory }

    /// All stored records, most recently updated first.
    func load() -> [TranscriptRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        let decoder = Self.makeDecoder()
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.transcriptFileName)),
                      let stored = try? decoder.decode(TranscriptRecord.self, from: data)
                else { return nil }
                // The directory name is the identity; the file's id is only a copy of it.
                return TranscriptRecord(
                    id: folder.lastPathComponent,
                    createdAt: stored.createdAt,
                    updatedAt: stored.updatedAt,
                    lines: stored.lines,
                    sessions: stored.sessions
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ record: TranscriptRecord) throws {
        let folder = recordDirectory(id: record.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(record)
        try data.write(to: folder.appendingPathComponent(Self.transcriptFileName), options: .atomic)
    }

    /// Removes the record's directory with everything in it, including the audio.
    func delete(id: String) throws {
        let folder = recordDirectory(id: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Removes the record's directory only when it holds nothing.
    func deleteIfEmpty(id: String) {
        let folder = recordDirectory(id: id)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func recordDirectory(id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    func summaryFile(id: String) -> URL {
        recordDirectory(id: id).appendingPathComponent(Self.summaryFileName)
    }

    func hasSummary(id: String) -> Bool {
        FileManager.default.fileExists(atPath: summaryFile(id: id).path)
    }

    /// Writes the record's summary next to its transcript, replacing an earlier one.
    func saveSummary(_ text: String, id: String) throws {
        try FileManager.default.createDirectory(at: recordDirectory(id: id), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: summaryFile(id: id), options: .atomic)
    }

    /// The id for a record started at `date` that no directory uses yet.
    func unusedID(startedAt date: Date) -> String {
        let name = TranscriptRecord.directoryName(for: date)
        var candidate = name
        var attempt = 1
        while FileManager.default.fileExists(atPath: recordDirectory(id: candidate).path) {
            attempt += 1
            candidate = "\(name)-\(attempt)"
        }
        return candidate
    }

    /// Converts records stored as flat `<uuid>.json` files by earlier versions into directories named by
    /// their start time. Files that cannot be decoded are left where they are.
    func migrateFlatFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let decoder = Self.makeDecoder()
        let flat = entries
            .filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .compactMap { file -> (URL, TranscriptRecord)? in
                guard let data = try? Data(contentsOf: file), let record = try? decoder.decode(TranscriptRecord.self, from: data) else { return nil }
                return (file, record)
            }
            .sorted { $0.1.createdAt < $1.1.createdAt }
        for (file, legacy) in flat {
            let record = TranscriptRecord(
                id: unusedID(startedAt: legacy.createdAt),
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                lines: legacy.lines,
                sessions: legacy.sessions
            )
            guard (try? save(record)) != nil else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
