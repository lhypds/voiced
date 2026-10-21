import XCTest
@testable import Voiced

final class LanguageLimitedDecoderTests: XCTestCase {
    func testPicksTheAllowedLanguageWithTheHighestLogit() {
        // Welsh would win overall; only Chinese and English are candidates.
        let logits: [Int: Float] = [1: 2.0, 2: 3.5, 3: 9.0]
        let picked = LanguageLimitedDecoder.mostLikely(of: [("zh", 1), ("en", 2)]) { logits[$0] ?? -.infinity }
        XCTAssertEqual(picked, "en")
    }

    func testNoCandidatesPicksNothing() {
        XCTAssertNil(LanguageLimitedDecoder.mostLikely(of: []) { _ in 0 })
    }
}
