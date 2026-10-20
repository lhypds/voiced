import XCTest
@testable import Voiced

final class SentenceAssemblerTests: XCTestCase {
    private let latin = SentenceAssembler(languageCode: "en")
    private let cjk = SentenceAssembler(languageCode: "zh")
    private let japanese = SentenceAssembler(languageCode: "ja")

    func testSegmentsMergeUntilTerminalPunctuation() {
        let lines = latin.sentences(from: [
            line("a", 0, 1, "Hello there"),
            line("b", 1, 2, "how are you?"),
            line("c", 2, 3, "Fine."),
        ])

        XCTAssertEqual(lines.map(\.text), ["Hello there how are you?", "Fine."])
        XCTAssertEqual(lines[0].start, 0)
        XCTAssertEqual(lines[0].end, 2)
        XCTAssertEqual(lines[0].id, "a|b")
    }

    func testLongPauseEndsSentenceAndAddsTerminator() {
        let lines = latin.sentences(from: [
            line("a", 0, 1, "First part"),
            line("b", 1 + SentenceAssembler.sentenceGap, 3, "Second part."),
        ])

        XCTAssertEqual(lines.map(\.text), ["First part.", "Second part."])
    }

    func testOverlongSentenceIsClosedWhenNextSegmentArrives() {
        let limit = SentenceAssembler.maxSentenceSeconds
        let lines = latin.sentences(from: [
            line("a", 0, limit - 2, "keeps going"),
            line("b", limit - 2, limit + 1, "and going"),
            line("c", limit + 1, limit + 2, "still"),
        ])

        XCTAssertEqual(lines.map(\.text), ["keeps going.", "and going still"])
    }

    func testCJKUsesFullWidthPunctuation() {
        let lines = cjk.sentences(from: [
            line("a", 0, 1, "你好"),
            line("b", 1.1, 2, "今天天气不错"),
            line("c", 3, 4, "再见。"),
        ])

        XCTAssertEqual(lines.map(\.text), ["你好，今天天气不错。", "再见。"])
    }

    func testTrailingSentenceCanBeExcluded() {
        let segments = [line("a", 0, 1, "Done."), line("b", 1, 2, "Still talking")]

        XCTAssertEqual(latin.sentences(from: segments).map(\.text), ["Done.", "Still talking"])
        XCTAssertEqual(latin.sentences(from: segments, includeTrailing: false).map(\.text), ["Done."])
    }

    func testPunctuatedSentenceAtEndOfAudioIsNotSettled() {
        let single = [line("a", 0, 1, "Done.")]
        XCTAssertEqual(latin.sentences(from: single).map(\.text), ["Done."])
        XCTAssertTrue(latin.sentences(from: single, includeTrailing: false).isEmpty)

        let two = [line("a", 0, 1, "One."), line("b", 1, 2, "Two.")]
        XCTAssertEqual(latin.sentences(from: two, includeTrailing: false).map(\.text), ["One."])
    }

    func testJoiningSeparatorFollowsPrecedingCharacter() {
        XCTAssertEqual(latin.joiningSeparator(after: "word"), " ")
        XCTAssertEqual(cjk.joiningSeparator(after: "word"), " ")
        XCTAssertEqual(cjk.joiningSeparator(after: "中文"), "，")
        XCTAssertEqual(japanese.joiningSeparator(after: "日本語"), "、")
        XCTAssertEqual(latin.joiningSeparator(after: "中文"), "，")
        XCTAssertEqual(latin.joiningSeparator(after: ""), "")
    }

    func testNoExtraCommaAfterExistingPunctuation() {
        XCTAssertEqual(japanese.joiningSeparator(after: "晴れて、"), "")
        XCTAssertEqual(cjk.joiningSeparator(after: "你好，"), "")
        XCTAssertEqual(latin.joiningSeparator(after: "well,"), " ")
        XCTAssertEqual(japanese.sentences(from: [line("a", 0, 1, "晴れて、"), line("b", 1, 2, "暑いです。")]).map(\.text), ["晴れて、暑いです。"])
    }

    func testTerminatedAddsPunctuationOnlyWhenMissing() {
        XCTAssertEqual(latin.terminated(line("a", 0, 1, "Hello")).text, "Hello.")
        XCTAssertEqual(latin.terminated(line("a", 0, 1, "Hello?")).text, "Hello?")
        XCTAssertEqual(cjk.terminated(line("a", 0, 1, "你好")).text, "你好。")
    }

    func testDraftTrimsAndDropsEmptyParts() {
        XCTAssertEqual(latin.draft(from: ["  hello ", "", "world"]), "hello world")
        XCTAssertEqual(latin.draft(from: ["", "   "]), "")
    }

    private func line(_ id: String, _ start: Float, _ end: Float, _ text: String) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: Date(timeIntervalSince1970: 0), text: text)
    }
}
