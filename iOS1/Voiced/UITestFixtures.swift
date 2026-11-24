#if DEBUG
import Foundation
import VoicedCore

/// UI tests use a fresh sandbox subdirectory and in-memory services. No real API key,
/// network request, model download, microphone capture or user history is involved.
@MainActor
enum UITestFixtures {
    static func makeModelIfRequested() -> MobileTranscriber? {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoicedUITests-\(UUID().uuidString)")
        let settings = AppSettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.appLanguage = .chinese
        settings.openAIAPIKey = "ui-test-key"
        settings.aiHints = false
        let store = TranscriptHistoryStore(directory: directory.appendingPathComponent("history"))
        let now = Date()
        let line = TranscriptLine(id: "fixture-line", start: 0, end: 1, recordedAt: now, text: "这是一条测试转写。")
        let record = TranscriptRecord(id: "fixture", createdAt: now, lines: [line], sessions: [
            TranscriptRecord.Session(startedAt: now, endedAt: now.addingTimeInterval(5), inputDevice: "test",
                                     language: "zh", engine: "turbo", audioFile: "sample.wav", audioOffset: 0)
        ])
        try? store.save(record)
        if let writer = try? WAVWriter(url: store.recordDirectory(id: record.id).appendingPathComponent("sample.wav"), sampleRate: 16_000) {
            try? writer.append([Float](repeating: 0, count: 80_000))
            writer.close()
        }
        let ai = TranscriptAI(makeHintProvider: { _, _, _ in HintStub() }, makeSummarizer: { _, _ in SummaryStub() })
        let model = MobileTranscriber(directory: directory, aiService: ai, translationService: TranslationStub())
        model.resume(record)
        if ProcessInfo.processInfo.arguments.contains("--ui-hints") {
            model.aiHintsEnabled = true
            let new = TranscriptLine(id: "new-question", start: 2, end: 4, recordedAt: now, text: "什么是 SwiftUI？")
            model.current.lines.append(new)
            model.ai.update(model.current.lines)
        }
        let empty = ProcessInfo.processInfo.arguments.contains("--ui-empty")
        if empty { model.newRecord() }
        if ProcessInfo.processInfo.arguments.contains("--ui-recording") {
            model.recording = true
            if !empty { model.liveText = "正在识别的实时文字。" }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-loading") {
            model.newRecord()
            model.busy = true
            model.loadingStartedAt = Date().addingTimeInterval(-2)
            model.loadingComponent = .audioEncoder
            model.status = model.strings.loadingModel(.audioEncoder)
        }
        return model
    }

    private struct HintStub: TranscriptHinting {
        func hints(for newLines: [TranscriptLine], context: [TranscriptLine], explained: [String], in language: AppLanguage) async throws -> [TranscriptHint] {
            [TranscriptHint(lineID: newLines[0].id, topic: "SwiftUI", text: "这是测试 AI 提示。")]
        }
    }
    private struct SummaryStub: TranscriptSummarizing {
        func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String { "这是测试摘要。" }
    }
    private final class TranslationStub: SentenceTranslating {
        func setPairs(_ pairs: [LanguagePair]) {}
        func translate(_ text: String, pair: LanguagePair) async throws -> TranslatedText { TranslatedText(language: pair.target, text: "Test translation.") }
    }
}
#endif
