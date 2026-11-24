import XCTest
import WhisperKit
@testable import VoicedCore

final class TranscriptionLogicTests: XCTestCase {
    func testSharedCommitPolicyKeepsTrailingSpeechAndDoesNotDuplicateRepeatedDecodes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = RecordingSession(startedAt: start, baseLines: [])
        let assembler = SentenceAssembler(languageCode: "en")
        let segments = [TranscriptionSegment(start: 1, end: 2, text: "Hello."),
                        TranscriptionSegment(start: 3, end: 4, text: "Another sentence.")]
        session.update(segments: segments, assembler: assembler)
        XCTAssertEqual(session.transcript.map(\.text), ["Hello."])
        XCTAssertEqual(session.pendingLines.map(\.text), ["Another sentence."])
        session.update(segments: segments, assembler: assembler)
        XCTAssertEqual(session.transcript.count, 1)
        session.commitTrailing(finalize: assembler.terminated)
        XCTAssertEqual(session.transcript.map(\.text), ["Hello.", "Another sentence."])
        XCTAssertEqual(session.transcript[1].recordedAt, start.addingTimeInterval(3))
        XCTAssertFalse(session.commitTrailing(finalize: assembler.terminated))
    }

    func testOptionsUseTheSameLanguageAndWordTimingPolicyOnBothPlatforms() {
        let pinned = TranscriptionLogic.decodingOptions(for: RecognitionLanguage.choice(id: "ja"), promptTokens: [12, 34])
        XCTAssertEqual(pinned.language, "ja")
        XCTAssertFalse(pinned.detectLanguage)
        XCTAssertTrue(pinned.wordTimestamps)
        XCTAssertEqual(pinned.promptTokens, [12, 34])
        XCTAssertTrue(TranscriptionLogic.decodingOptions(for: .automatic).detectLanguage)
    }

    func testSharedRecordExportUsesTheSameTimestampFunction() {
        let line = TranscriptLine(id: "line", start: 62, end: 65, recordedAt: Date(), text: "你好。")
        let record = TranscriptRecord(lines: [line])
        XCTAssertEqual(record.text, "[01:02] 你好。")
        XCTAssertEqual(record.text, TranscriptionLogic.export(record.lines))
    }
    func testTranslatedExportPreservesTheDesktopDisplayOrder() {
        let line = TranscriptLine(id: "line", start: 0, end: 1, recordedAt: Date(), text: "你好。",
                                  translation: TranslatedText(language: "en", text: "Hello."))
        let text = TranscriptionLogic.export([line]) { line in (line.translation!.text, line.text) }
        XCTAssertEqual(text, "[00:00] Hello.\n你好。")
    }

}
