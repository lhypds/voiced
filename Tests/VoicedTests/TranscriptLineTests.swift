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

    // MARK: - Translation

    func testTranslationIsDroppedWhenTheTextChanges() {
        let translated = line(start: 0, text: "Hello.").translated(TranslatedText(language: "zh", text: "你好。"))
        XCTAssertEqual(translated.translation?.text, "你好。")

        XCTAssertNil(translated.replacingText("Hello!").translation, "the translation belonged to the old text")
        XCTAssertNil(translated.merged(with: line(id: "b", start: 1, text: "Bye."), separator: " ").translation)
        XCTAssertEqual(translated.replacingText("Hello!").id, translated.id)
    }

    func testNeedsTranslationUntilTranslatedIntoThatLanguage() {
        let plain = line(start: 0, text: "Hello.")
        XCTAssertTrue(plain.needsTranslation(into: "zh"))

        let translated = plain.translated(TranslatedText(language: "zh", text: "你好。"))
        XCTAssertFalse(translated.needsTranslation(into: "zh"))
        XCTAssertTrue(translated.needsTranslation(into: "ja"), "a translation into another language does not count")

        let sameLanguage = plain.translated(TranslatedText(language: "en", text: ""))
        XCTAssertFalse(sameLanguage.needsTranslation(into: "en"), "a line found to be in the target language is not retried")
        XCTAssertNil(sameLanguage.translation?.displayText)
    }

    func testTranslatedTextKeepsOnlyRealTranslations() {
        XCTAssertEqual(
            TranslatedText.from(original: "Hello.", translated: " 你好。\n", sourceLanguage: "en", targetLanguage: "zh"),
            TranslatedText(language: "zh", text: "你好。")
        )
        XCTAssertEqual(
            TranslatedText.from(original: "Hello.", translated: "Hello.", sourceLanguage: "en", targetLanguage: "en").text, "",
            "speech already in the target language shows no second text"
        )
        XCTAssertEqual(
            TranslatedText.from(original: "OK.", translated: "OK.", sourceLanguage: "fr", targetLanguage: "en").text, "",
            "an unchanged answer is not shown twice"
        )
        XCTAssertEqual(
            TranslatedText.from(original: "Hello.", translated: "Bonjour.", sourceLanguage: nil, targetLanguage: "fr").text,
            "Bonjour.",
            "an unknown source language does not block the translation"
        )
    }

    func testKeepingTranslationsCarriesThemOntoRebuiltLines() {
        let translation = TranslatedText(language: "zh", text: "你好。")
        let shown = [
            line(id: "a", start: 0, text: "Hello.").translated(translation),
            line(id: "b", start: 1, text: "Bye.").translated(TranslatedText(language: "zh", text: "再见。")),
        ]
        let rebuilt = [
            line(id: "a", start: 0, text: "Hello."),
            line(id: "b", start: 1, text: "Bye!"),
            line(id: "c", start: 2, text: "New."),
        ]

        let kept = rebuilt.keepingTranslations(from: shown)

        XCTAssertEqual(kept.map(\.translation), [translation, nil, nil], "only a line with the same id and text keeps its translation")
        XCTAssertEqual(kept.map(\.text), ["Hello.", "Bye!", "New."])
    }

    func testLinesWithoutTranslationDecodeAndTranslationsRoundTrip() throws {
        let legacy = Data(#"{"id":"a","start":0,"end":1,"recordedAt":0,"text":"Hello."}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptLine.self, from: legacy)
        XCTAssertNil(decoded.translation)

        let translated = decoded.translated(TranslatedText(language: "ja", text: "こんにちは。"))
        let data = try JSONEncoder().encode(translated)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptLine.self, from: data), translated)
        let plain = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("translation"), "untranslated lines are written as before")
    }

    private func line(id: String = "a", start: Float, end: Float = 1, text: String = "x") -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: Date(), text: text)
    }
}
