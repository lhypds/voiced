import XCTest
@testable import Voiced

final class PunctuationNormalizerTests: XCTestCase {
    func testScriptIsDecidedFromText() {
        XCTAssertEqual(PunctuationNormalizer.script(of: "今日は晴れ", languageCode: nil), .japanese)
        XCTAssertEqual(PunctuationNormalizer.script(of: "今天天气", languageCode: nil), .chinese)
        XCTAssertEqual(PunctuationNormalizer.script(of: "東京", languageCode: "ja"), .japanese)
        XCTAssertEqual(PunctuationNormalizer.script(of: "東京", languageCode: "zh"), .chinese)
        XCTAssertEqual(PunctuationNormalizer.script(of: "Hello", languageCode: "zh"), .latin)
        XCTAssertEqual(PunctuationNormalizer.script(of: "안녕하세요", languageCode: nil), .latin)
    }

    func testChineseGetsFullWidthMarks() {
        XCTAssertEqual(PunctuationNormalizer.normalize("你好, 世界. 怎么样?", languageCode: nil), "你好，世界。怎么样？")
        XCTAssertEqual(PunctuationNormalizer.normalize("你好、世界！", languageCode: "zh"), "你好、世界！")
        XCTAssertEqual(PunctuationNormalizer.normalize("等一下...", languageCode: "zh"), "等一下……")
        XCTAssertEqual(PunctuationNormalizer.normalize("他说: 好的; 走吧 (现在)", languageCode: nil), "他说：好的；走吧 （现在）")
    }

    func testJapaneseUsesIdeographicComma() {
        XCTAssertEqual(PunctuationNormalizer.normalize("今日は, 晴れです.", languageCode: nil), "今日は、晴れです。")
        XCTAssertEqual(PunctuationNormalizer.normalize("今日は，晴れです。", languageCode: nil), "今日は、晴れです。")
        XCTAssertEqual(PunctuationNormalizer.normalize("東京, 大阪", languageCode: "ja"), "東京、大阪")
    }

    func testNumbersAndLatinWordsInsideCJKKeepASCIIMarks() {
        XCTAssertEqual(PunctuationNormalizer.normalize("价格是3.14, 共1,000元.", languageCode: nil), "价格是3.14，共1,000元。")
        XCTAssertEqual(PunctuationNormalizer.normalize("请访问example.com.", languageCode: nil), "请访问example.com。")
    }

    func testLatinGetsHalfWidthMarks() {
        XCTAssertEqual(PunctuationNormalizer.normalize("Hello，world。", languageCode: nil), "Hello, world.")
        XCTAssertEqual(PunctuationNormalizer.normalize("Really？Yes！", languageCode: "zh"), "Really? Yes!")
        XCTAssertEqual(PunctuationNormalizer.normalize("Wait……", languageCode: nil), "Wait...")
        XCTAssertEqual(PunctuationNormalizer.normalize("Hello, world.", languageCode: nil), "Hello, world.")
        XCTAssertEqual(PunctuationNormalizer.normalize("note（here）ok", languageCode: nil), "note (here) ok")
    }

    func testAssemblerNormalizesSegmentsAndDraft() {
        let auto = SentenceAssembler(languageCode: nil)
        let lines = auto.sentences(from: [
            line("a", 0, 1, "你好,"),
            line("b", 1, 2, "世界."),
            line("c", 3, 4, "Hello，world。"),
        ])
        XCTAssertEqual(lines.map(\.text), ["你好，世界。", "Hello, world."])
        XCTAssertEqual(auto.draft(from: ["今日は,", "晴れ"]), "今日は、晴れ")
        XCTAssertEqual(auto.terminated(line("d", 0, 1, "日本語")).text, "日本語。")
        XCTAssertEqual(auto.terminated(line("e", 0, 1, "English")).text, "English.")
    }

    private func line(_ id: String, _ start: Float, _ end: Float, _ text: String) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: Date(timeIntervalSince1970: 0), text: text)
    }
}
