import XCTest
@testable import Voiced

final class AppLanguageTests: XCTestCase {
    func testFirstSupportedPreferredLanguageWins() {
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["ko-KR", "fr-FR", "en"]), .french)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["es-419"]), .spanish)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["de-CH"]), .german)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["EN-GB"]), .english)
    }

    func testFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["ko-KR", "ru-RU"]), .english)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: []), .english)
    }
}
