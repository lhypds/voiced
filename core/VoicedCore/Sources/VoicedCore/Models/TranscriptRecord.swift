import Foundation

/// One saved transcript in the history. A record is created when a recording starts and updated every
/// time more lines are committed, so it always mirrors what was on screen.
///
/// On disk a record is a directory named by its `id` under `~/.voiced/history`, holding
/// `transcript.json` and the WAV file its recording sessions append to in turn.
public struct TranscriptRecord: Identifiable, Equatable, Codable, Sendable {
    /// One start/stop recording cycle that fed this record, and the raw audio it saved.
    public struct Session: Codable, Equatable, Sendable {
        public init(startedAt: Date, endedAt: Date? = nil, inputDevice: String, language: String?, engine: String, audioFile: String? = nil, audioOffset: TimeInterval? = nil) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.inputDevice = inputDevice
            self.language = language
            self.engine = engine
            self.audioFile = audioFile
            self.audioOffset = audioOffset
        }

        public var startedAt: Date
        public var endedAt: Date?
        public var inputDevice: String
        /// Recognition language code, or nil for auto detect.
        public var language: String?
        public var engine: String
        /// Name of the WAV file in the record's directory, or nil when nothing was captured.
        public var audioFile: String?
        /// Where this session starts in `audioFile`, in seconds: sessions of one record share its
        /// file, each appended after the previous one. Nil (zero) for files written before this was tracked.
        public var audioOffset: TimeInterval?
    }

    /// Name of the record's directory: the unix time in seconds at which it was started, with a
    /// `-2`-style suffix when two records were started within the same second.
    public let id: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lines: [TranscriptLine]
    public var sessions: [Session]
    /// The lines the iPhone sent to the Mac while its microphone was held, by line id: true when
    /// the sentence went out, false when no Mac was connected. Nil for records with none, and for
    /// files written before this existed.
    public var macDeliveries: [String: Bool]?

    public init(
        id: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        lines: [TranscriptLine],
        sessions: [Session] = [],
        macDeliveries: [String: Bool]? = nil
    ) {
        self.id = id ?? Self.directoryName(for: createdAt)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lines = lines
        self.sessions = sessions
        self.macDeliveries = macDeliveries
    }

    /// Unix time of `date` in whole seconds, the way record directories are named.
    public static func directoryName(for date: Date) -> String {
        String(Int(date.timeIntervalSince1970.rounded(.down)))
    }

    /// Opening words of the transcript, used as the title in the history list.
    /// Plain-text export used by the mobile share sheet and other clients.
    public var text: String { TranscriptionLogic.export(lines) }

    public var preview: String {
        lines.first?.text ?? ""
    }

    /// Where in the saved audio `line` was spoken: the file's name in the record's directory and
    /// the seconds into it. The line belongs to the last session started by the time it was
    /// recorded, and sits `line.start` seconds after that session's start in the file. Nil for a
    /// line recorded outside every session or in one that left no audio behind; a session still
    /// running is not listed yet.
    public func audioPosition(of line: TranscriptLine) -> (file: String, time: TimeInterval)? {
        // Dates lose their fraction of a second on disk, so the session's start is compared in
        // whole seconds: the line's own start is always at or after it.
        guard let session = sessions.last(where: { $0.startedAt.timeIntervalSince(line.recordedAt) < 1 }),
              let file = session.audioFile else { return nil }
        if let endedAt = session.endedAt, line.recordedAt.timeIntervalSince(endedAt) >= 1 {
            return nil
        }
        return (file, (session.audioOffset ?? 0) + TimeInterval(max(0, line.start)))
    }

    /// Where `line`'s audio ends in its session's file: its start there plus the line's length,
    /// with a little more so the last word's fading tail is not cut. Nil without saved audio.
    public func audioEnd(of line: TranscriptLine) -> TimeInterval? {
        audioPosition(of: line).map { $0.time + TimeInterval(max(0, line.end - line.start)) + 0.3 }
    }

    /// Files written before sessions were tracked have no `sessions` key, and their ids are UUIDs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lines = try container.decode([TranscriptLine].self, forKey: .lines).withUniqueIDs()
        sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        macDeliveries = try container.decodeIfPresent([String: Bool].self, forKey: .macDeliveries)
    }
}
