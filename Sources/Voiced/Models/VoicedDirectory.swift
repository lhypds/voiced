import Foundation

/// Everything Voiced keeps on disk lives under `~/.voiced`:
///
/// ```
/// ~/.voiced/
///   settings.json             user preferences
///   prompt.txt                recognition prompt: words the recognizer should prefer
///   noise-profile.json        background noise spectrum for noise reduction
///   history/<unix time>/      one directory per record (see `TranscriptHistoryStore`)
///     transcript.json         lines and recording sessions
///     <unix time>.wav         raw audio of each session
/// ```
enum VoicedDirectory {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voiced", isDirectory: true)
    static let settingsFile = root.appendingPathComponent("settings.json")
    static let promptFile = root.appendingPathComponent("prompt.txt")
    static let noiseProfileFile = root.appendingPathComponent("noise-profile.json")
    static let historyDirectory = root.appendingPathComponent("history", isDirectory: true)

    /// Where versions before `~/.voiced` kept the history.
    static var legacyHistoryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Voiced/History", isDirectory: true)
    }

    /// Brings data written by earlier versions into `~/.voiced`: history records from Application Support,
    /// records stored as flat files, and preferences from `UserDefaults`. Safe to run on every launch;
    /// it is a no-op once nothing is left to move.
    static func migrateLegacyData() {
        migrateHistory(from: legacyHistoryDirectory, to: historyDirectory)
        TranscriptHistoryStore(directory: historyDirectory).migrateFlatFiles()
        AppSettings.importLegacyDefaults(.standard, into: settingsFile)
    }

    /// Moves every flat record file out of `legacy` into `destination`, where `migrateFlatFiles` picks
    /// them up. A file that already exists at the destination is dropped instead.
    static func migrateHistory(from legacy: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        let records = files.filter { $0.pathExtension == "json" }
        guard !records.isEmpty else { return }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in records {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: file)
            } else {
                try? fileManager.moveItem(at: file, to: target)
            }
        }
    }
}
