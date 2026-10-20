import Foundation

/// Transcript bookkeeping for one start/stop recording cycle.
///
/// Every decode re-sends all segments for the audio still in the buffer, so the session remembers how far
/// into the audio it has already committed sentences and only appends what lies beyond that point.
/// Committed lines never change.
struct RecordingSession {
    /// Slack when comparing a sentence's start against the committed boundary. The transcriber may
    /// cut the audio up to `LiveTranscriber.cutSearchBefore` earlier than the boundary, so the next
    /// decode's first sentence can start slightly before `committedEnd` and is still new speech.
    private static let overlapTolerance: Float = LiveTranscriber.cutSearchBefore + 0.1

    let startedAt: Date
    /// Lines that were already on screen before this session began.
    private(set) var baseLines: [TranscriptLine]
    /// Sentences from this session that are final and shown in the transcript.
    private(set) var committedLines: [TranscriptLine] = []
    /// End time (seconds since start) of the last committed sentence. Audio before it can be discarded.
    private(set) var committedEnd: Float = 0
    /// Most recent complete sentence list from the stream, including an unfinished trailing sentence.
    private var latestLines: [TranscriptLine] = []

    init(startedAt: Date, baseLines: [TranscriptLine]) {
        self.startedAt = startedAt
        self.baseLines = baseLines
    }

    /// Everything that should currently be displayed.
    var transcript: [TranscriptLine] {
        baseLines + committedLines
    }

    /// Sentences the stream has decoded but that are not committed yet.
    var pendingLines: [TranscriptLine] {
        latestLines.filter(isBeyondCommitted)
    }

    /// Records a new decode. Returns true when at least one new sentence was committed.
    ///
    /// - Parameters:
    ///   - latest: all sentences, including the unfinished one.
    ///   - completed: only sentences that cannot change any more.
    mutating func update(latest: [TranscriptLine], completed: [TranscriptLine]) -> Bool {
        // A decode that finds nothing keeps the previous pending sentences: WhisperKit drops short
        // fragments it cannot make sense of alone, and the pause commit should still catch them.
        if !latest.isEmpty {
            latestLines = latest
        }
        return commit(completed.filter(isBeyondCommitted))
    }

    /// Commits whatever unfinished speech is left, after a pause or when recording stops.
    /// `finalize` is applied to each line, typically to add a sentence terminator.
    /// Returns true when at least one line was committed.
    @discardableResult
    mutating func commitTrailing(finalize: (TranscriptLine) -> TranscriptLine = { $0 }) -> Bool {
        let committed = commit(pendingLines.map(finalize))
        latestLines = []
        return committed
    }

    /// Empties the visible transcript while keeping the committed boundary,
    /// so already-seen sentences are not re-added by the next decode.
    mutating func clearTranscript() {
        baseLines = []
        committedLines = []
        latestLines = []
    }

    private mutating func commit(_ lines: [TranscriptLine]) -> Bool {
        guard let last = lines.last else { return false }
        committedLines.append(contentsOf: lines)
        committedEnd = last.end
        return true
    }

    private func isBeyondCommitted(_ line: TranscriptLine) -> Bool {
        line.start >= committedEnd - Self.overlapTolerance
    }
}
