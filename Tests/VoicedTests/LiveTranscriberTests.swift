import XCTest
@testable import Voiced
import WhisperKit

final class LiveTranscriberTests: XCTestCase {
    private let rate = 16_000
    private let floor: Float = 0.02

    func testDecodeInputKeepsShortMarginsAroundSpeech() {
        // 3 s of silence, 2 s of speech, 3 s of silence.
        let buffer = silence(3) + tone(2) + silence(3)

        let (samples, lead) = LiveTranscriber.decodeInput(buffer, floor: floor)

        XCTAssertEqual(lead, 2.5, accuracy: 0.001, "half a second before the first speech frame is kept")
        XCTAssertEqual(Float(samples.count) / Float(rate), 3.0, accuracy: 0.001, "half a second after the last speech frame is kept")
        XCTAssertEqual(samples, Array(buffer[(rate * 5 / 2)..<(rate * 11 / 2)]))
    }

    func testDecodeInputWithoutSpeechIsTheWholeBuffer() {
        let buffer = silence(2)

        let (samples, lead) = LiveTranscriber.decodeInput(buffer, floor: floor)

        XCTAssertEqual(lead, 0)
        XCTAssertEqual(samples.count, buffer.count)
    }

    func testDecodeInputNearTheEdgesIsClamped() {
        let buffer = tone(1) + silence(0.2)

        let (samples, lead) = LiveTranscriber.decodeInput(buffer, floor: floor)

        XCTAssertEqual(lead, 0)
        XCTAssertEqual(samples.count, buffer.count)
    }

    private func silence(_ seconds: Float) -> ContiguousArray<Float> {
        ContiguousArray(repeating: 0, count: Int(seconds * Float(rate)))
    }

    private func tone(_ seconds: Float) -> ContiguousArray<Float> {
        ContiguousArray((0..<Int(seconds * Float(rate))).map { 0.3 * sin(Float($0) * 2 * .pi * 440 / Float(rate)) })
    }
}

final class SegmentSplittingTests: XCTestCase {
    func testSegmentIsSplitAfterEveryPunctuatedWord() {
        let segment = TranscriptionSegment(start: 10, end: 16, text: "你好，今天很热。再见", words: [
            word("你", 10.0, 10.3), word("好，", 10.3, 10.8),
            word("今", 11.0, 11.2), word("天", 11.2, 11.5), word("很", 11.5, 11.8), word("热。", 11.8, 12.5),
            word("再", 14.0, 14.4), word("见", 14.4, 15.0),
        ])

        let pieces = LiveTranscriber.splitAtPunctuation(segment)

        XCTAssertEqual(pieces.map(\.text), ["你好，", "今天很热。", "再见"])
        XCTAssertEqual(pieces.map(\.start), [10.0, 11.0, 14.0])
        XCTAssertEqual(pieces.map(\.end), [10.8, 12.5, 15.0])
    }

    func testLatinWordsKeepTheirSpacesInsideAPiece() {
        let segment = TranscriptionSegment(start: 0, end: 3, text: " Hello there. Bye", words: [
            word(" Hello", 0.0, 0.5), word(" there.", 0.5, 1.2), word(" Bye", 2.0, 2.6),
        ])

        XCTAssertEqual(LiveTranscriber.splitAtPunctuation(segment).map(\.text), ["Hello there.", "Bye"])
    }

    func testSegmentWithoutWordTimingsOrOutOfOrderTimingsStaysWhole() {
        let plain = TranscriptionSegment(start: 0, end: 3, text: "a. b")
        XCTAssertEqual(LiveTranscriber.splitAtPunctuation(plain).map(\.text), ["a. b"])

        let disordered = TranscriptionSegment(start: 0, end: 3, text: "a. b", words: [word("a.", 2.0, 2.5), word(" b", 0.0, 0.5)])
        XCTAssertEqual(LiveTranscriber.splitAtPunctuation(disordered).map(\.text), ["a. b"])
    }

    func testSinglePieceIsNotSplit() {
        let segment = TranscriptionSegment(start: 0, end: 2, text: "你好。", words: [word("你", 0, 0.5), word("好。", 0.5, 1.0)])
        XCTAssertEqual(LiveTranscriber.splitAtPunctuation(segment).map(\.text), ["你好。"])
    }

    private func word(_ text: String, _ start: Float, _ end: Float) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: end, probability: 1)
    }
}

final class CutPointTests: XCTestCase {
    private let rate = 16_000

    func testPauseJustAfterTheBoundaryIsUsed() {
        // Speech until 2.2 s, then silence. The boundary (an early word timing) is at 2.0 s.
        let samples = tone(2.2) + silence(1.0)
        let cut = LiveTranscriber.quietestCut(in: samples, around: 2 * rate)
        XCTAssertEqual(Float(cut) / Float(rate), 2.2, accuracy: 0.03)
    }

    func testPauseBeforeTheBoundaryIsUsed() {
        // Speech, a 0.3 s pause, then the next word; the boundary sits 0.1 s into that word.
        let samples = tone(2.0) + silence(0.3) + tone(1.0)
        let cut = LiveTranscriber.quietestCut(in: samples, around: Int(2.4 * Float(rate)))
        XCTAssertEqual(Float(cut) / Float(rate), 2.0, accuracy: 0.03)
    }

    func testWithoutAPauseTheQuietestFrameBeforeTheBoundaryIsUsed() {
        // Continuous tone with one quiet 40 ms dip at 1.7 s; boundary at 2.0 s.
        var samples = tone(3.0)
        for i in Int(1.7 * Float(rate))..<Int(1.74 * Float(rate)) { samples[i] *= 0.1 }
        let cut = LiveTranscriber.quietestCut(in: samples, around: 2 * rate)
        XCTAssertEqual(Float(cut) / Float(rate), 1.7, accuracy: 0.03)
    }

    func testQuietFrameWellAfterTheBoundaryIsNotUsedAsFallback() {
        // A dip 0.3 s after the boundary would be inside the next word; it must be ignored.
        var samples = tone(3.0)
        for i in Int(2.3 * Float(rate))..<Int(2.34 * Float(rate)) { samples[i] *= 0.1 }
        let cut = LiveTranscriber.quietestCut(in: samples, around: 2 * rate)
        XCTAssertLessThanOrEqual(Float(cut) / Float(rate), 2.1 + 0.03)
    }

    private func silence(_ seconds: Float) -> ContiguousArray<Float> {
        ContiguousArray(repeating: 0, count: Int(seconds * Float(rate)))
    }

    private func tone(_ seconds: Float) -> ContiguousArray<Float> {
        ContiguousArray((0..<Int(seconds * Float(rate))).map { 0.3 * sin(Float($0) * 2 * .pi * 440 / Float(rate)) })
    }
}
