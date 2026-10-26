import Foundation

/// One saved transcript in the history. A record is created when a recording starts and updated every
/// time more lines are committed, so it always mirrors what was on screen.
///
/// On disk a record is a directory named by its `id` under `~/.voiced/history`, holding
/// `transcript.json` and the WAV file its recording sessions append to in turn.
struct TranscriptRecord: Identifiable, Equatable, Codable, Sendable {
    /// One start/stop recording cycle that fed this record, and the raw audio it saved.
    struct Session: Codable, Equatable, Sendable {
        var startedAt: Date
        var endedAt: Date?
        var inputDevice: String
        /// Recognition language code, or nil for auto detect.
        var language: String?
        var engine: String
        /// Name of the WAV file in the record's directory, or nil when nothing was captured.
        var audioFile: String?
        /// Where this session starts in `audioFile`, in seconds: sessions of one record share its
        /// file, each appended after the previous one. Nil (zero) for files written before this was tracked.
        var audioOffset: TimeInterval?
    }

    /// Name of the record's directory: the unix time in seconds at which it was started, with a
    /// `-2`-style suffix when two records were started within the same second.
    let id: String
    let createdAt: Date
    var updatedAt: Date
    var lines: [TranscriptLine]
    var sessions: [Session]

    init(
        id: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        lines: [TranscriptLine],
        sessions: [Session] = []
    ) {
        self.id = id ?? Self.directoryName(for: createdAt)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lines = lines
        self.sessions = sessions
    }

    /// Unix time of `date` in whole seconds, the way record directories are named.
    static func directoryName(for date: Date) -> String {
        String(Int(date.timeIntervalSince1970.rounded(.down)))
    }

    /// Opening words of the transcript, used as the title in the history list.
    var preview: String {
        lines.first?.text ?? ""
    }

    /// Where in the saved audio `line` was spoken: the file's name in the record's directory and
    /// the seconds into it. The line belongs to the last session started by the time it was
    /// recorded, and sits `line.start` seconds after that session's start in the file. Nil for a
    /// line recorded outside every session or in one that left no audio behind; a session still
    /// running is not listed yet.
    func audioPosition(of line: TranscriptLine) -> (file: String, time: TimeInterval)? {
        // Dates lose their fraction of a second on disk, so the session's start is compared in
        // whole seconds: the line's own start is always at or after it.
        guard let session = sessions.last(where: { $0.startedAt.timeIntervalSince(line.recordedAt) < 1 }),
              let file = session.audioFile else { return nil }
        if let endedAt = session.endedAt, line.recordedAt.timeIntervalSince(endedAt) >= 1 {
            return nil
        }
        return (file, (session.audioOffset ?? 0) + TimeInterval(max(0, line.start)))
    }

    /// Files written before sessions were tracked have no `sessions` key, and their ids are UUIDs.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lines = try container.decode([TranscriptLine].self, forKey: .lines).withUniqueIDs()
        sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    }
}
