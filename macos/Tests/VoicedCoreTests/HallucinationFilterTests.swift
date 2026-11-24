import XCTest
@testable import VoicedCore

final class HallucinationFilterTests: XCTestCase {
    func testKnownPhraseAloneIsDropped() {
        XCTAssertEqual(HallucinationFilter.strip("ご視聴ありがとうございました"), "")
        XCTAssertEqual(HallucinationFilter.strip(" ご視聴ありがとうございました。 "), "")
        XCTAssertEqual(HallucinationFilter.strip("Thank you for watching."), "")
        XCTAssertEqual(HallucinationFilter.strip("thank you for watching!"), "")
    }

    func testPhraseInsideRealSpeechIsRemoved() {
        XCTAssertEqual(HallucinationFilter.strip("今日はいい天気ですね ご視聴ありがとうございました"), "今日はいい天気ですね")
        XCTAssertEqual(HallucinationFilter.strip("That is all for now. Thanks for watching"), "That is all for now.")
    }

    func testOrdinarySpeechIsUntouched() {
        XCTAssertEqual(HallucinationFilter.strip("ありがとうございました、助かりました。"), "ありがとうございました、助かりました。")
        XCTAssertEqual(HallucinationFilter.strip("I am watching the game."), "I am watching the game.")
        XCTAssertEqual(HallucinationFilter.strip(""), "")
    }
}
