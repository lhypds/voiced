import XCTest
@testable import VoicedCore

final class TranslationRuleTests: XCTestCase {
    private let chineseToJapanese = TranslationRule(source: .chinese, target: .japanese)
    private let japaneseToEnglish = TranslationRule(source: .japanese, target: .english)
    private let anyToChinese = TranslationRule(source: nil, target: .chinese)

    func testARuleNamingTheLanguageWins() {
        let rules = [anyToChinese, chineseToJapanese, japaneseToEnglish]

        XCTAssertEqual(rules.rule(for: "zh"), chineseToJapanese, "a named rule beats an earlier rule for any language")
        XCTAssertEqual(rules.rule(for: "ja"), japaneseToEnglish)
        XCTAssertEqual(rules.rule(for: "fr"), anyToChinese)
    }

    func testTheFirstNamedRuleIsUsed() {
        let chineseToFrench = TranslationRule(source: .chinese, target: .french)
        XCTAssertEqual([chineseToJapanese, chineseToFrench].rule(for: "zh"), chineseToJapanese)
    }

    func testLinesAlreadyInTheTargetAreLeftAlone() {
        XCTAssertNil([anyToChinese].rule(for: "zh"))
        XCTAssertNil([TranslationRule(source: .chinese, target: .chinese)].rule(for: "zh"))
    }

    func testUnmatchedAndUnknownLanguages() {
        XCTAssertNil([chineseToJapanese].rule(for: "fr"), "no rule for French and none for any language")
        XCTAssertNil([chineseToJapanese].rule(for: nil), "a line of unknown language fits no named rule")
        XCTAssertEqual([chineseToJapanese, anyToChinese].rule(for: nil), anyToChinese)
    }

    func testRepeatedSourcesKeepOnlyTheFirstRule() {
        let chineseToFrench = TranslationRule(source: .chinese, target: .french)
        let anyToEnglish = TranslationRule(source: nil, target: .english)
        XCTAssertEqual(
            [chineseToJapanese, anyToChinese, chineseToFrench, anyToEnglish, japaneseToEnglish].withoutRepeatedSources,
            [chineseToJapanese, anyToChinese, japaneseToEnglish]
        )
    }

    func testStoredFormRoundTrips() {
        XCTAssertEqual(chineseToJapanese.stored, ["source": "chinese", "target": "japanese"])
        XCTAssertEqual(anyToChinese.stored, ["target": "chinese"])

        let decoded = TranslationRule(stored: chineseToJapanese.stored)
        XCTAssertEqual(decoded?.source, .chinese)
        XCTAssertEqual(decoded?.target, .japanese)
        XCTAssertNil(TranslationRule(stored: ["target": "chinese"])?.source)
    }

    func testUnknownStoredLanguagesDropTheRule() {
        XCTAssertNil(TranslationRule(stored: ["source": "klingon", "target": "chinese"]), "must not widen to any language")
        XCTAssertNil(TranslationRule(stored: ["source": "chinese", "target": "klingon"]))
        XCTAssertNil(TranslationRule(stored: [:]))
    }

    func testLineLanguageDetection() {
        XCTAssertEqual(LineLanguage.code(of: "今天我们来讨论一下这个项目的进度。"), "zh")
        XCTAssertEqual(LineLanguage.code(of: "今日はこのプロジェクトの進み具合について話しましょう。"), "ja")
        XCTAssertEqual(LineLanguage.code(of: "Let's talk about how this project is going today."), "en")
        XCTAssertNil(LineLanguage.code(of: ""))
    }
}
