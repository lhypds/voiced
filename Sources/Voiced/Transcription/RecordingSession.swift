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

    private mutating func commit(_ lines: [TranscriptLine]) -> Bool {
        var added = false
        for line in lines {
            if isRepeatedTail(line) {
                committedEnd = max(committedEnd, line.end)
                continue
            }
            committedLines.append(line)
            committedEnd = line.end
            added = true
        }
        return added
    }

    /// Whether `line` is the end of the last committed line transcribed again. The audio cut after a
    /// commit can leave the tail of the last word in the buffer when the boundary sat a little early,
    /// and the next decode then returns that tail as a short line of its own. Such a line starts
    /// before the committed end, inside the overlap tolerance; a genuine repetition starts after it.
    private func isRepeatedTail(_ line: TranscriptLine) -> Bool {
        guard line.start < committedEnd, let previous = committedLines.last else { return false }
        let tail = Self.letters(of: line.text)
        guard !tail.isEmpty else { return true }
        return Self.letters(of: previous.text).hasSuffix(tail)
    }

    private static func letters(of text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }

    private func isBeyondCommitted(_ line: TranscriptLine) -> Bool {
        line.start >= committedEnd - Self.overlapTolerance
    }
}
