#if DEBUG
import Foundation
import VoicedCore
import WhisperKit

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
        // The fixture line stands for one just recognized, so it is translated like one.
        model.adoptIntoConversation(model.current.lines)
        if ProcessInfo.processInfo.arguments.contains("--ui-hints") {
            model.aiHintsEnabled = true
            let new = TranscriptLine(id: "new-question", start: 2, end: 4, recordedAt: now, text: "什么是 SwiftUI？")
            model.current.lines.append(new)
            model.ai.update(model.current.lines)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-many-lines") {
            // Enough lines to run on under the microphone, for checking the list's edges.
            model.current.lines += (1...14).map { index in
                TranscriptLine(id: "many-\(index)", start: Float(index), end: Float(index) + 1,
                               recordedAt: now.addingTimeInterval(TimeInterval(index)), text: "第 \(index) 句测试转写，用来填满屏幕。")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-mac-line") {
            // The fixture line as one sent to the Mac, and a tap that plays it.
            model.current.macDeliveries = [line.id: true]
            model.lineClickAction = .play
        }
        let empty = ProcessInfo.processInfo.arguments.contains("--ui-empty")
        if empty { model.newRecord() }
        if ProcessInfo.processInfo.arguments.contains("--ui-send-to-mac") { model.sendToMacEnabled = true }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-claude"), index + 2 < arguments.count {
            // Run mode in a folder on the Mac, and a line to send: `--ui-claude <folder> <prompt>`.
            model.sendToMacEnabled = true
            model.sendToMacMode = .claude
            model.claudeFolder = arguments[index + 1]
            model.current.lines.append(TranscriptLine(id: "claude-line", start: 2, end: 3, recordedAt: now.addingTimeInterval(2),
                                                      text: arguments[index + 2]))
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-recording") {
            model.recording = true
            if !empty { model.liveText = "正在识别的实时文字。" }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-loading") {
            model.newRecord()
            model.busy = true
            model.modelLoading = true
            model.loadingStartedAt = Date().addingTimeInterval(-2)
            model.loadingComponent = .audioEncoder
            model.status = model.strings.loadingModel(.audioEncoder)
        }
        return model
    }

    /// The capture recordings use: the microphone, or with `--ui-audio-file <path>` a 16 kHz mono
    /// WAV fed in at real-time pace, for end-to-end runs where no microphone reaches the simulator.
    static func makeCapture() -> AudioCapturing {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-audio-file"), index + 1 < arguments.count,
              let capture = FileAudioCapture(url: URL(fileURLWithPath: arguments[index + 1])) else { return AudioCapture() }
        return capture
    }

    /// Plays a WAV file as if it were the microphone: 100 ms chunks in real time from `start`,
    /// then silence until stopped.
    final class FileAudioCapture: AudioCapturing, @unchecked Sendable {
        private let samples: [Float]
        private var timer: DispatchSourceTimer?
        private var position = 0
        private let queue = DispatchQueue(label: "voiced.ui-test.file-capture")

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
            // A canonical PCM WAV: find the "data" chunk and read 16-bit little-endian samples.
            guard let range = data.range(of: Data("data".utf8)) else { return nil }
            let start = range.upperBound + 4
            samples = stride(from: start, to: data.count - 1, by: 2).map { offset in
                Float(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)) / 32768
            }
        }

        func start(deviceID: DeviceID?, onChunk: @escaping ([Float]) -> Void) throws {
            let chunk = 1600
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let end = min(self.position + chunk, self.samples.count)
                var piece = self.position < end ? Array(self.samples[self.position..<end]) : []
                piece += [Float](repeating: 0, count: chunk - piece.count)
                self.position += chunk
                onChunk(piece)
            }
            self.timer = timer
            timer.resume()
        }

        func pause() { timer?.suspend() }
        func resume() throws { timer?.resume() }
        func stop() { timer?.cancel(); timer = nil }
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
