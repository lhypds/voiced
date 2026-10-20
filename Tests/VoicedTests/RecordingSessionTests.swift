import XCTest
@testable import Voiced

final class RecordingSessionTests: XCTestCase {
    func testTranscriptStartsWithBaseLines() {
        let base = [line("old", 0, 1, "Earlier.")]
        let session = RecordingSession(startedAt: Date(), baseLines: base)

        XCTAssertEqual(session.transcript, base)
        XCTAssertEqual(session.committedEnd, 0)
    }

    func testUpdateCommitsOnlyNewCompletedLines() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let first = line("a", 0, 2, "One.")
        let second = line("b", 2, 4, "Two.")

        XCTAssertTrue(session.update(latest: [first], completed: [first]))
        XCTAssertEqual(session.committedEnd, 2)
        XCTAssertFalse(session.update(latest: [first], completed: [first]), "re-sent lines must not be committed twice")
        XCTAssertTrue(session.update(latest: [first, second], completed: [first, second]))
        XCTAssertEqual(session.transcript.map(\.text), ["One.", "Two."])
        XCTAssertEqual(session.committedEnd, 4)
    }

    func testPendingLinesAreTheUncommittedTail() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let done = line("a", 0, 2, "Done.")
        let trailing = line("b", 2, 3, "Still talking")

        _ = session.update(latest: [done, trailing], completed: [done])

        XCTAssertEqual(session.pendingLines.map(\.text), ["Still talking"])
        XCTAssertEqual(session.transcript.map(\.text), ["Done."])
    }

    func testEmptyDecodeKeepsPendingLines() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let pending = line("a", 0, 1, "if the weather")
        _ = session.update(latest: [pending], completed: [])

        XCTAssertFalse(session.update(latest: [], completed: []))

        XCTAssertEqual(session.pendingLines.map(\.text), ["if the weather"])
        XCTAssertTrue(session.commitTrailing())
        XCTAssertEqual(session.transcript.map(\.text), ["if the weather"])
    }

    func testCommitTrailingFinalizesUnfinishedSpeech() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let done = line("a", 0, 2, "Done.")
        let trailing = line("b", 2, 3, "Still talking")
        _ = session.update(latest: [done, trailing], completed: [done])

        XCTAssertTrue(session.commitTrailing { $0.replacingText($0.text + ".") })

        XCTAssertEqual(session.transcript.map(\.text), ["Done.", "Still talking."])
        XCTAssertEqual(session.committedEnd, 3)
        XCTAssertTrue(session.pendingLines.isEmpty)
        XCTAssertFalse(session.commitTrailing(), "nothing left to commit")
    }

    func testCommittedLinesSurviveALaterDecodeOfTheSameAudio() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let pending = line("a", 0, 2, "Hello there")
        _ = session.update(latest: [pending], completed: [])
        _ = session.commitTrailing { $0.replacingText($0.text + ".") }

        // A decode that was in flight during the commit may still mention the old audio.
        let revised = line("a2", 0, 2, "Hello here")
        let next = line("b", 3, 4, "Next.")
        XCTAssertTrue(session.update(latest: [revised, next], completed: [revised, next]))

        XCTAssertEqual(session.transcript.map(\.text), ["Hello there.", "Next."])
    }

    func testClearDoesNotResurrectCommittedLines() {
        var session = RecordingSession(startedAt: Date(), baseLines: [line("old", 0, 1, "Earlier.")])
        let first = line("a", 0, 2, "One.")
        _ = session.update(latest: [first], completed: [first])

        session.clearTranscript()
        XCTAssertTrue(session.transcript.isEmpty)

        XCTAssertFalse(session.update(latest: [first], completed: [first]))
        XCTAssertTrue(session.transcript.isEmpty)

        let second = line("b", 2, 4, "Two.")
        XCTAssertTrue(session.update(latest: [first, second], completed: [first, second]))
        XCTAssertEqual(session.transcript.map(\.text), ["Two."])
    }

    private func line(_ id: String, _ start: Float, _ end: Float, _ text: String) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: Date(timeIntervalSince1970: 0), text: text)
    }
}

final class RecordingSessionRepeatedTailTests: XCTestCase {
    func testTailOfThePreviousLineTranscribedAgainIsDropped() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let first = line("a", 0, 5.0, "还有施工标志等等。")
        _ = session.update(latest: [first], completed: [first])

        // The cut left the end of 等等 in the buffer; it came back starting before the committed end.
        let tail = line("b", 4.7, 5.3, "等等。")
        XCTAssertFalse(session.update(latest: [first, tail], completed: [first, tail]))

        XCTAssertEqual(session.transcript.map(\.text), ["还有施工标志等等。"])
        XCTAssertEqual(session.committedEnd, 5.3, "the repeated tail still advances the cut")
    }

    func testGenuineRepetitionAfterTheCommittedEndIsKept() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let first = line("a", 0, 2, "好。")
        _ = session.update(latest: [first], completed: [first])

        let again = line("b", 2.5, 3, "好。")
        XCTAssertTrue(session.update(latest: [first, again], completed: [first, again]))
        XCTAssertEqual(session.transcript.map(\.text), ["好。", "好。"])
    }

    func testDifferentTextStartingInsideTheToleranceIsKept() {
        var session = RecordingSession(startedAt: Date(), baseLines: [])
        let first = line("a", 0, 5, "那不仅代码量会非常大。")
        _ = session.update(latest: [first], completed: [first])

        let next = line("b", 4.8, 7, "车载的算力也不够用。")
        XCTAssertTrue(session.update(latest: [first, next], completed: [first, next]))
        XCTAssertEqual(session.transcript.count, 2)
    }

    private func line(_ id: String, _ start: Float, _ end: Float, _ text: String) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: Date(timeIntervalSince1970: 0), text: text)
    }
}
