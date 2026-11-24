import XCTest
@testable import VoicedCore

final class TranscriptRecordTests: XCTestCase {
    func testAudioPositionFollowsTheLineSessionAndItsOffsetInTheFile() {
        let first = session(startedAt: 100, endedAt: 150, audioFile: "100.wav")
        let continued = session(startedAt: 160, endedAt: 170, audioFile: "100.wav", audioOffset: 50)
        let record = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 100), lines: [], sessions: [first, continued])

        let early = record.audioPosition(of: line(recordedAt: 112.5, start: 12.5))
        XCTAssertEqual(early?.file, "100.wav")
        XCTAssertEqual(early?.time ?? -1, 12.5, accuracy: 0.001)

        let later = record.audioPosition(of: line(recordedAt: 163, start: 3))
        XCTAssertEqual(later?.file, "100.wav")
        XCTAssertEqual(later?.time ?? -1, 53, accuracy: 0.001, "the second session's audio follows the first's in the file")
    }

    func testAudioPositionToleratesDatesStoredInWholeSeconds() {
        // On disk both dates lose their fraction: a line 0.3 s into a session started at 100.9
        // reads as recorded at 101, the session as started at 100; a session started at 100.9
        // can also read as 100 against a line recorded at 100.
        let record = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 100), lines: [], sessions: [
            session(startedAt: 101, endedAt: 150, audioFile: "100.wav"),
        ])

        XCTAssertEqual(record.audioPosition(of: line(recordedAt: 100.2, start: 0.3))?.time ?? -1, 0.3, accuracy: 0.001)
        XCTAssertNil(record.audioPosition(of: line(recordedAt: 99, start: 0)), "a line a full second before the session is not its")
    }

    func testAudioPositionIsNilWithoutSavedAudio() {
        let silent = session(startedAt: 100, endedAt: 150, audioFile: nil)
        let recorded = session(startedAt: 200, endedAt: 250, audioFile: "200.wav")
        let record = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 100), lines: [], sessions: [silent, recorded])

        XCTAssertNil(record.audioPosition(of: line(recordedAt: 120, start: 20)), "a session without audio has nothing to play")
        XCTAssertNil(record.audioPosition(of: line(recordedAt: 50, start: 0)), "recorded before any session")
        XCTAssertNil(record.audioPosition(of: line(recordedAt: 300, start: 5)), "recorded after the last session ended, in one not attached yet")
        XCTAssertNotNil(record.audioPosition(of: line(recordedAt: 220, start: 20)))
        XCTAssertNil(TranscriptRecord(lines: []).audioPosition(of: line(recordedAt: 0, start: 0)))
    }

    func testDecodingMakesRepeatedLineIDsUnique() throws {
        let repeated = TranscriptLine(id: "0-8521.88-8521.88", start: 8521.88, end: 8521.88, recordedAt: Date(timeIntervalSince1970: 100), text: "我。")
        let saved = TranscriptRecord(createdAt: Date(timeIntervalSince1970: 100), lines: [repeated, repeated, repeated])

        let loaded = try JSONDecoder().decode(TranscriptRecord.self, from: JSONEncoder().encode(saved))

        XCTAssertEqual(loaded.lines.map(\.id), ["0-8521.88-8521.88", "0-8521.88-8521.88#2", "0-8521.88-8521.88#3"])
        XCTAssertEqual(loaded.lines.map(\.text), ["我。", "我。", "我。"])
    }

    private func session(startedAt: TimeInterval, endedAt: TimeInterval?, audioFile: String?, audioOffset: TimeInterval? = nil) -> TranscriptRecord.Session {
        TranscriptRecord.Session(
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map(Date.init(timeIntervalSince1970:)),
            inputDevice: "Mic", language: "en", engine: "turbo",
            audioFile: audioFile, audioOffset: audioOffset
        )
    }

    private func line(recordedAt: TimeInterval, start: Float) -> TranscriptLine {
        TranscriptLine(id: "\(recordedAt)", start: start, end: start + 1, recordedAt: Date(timeIntervalSince1970: recordedAt), text: "text")
    }
}
