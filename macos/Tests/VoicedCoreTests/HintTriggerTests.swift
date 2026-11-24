import XCTest
@testable import VoicedCore

@MainActor
final class HintTriggerTests: XCTestCase {
    func testEverydaySpeechIsNotSent() {
        for text in [
            "我们明天下午三点开会吧。",
            "今天天气不错，我们去公园散步。",
            "Let's meet tomorrow at three in the afternoon.",
            "I think that went well, thanks everyone.",
            "明日の午後三時に会いましょう。",
            "",
        ] {
            XCTAssertNil(HintTrigger.reason(for: text), text)
        }
    }

    func testQuestionsAreSent() {
        for text in [
            "蒙古的首都是哪里？",
            "你觉得这样行吗",
            "为什么会这样",
            "What is the capital of Mongolia?",
            "Why does it take so long",
            "これは何ですか",
            "Pourquoi est-ce si long ?",
        ] {
            XCTAssertEqual(HintTrigger.reason(for: text), .question, text)
        }
    }

    func testLatinWordsInsideCJKTextAreSent() {
        XCTAssertEqual(HintTrigger.reason(for: "数据存放在一棵 Merkle 树里。"), .foreignWord)
        XCTAssertNil(HintTrigger.reason(for: "这个 app 还不错。"), "a short everyday word is not a term")
    }

    func testCodeLikeTokensAreSent() {
        XCTAssertEqual(HintTrigger.reason(for: "We deployed it on an H100 yesterday."), .codeLikeToken)
        XCTAssertEqual(HintTrigger.reason(for: "跑在 CUDA 上面。"), .codeLikeToken)
        XCTAssertEqual(HintTrigger.reason(for: "It only runs on macOS for now."), .codeLikeToken)
        XCTAssertNil(HintTrigger.reason(for: "It costs 12 dollars, OK."), "plain numbers and two-letter words are not tokens")
    }

    func testLongKatakanaWordsAreSent() {
        XCTAssertEqual(HintTrigger.reason(for: "データはマークルツリーに保存されます。"), .katakanaWord)
        XCTAssertNil(HintTrigger.reason(for: "レストランに行きましょう。"), "everyday loanwords are short")
    }

    func testNamesAreSent() {
        XCTAssertEqual(HintTrigger.reason(for: "昨天我见到了成吉思汗的雕像。"), .name)
        XCTAssertEqual(HintTrigger.reason(for: "这个用到了傅里叶变换。"), .name)
        XCTAssertNotNil(HintTrigger.reason(for: "Have you read the book by Daniel Kahneman."))
    }

    func testWordsTheSpellCheckerDoesNotKnowAreSent() {
        XCTAssertNotNil(HintTrigger.reason(for: "The data lives in a merkle tree."))
    }
}
