import CoreML
import XCTest
@testable import VoicedCore

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

    func testDroppingRowsMovesLaterRowsToTheTop() throws {
        // 4 rows of 3 columns, each value 10 * row + column.
        let weights = try MLMultiArray(shape: [4, 3], dataType: .float16)
        for row in 0..<4 {
            for column in 0..<3 {
                weights[[NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: 10 * row + column)
            }
        }

        let shifted = try LanguageLimitedDecoder.droppingRows(1, of: weights)

        XCTAssertEqual(shifted.shape, [4, 3])
        XCTAssertEqual(shifted[[0, 0]].floatValue, 10)
        XCTAssertEqual(shifted[[2, 2]].floatValue, 32)
        XCTAssertEqual(shifted[[3, 1]].floatValue, 0, "rows past the end are cleared")
        XCTAssertEqual(weights[[0, 0]].floatValue, 0, "the original is left alone")
    }

    func testDroppingNoRowsKeepsTheWeights() throws {
        let weights = try MLMultiArray(shape: [2, 2], dataType: .float16)
        XCTAssertTrue(try LanguageLimitedDecoder.droppingRows(0, of: weights) === weights)
    }
}
