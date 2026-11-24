import Foundation

/// Transcript bookkeeping for one start/stop recording cycle.
///
/// Every decode re-sends all segments for the audio still in the buffer, so the session remembers how far
/// into the audio it has already committed sentences and only appends what lies beyond that point.
/// Committed lines never change.
public struct RecordingSession {
    /// Slack when comparing a sentence's start against the committed boundary. The transcriber may
    /// cut the audio up to `LiveTranscriber.cutSearchBefore` earlier than the boundary, so the next
    /// decode's first sentence can start slightly before `committedEnd` and is still new speech.
    private static let overlapTolerance: Float = LiveTranscriber.cutSearchBefore + 0.1

    public let startedAt: Date
    /// Lines that were already on screen before this session began.
    public private(set) var baseLines: [TranscriptLine]
    /// Sentences from this session that are final and shown in the transcript.
    public private(set) var committedLines: [TranscriptLine] = []
    /// End time (seconds since start) of the last committed sentence. Audio before it can be discarded.
    public private(set) var committedEnd: Float = 0
    /// Most recent complete sentence list from the stream, including an unfinished trailing sentence.
    private var latestLines: [TranscriptLine] = []

    public init(startedAt: Date, baseLines: [TranscriptLine]) {
        self.startedAt = startedAt
        self.baseLines = baseLines
    }

    /// Everything that should currently be displayed.
    public var transcript: [TranscriptLine] {
        baseLines + committedLines
    }

    /// Sentences the stream has decoded but that are not committed yet.
    public var pendingLines: [TranscriptLine] {
        latestLines.filter(isBeyondCommitted)
    }

    /// Records a new decode. Returns true when at least one new sentence was committed.
    ///
    /// - Parameters:
    ///   - latest: all sentences, including the unfinished one.
    ///   - completed: only sentences that cannot change any more.
    public mutating func update(latest: [TranscriptLine], completed: [TranscriptLine]) -> Bool {
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
    public mutating func commitTrailing(finalize: (TranscriptLine) -> TranscriptLine = { $0 }) -> Bool {
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
            committedLines.append(uniquelyIdentified(line))
            committedEnd = line.end
            added = true
        }
        return added
    }

    /// Whether `line` is committed speech transcribed again. The audio cut after a commit can leave
    /// the tail of the last word in the buffer when the boundary sat a little early, and the next
    /// decode then returns that tail as a short line of its own. Such a line starts before the
    /// committed end, inside the overlap tolerance; a genuine repetition starts after it. A line
    /// that also ends by the committed end covers no new audio at all, whatever it says: the
    /// decoder sometimes stamps a hallucinated word with no duration right at the cut, and every
    /// decode of the buffer after it returns that same word again.
    private func isRepeatedTail(_ line: TranscriptLine) -> Bool {
        guard let previous = committedLines.last else { return false }
        if line.end <= committedEnd { return true }
        guard line.start < committedEnd else { return false }
        let tail = Self.letters(of: line.text)
        guard !tail.isEmpty else { return true }
        return Self.letters(of: previous.text).hasSuffix(tail)
    }

    /// `line` with an id no line of the transcript has yet. Ids are built from the decode's
    /// segment numbers and times, which start over with every session of a record, so a resumed
    /// record can meet the same id twice; two rows with one id share their state on screen.
    private func uniquelyIdentified(_ line: TranscriptLine) -> TranscriptLine {
        let taken = Set(transcript.map(\.id))
        guard taken.contains(line.id) else { return line }
        var attempt = 2
        while taken.contains("\(line.id)#\(attempt)") { attempt += 1 }
        return line.replacingID("\(line.id)#\(attempt)")
    }

    private static func letters(of text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }

    private func isBeyondCommitted(_ line: TranscriptLine) -> Bool {
        line.start >= committedEnd - Self.overlapTolerance
    }
}
