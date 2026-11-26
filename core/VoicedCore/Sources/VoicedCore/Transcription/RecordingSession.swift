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

    /// Drops a line the user deleted from what is displayed. What it said stays committed, so a
    /// later decode does not bring it back.
    public mutating func removeLine(id: String) {
        baseLines.removeAll { $0.id == id }
        committedLines.removeAll { $0.id == id }
    }

    /// Gives the line `id` new text, as edited by hand. Its translation goes with the old text.
    public mutating func replaceText(ofLine id: String, with text: String) {
        if let index = baseLines.firstIndex(where: { $0.id == id }) { baseLines[index] = baseLines[index].replacingText(text) }
        if let index = committedLines.firstIndex(where: { $0.id == id }) { committedLines[index] = committedLines[index].replacingText(text) }
    }

    /// Adds a line that was typed rather than spoken, after the committed ones. It covers no
    /// audio, so where the session has committed to stays where it is.
    public mutating func appendTyped(_ line: TranscriptLine) {
        committedLines.append(uniquelyIdentified(line))
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

    /// The uncommitted part of `lines` joined into one line, or nil when none of it is new.
    /// `join` builds the text from the parts.
    public func merged(_ lines: [TranscriptLine], join: ([String]) -> String) -> TranscriptLine? {
        let new = lines.filter(isBeyondCommitted).filter { !isRepeatedTail($0) }
        guard let first = new.first, let last = new.last else { return nil }
        let text = join(new.map(\.text))
        guard !text.isEmpty else { return nil }
        return TranscriptLine(id: first.id, start: first.start, end: last.end, recordedAt: first.recordedAt, text: text)
    }

    /// Commits the uncommitted part of `lines` as a single line, however many sentences it holds,
    /// and drops whatever else is pending. Used for what is said while the iPhone's microphone is
    /// held, which goes to the Mac as one piece. Returns the committed line.
    @discardableResult
    public mutating func commitMerged(_ lines: [TranscriptLine], join: ([String]) -> String,
                                      finalize: (TranscriptLine) -> TranscriptLine = { $0 }) -> TranscriptLine? {
        defer { latestLines = [] }
        guard let line = merged(lines, join: join) else { return nil }
        let final = uniquelyIdentified(finalize(line))
        committedLines.append(final)
        committedEnd = max(committedEnd, final.end)
        return final
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
