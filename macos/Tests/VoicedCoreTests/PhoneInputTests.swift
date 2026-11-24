import XCTest
@testable import VoicedCore

final class PhoneInputTests: XCTestCase {
    func testMessagesSurviveEncodingAndDecoding() {
        var decoder = PhoneInput.Decoder()
        let data = PhoneInput.encode("你好。") + PhoneInput.encode("Line one\nline two")

        XCTAssertEqual(decoder.feed(data).map(\.text), ["你好。", "Line one\nline two"], "a line break inside a sentence does not end its message")
    }

    func testAMessageSplitAcrossReadsWaitsForItsEnd() {
        var decoder = PhoneInput.Decoder()
        let data = PhoneInput.encode("こんにちは。")
        let middle = data.count / 2

        XCTAssertEqual(decoder.feed(data.prefix(middle)), [])
        XCTAssertEqual(decoder.feed(data.suffix(from: middle)).map(\.text), ["こんにちは。"])
    }

    func testLinesThatAreNotMessagesAreDropped() {
        var decoder = PhoneInput.Decoder()
        let data = Data("garbage\n{\"other\":1}\n".utf8) + PhoneInput.encode("ok")

        XCTAssertEqual(decoder.feed(data).map(\.text), ["ok"])
    }

    func testUnknownFieldsAreIgnored() {
        var decoder = PhoneInput.Decoder()

        XCTAssertEqual(decoder.feed(Data("{\"text\":\"hi\",\"later\":true}\n".utf8)).map(\.text), ["hi"])
    }

    func testLatinSentencesAreFollowedByASpace() {
        XCTAssertEqual(PhoneInput.typedText(for: "Hello there.", pressesReturn: false), "Hello there. ")
        XCTAssertEqual(PhoneInput.typedText(for: "  run the tests ", pressesReturn: false), "run the tests ")
    }

    func testChineseAndJapaneseSentencesAreTypedAsTheyAre() {
        XCTAssertEqual(PhoneInput.typedText(for: "运行测试。", pressesReturn: false), "运行测试。")
        XCTAssertEqual(PhoneInput.typedText(for: "テストを実行して", pressesReturn: false), "テストを実行して")
    }

    func testNothingIsAddedBeforeReturn() {
        XCTAssertEqual(PhoneInput.typedText(for: "Hello there.", pressesReturn: true), "Hello there.")
    }
}
