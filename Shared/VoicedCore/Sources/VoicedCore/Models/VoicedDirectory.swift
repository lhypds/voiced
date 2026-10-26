import Foundation

/// Shared data layout: `~/.voiced` on macOS, Application Support/Voiced in the iOS sandbox.
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
public enum VoicedDirectory {
    public static let root: URL = {
        #if os(iOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voiced", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voiced", isDirectory: true)
        #endif
    }()
    public static let settingsFile = root.appendingPathComponent("settings.json")
    public static let promptFile = root.appendingPathComponent("prompt.txt")
    public static let noiseProfileFile = root.appendingPathComponent("noise-profile.json")
    public static let historyDirectory = root.appendingPathComponent("history", isDirectory: true)

    /// Where versions before `~/.voiced` kept the history.
    public static var legacyHistoryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? root
        return base.appendingPathComponent("Voiced/History", isDirectory: true)
    }

    /// Brings data written by earlier versions into `~/.voiced`: history records from Application Support,
    /// records stored as flat files, and preferences from `UserDefaults`. Safe to run on every launch;
    /// it is a no-op once nothing is left to move.
    public static func migrateLegacyData() {
        #if os(macOS)
        migrateHistory(from: legacyHistoryDirectory, to: historyDirectory)
        TranscriptHistoryStore(directory: historyDirectory).migrateFlatFiles()
        AppSettings.importLegacyDefaults(.standard, into: settingsFile)
        #endif
    }

    /// Moves every flat record file out of `legacy` into `destination`, where `migrateFlatFiles` picks
    /// them up. A file that already exists at the destination is dropped instead.
    public static func migrateHistory(from legacy: URL, to destination: URL) {
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
