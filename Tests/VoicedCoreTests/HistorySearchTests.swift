import SwiftUI
import XCTest
@testable import VoicedCore

final class HistorySearchTests: XCTestCase {
    private func line(_ id: String, _ text: String, translation: String? = nil) -> TranscriptLine {
        TranscriptLine(
            id: id, start: 0, end: 1, recordedAt: Date(timeIntervalSince1970: 0), text: text,
            translation: translation.map { TranslatedText(language: "en", text: $0) }
        )
    }

    private func record(_ id: String, _ lines: [TranscriptLine]) -> TranscriptRecord {
        TranscriptRecord(id: id, createdAt: Date(timeIntervalSince1970: 0), lines: lines)
    }

    func testBlankQueryFindsNothing() {
        let records = [record("a", [line("1", "Hello")])]
        XCTAssertTrue(HistorySearch.results(in: records, for: "   ").isEmpty)
        XCTAssertNil(HistorySearch.normalized(" \n"))
    }

    func testFindsRecordsByAnyLineIgnoringCaseAndKeepsTheirOrder() {
        let records = [
            record("new", [line("1", "Nothing here"), line("2", "Meet at the STATION"), line("3", "station again")]),
            record("none", [line("4", "Unrelated")]),
            record("old", [line("5", "测试 station")]),
        ]
        let results = HistorySearch.results(in: records, for: " station ")
        XCTAssertEqual(results.map(\.id), ["new", "old"])
        XCTAssertEqual(results[0].firstMatch.id, "2")
        XCTAssertEqual(results[0].matchedText, "Meet at the STATION")
        XCTAssertEqual(results[0].matchCount, 2)
        XCTAssertEqual(results[1].matchCount, 1)
    }

    func testMatchesChineseText() {
        let results = HistorySearch.results(in: [record("a", [line("1", "今天开会讨论预算。")])], for: "预算")
        XCTAssertEqual(results.first?.matchedText, "今天开会讨论预算。")
    }

    func testATranslationMatchShowsTheTranslation() {
        let records = [record("a", [line("1", "你好", translation: "Hello there")])]
        let result = try? XCTUnwrap(HistorySearch.results(in: records, for: "hello").first)
        XCTAssertEqual(result?.matchedText, "Hello there")
    }

    func testHighlightMarksEveryOccurrence() {
        let text = HistorySearch.highlighted("Go go GO", query: "go", color: .orange)
        let marked = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(marked.count, 3)
        XCTAssertEqual(String(text.characters), "Go go GO")
    }
}
