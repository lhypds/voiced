import XCTest
@testable import Voiced

final class TranscriptLineTests: XCTestCase {
    func testRelativeTimestampFormatting() {
        XCTAssertEqual(line(start: 0).timestamp(mode: .relative, showDate: false), "00:00")
        XCTAssertEqual(line(start: 65.9).timestamp(mode: .relative, showDate: false), "01:05")
        XCTAssertEqual(line(start: 3_661).timestamp(mode: .relative, showDate: false), "01:01:01")
        XCTAssertEqual(line(start: -5).timestamp(mode: .relative, showDate: false), "00:00")
    }

    func testClockTimestampFormatting() {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 18
        components.hour = 9
        components.minute = 5
        components.second = 7
        let date = Calendar.current.date(from: components)!
        let line = TranscriptLine(id: "a", start: 0, end: 1, recordedAt: date, text: "x")

        XCTAssertEqual(line.timestamp(mode: .current, showDate: false), "09:05:07")
        XCTAssertEqual(line.timestamp(mode: .current, showDate: true), "2026-10-18 09:05:07")
    }

    func testMergedKeepsStartAndTakesEnd() {
        let merged = line(start: 1, end: 2, text: "a").merged(with: line(id: "b", start: 2, end: 5, text: "b"), separator: " ")

        XCTAssertEqual(merged.start, 1)
        XCTAssertEqual(merged.end, 5)
        XCTAssertEqual(merged.text, "a b")
        XCTAssertEqual(merged.id, "a|b")
    }

    private func line(id: String = "a", start: Float, end: Float = 1, text: String = "x") -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: Date(), text: text)
    }
}
