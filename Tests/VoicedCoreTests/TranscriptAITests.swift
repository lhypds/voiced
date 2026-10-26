import Foundation
import XCTest
@testable import VoicedCore

private actor HintServiceStub: TranscriptHinting {
    var calls: [[TranscriptLine]] = []
    var contexts: [[TranscriptLine]] = []
    var languages: [AppLanguage] = []
    var continuation: CheckedContinuation<[TranscriptHint], Error>?
    let delayed: Bool
    init(delayed: Bool = false) { self.delayed = delayed }
    func hints(for newLines: [TranscriptLine], context: [TranscriptLine], explained: [String], in language: AppLanguage) async throws -> [TranscriptHint] {
        calls.append(newLines)
        contexts.append(context)
        languages.append(language)
        if delayed { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return [TranscriptHint(lineID: newLines[0].id, topic: "Topic", text: "Answer")]
    }
    func release() {
        continuation?.resume(returning: [TranscriptHint(lineID: calls[0][0].id, topic: "Old", text: "Late answer")])
        continuation = nil
    }
}

private actor SummaryServiceStub: TranscriptSummarizing {
    var calls = 0
    var languages: [AppLanguage] = []
    var continuation: CheckedContinuation<String, Error>?
    let delayed: Bool
    init(delayed: Bool = false) { self.delayed = delayed }
    func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String {
        calls += 1
        languages.append(language)
        if delayed { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return "Saved summary"
    }
    func release() { continuation?.resume(returning: "Late summary"); continuation = nil }
}

@MainActor
final class TranscriptAITests: XCTestCase {
    private func line(_ id: String, _ text: String = "什么是 SwiftUI？") -> TranscriptLine {
        TranscriptLine(id: id, start: 0, end: 2, recordedAt: Date(), text: text)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
    private func waitForHint(_ stub: HintServiceStub) async {
        for _ in 0..<200 { if await !stub.calls.isEmpty { return }; await Task.yield() }
        XCTFail("Hint service did not start")
    }

    func testHintsNeedOptInAndKeyAndDoNotUploadExistingText() async {
        let stub = HintServiceStub()
        let service = TranscriptAI(makeHintProvider: { _, _, _ in stub })
        let old = line("old")
        service.update([old])
        service.configure(.init(hintsEnabled: true), existingLines: [old])
        service.update([old])
        await settle()
        let firstCalls = await stub.calls.count
        XCTAssertEqual(firstCalls, 0)
        service.configure(.init(apiKey: "test", hintsEnabled: true, hintLanguage: .japanese), existingLines: [old])
        service.update([old])
        await settle()
        let secondCalls = await stub.calls.count
        XCTAssertEqual(secondCalls, 0)
        let new = line("new")
        service.update([old, new])
        await waitForHint(stub)
        await settle()
        let calls = await stub.calls
        let context = await stub.contexts
        let languages = await stub.languages
        XCTAssertEqual(calls.map { $0.map(\.id) }, [["new"]])
        XCTAssertEqual(context[0].map(\.id), ["old"])
        XCTAssertEqual(languages, [.japanese])
        service.update([old, new])
        await settle()
        let finalCount = await stub.calls.count
        XCTAssertEqual(finalCount, 1)
    }

    func testResetRejectsAnAnswerFromThePreviousRecord() async {
        let stub = HintServiceStub(delayed: true)
        let service = TranscriptAI(makeHintProvider: { _, _, _ in stub })
        service.configure(.init(apiKey: "test", hintsEnabled: true), existingLines: [])
        service.update([line("old")])
        await waitForHint(stub)
        service.reset(existingLines: [line("resumed")])
        await stub.release()
        await settle()
        XCTAssertTrue(service.hints.isEmpty)
        XCTAssertNil(service.hintError)
        service.update([line("resumed")])
        await settle()
        let calls = await stub.calls.count
        XCTAssertEqual(calls, 1)
    }

    func testDisablingHintsRejectsLateAnswers() async {
        let stub = HintServiceStub(delayed: true)
        let service = TranscriptAI(makeHintProvider: { _, _, _ in stub })
        service.configure(.init(apiKey: "test", hintsEnabled: true), existingLines: [])
        service.update([line("line")])
        await waitForHint(stub)
        service.configure(.init(apiKey: "test", hintsEnabled: false), existingLines: [line("line")])
        await stub.release()
        await settle()
        XCTAssertTrue(service.hints.isEmpty)
    }

    func testExplicitSummarySavesBesideTheRecordAndRespectsItsSwitch() async throws {
        let stub = SummaryServiceStub()
        let service = TranscriptAI(makeSummarizer: { _, _ in stub })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(lines: [line("line")])
        try store.save(record)
        let disabled = await service.summarize(record, apiKey: "test", model: "custom", language: .chinese, enabled: false, store: store)
        XCTAssertNil(disabled)
        let count = await stub.calls
        XCTAssertEqual(count, 0)
        let summary = await service.summarize(record, apiKey: "test", model: "custom", language: .chinese, enabled: true, store: store)
        XCTAssertEqual(summary, "Saved summary")
        XCTAssertEqual(try String(contentsOf: store.summaryFile(id: record.id), encoding: .utf8), "Saved summary")
        XCTAssertTrue(service.summarizingRecordIDs.isEmpty)
        let languages = await stub.languages
        XCTAssertEqual(languages, [.chinese])
    }

    func testDeletingARecordCannotRecreateItWithALateSummary() async throws {
        let stub = SummaryServiceStub(delayed: true)
        let service = TranscriptAI(makeSummarizer: { _, _ in stub })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranscriptHistoryStore(directory: directory)
        let record = TranscriptRecord(lines: [line("line")])
        try store.save(record)
        let task = Task { await service.summarize(record, apiKey: "test", model: "custom", language: .english, enabled: true, store: store) }
        for _ in 0..<200 { if await stub.calls > 0 { break }; await Task.yield() }
        service.forget(recordID: record.id)
        try store.delete(id: record.id)
        await stub.release()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordDirectory(id: record.id).path))
        XCTAssertTrue(service.summarizingRecordIDs.isEmpty)
    }
    func testHintConfigurationForwardsKeyModelSearchAndLanguage() async {
        let stub = HintServiceStub()
        var captured: (String, String, Bool)?
        let service = TranscriptAI(makeHintProvider: { key, model, web in captured = (key, model, web); return stub })
        service.configure(.init(apiKey: "  test-key  ", hintsEnabled: true, hintModel: "  custom-model  ",
                                webSearch: true, hintLanguage: .french), existingLines: [])
        service.update([line("question")])
        await waitForHint(stub)
        await settle()
        XCTAssertEqual(captured?.0, "test-key")
        XCTAssertEqual(captured?.1, "custom-model")
        XCTAssertEqual(captured?.2, true)
        let languages = await stub.languages
        XCTAssertEqual(languages, [.french])
    }

}
