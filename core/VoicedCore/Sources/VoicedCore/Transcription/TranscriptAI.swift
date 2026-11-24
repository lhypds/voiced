import Combine
import Foundation

/// One request policy and lifecycle for both native apps. Merely creating/configuring this
/// service never sends a transcript: hints require opt-in, summaries require an explicit call.
@MainActor
public final class TranscriptAI: ObservableObject {
    public struct Configuration: Equatable {
        public var apiKey: String
        public var hintsEnabled: Bool
        public var hintModel: String
        public var webSearch: Bool
        public var hintLanguage: AppLanguage
        public init(apiKey: String = "", hintsEnabled: Bool = false, hintModel: String = OpenAIChatCompletion.defaultModel,
                    webSearch: Bool = false, hintLanguage: AppLanguage = .systemDefault) {
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.hintsEnabled = hintsEnabled
            self.hintModel = OpenAIChatCompletion.modelName(hintModel)
            self.webSearch = webSearch
            self.hintLanguage = hintLanguage
        }
    }

    @Published public private(set) var hints: [TranscriptHint] = []
    @Published public private(set) var hintError: String?
    @Published public private(set) var summarizingRecordIDs: Set<String> = []
    @Published public private(set) var summaryErrors: [String: String] = [:]
    private var configuration = Configuration()
    private var lines: [TranscriptLine] = []
    private var judged: Set<String> = []
    private var explained: [String] = []
    private var hintTask: Task<Void, Never>?
    private var hintGeneration = UUID()
    private var summaryTokens: [String: UUID] = [:]
    private var summaryTasks: [String: Task<String?, Never>] = [:]
    private let makeHintProvider: (String, String, Bool) -> any TranscriptHinting
    private let makeSummarizer: (String, String) -> any TranscriptSummarizing

    public init(
        makeHintProvider: @escaping (String, String, Bool) -> any TranscriptHinting = { OpenAIHintProvider(apiKey: $0, model: $1, webSearch: $2) },
        makeSummarizer: @escaping (String, String) -> any TranscriptSummarizing = { OpenAISummarizer(apiKey: $0, model: $1) }
    ) {
        self.makeHintProvider = makeHintProvider
        self.makeSummarizer = makeSummarizer
    }

    public func configure(_ wanted: Configuration, existingLines: [TranscriptLine]) {
        guard wanted != configuration else { return }
        let enabling = !configuration.hintsEnabled && wanted.hintsEnabled
        cancelHints()
        configuration = wanted
        lines = existingLines
        if enabling { judged.formUnion(existingLines.map(\.id)) }
        if !wanted.hintsEnabled || wanted.apiKey.isEmpty { hints = [] }
        hintError = nil
    }

    /// Resumed/old text is never automatically uploaded for hints.
    public func reset(existingLines: [TranscriptLine] = []) {
        cancelHints()
        lines = existingLines
        judged = Set(existingLines.map(\.id))
        explained = []
        hints = []
        hintError = nil
    }

    public func update(_ lines: [TranscriptLine]) {
        self.lines = lines
        requestNextHints()
    }

    public func dismiss(_ hint: TranscriptHint) { hints.removeAll { $0.id == hint.id } }

    private func cancelHints() {
        hintGeneration = UUID()
        hintTask?.cancel()
        hintTask = nil
    }

    private func requestNextHints() {
        guard configuration.hintsEnabled, !configuration.apiKey.isEmpty, hintTask == nil else { return }
        let pending = lines.filter { !judged.contains($0.id) }
        guard !pending.isEmpty else { return }
        judged.formUnion(pending.map(\.id))
        let batch = Array(pending.filter { HintTrigger.shouldAsk($0.text) }.suffix(8))
        guard let first = batch.first else { return }
        let context = Array(lines.prefix(while: { $0.id != first.id }).suffix(OpenAIHintProvider.contextLineCount))
        let topics = explained
        let config = configuration
        let generation = hintGeneration
        let provider = makeHintProvider(config.apiKey, config.hintModel, config.webSearch)
        hintTask = Task { [weak self] in
            do {
                let found = try await provider.hints(for: batch, context: context, explained: topics, in: config.hintLanguage)
                guard let self, !Task.isCancelled, self.hintGeneration == generation else { return }
                let shown = Set(self.lines.map(\.id))
                let kept = found.filter { shown.contains($0.lineID) }
                if !kept.isEmpty { self.hints = kept }
                self.explained = Array((self.explained + kept.map(\.topic)).suffix(30))
                self.hintError = nil
            } catch {
                guard let self, !Task.isCancelled, self.hintGeneration == generation else { return }
                self.hintError = error.localizedDescription
            }
            guard let self, self.hintGeneration == generation else { return }
            self.hintTask = nil
            self.requestNextHints()
        }
    }

    /// Call only following a user's summary action. Deleted records cancel their tasks and
    /// cannot be recreated by an answer arriving after deletion.
    public func summarize(_ record: TranscriptRecord, apiKey: String, model: String, language: AppLanguage,
                          enabled: Bool, store: TranscriptHistoryStore) async -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !key.isEmpty, !record.lines.isEmpty, !summarizingRecordIDs.contains(record.id) else { return nil }
        let id = record.id
        let token = UUID()
        summaryTokens[id] = token
        summarizingRecordIDs.insert(id)
        summaryErrors[id] = nil
        let provider = makeSummarizer(key, OpenAIChatCompletion.modelName(model))
        let task = Task<String?, Never> { [weak self] in
            defer {
                if let self, self.summaryTokens[id] == token {
                    self.summaryTokens[id] = nil
                    self.summaryTasks[id] = nil
                    self.summarizingRecordIDs.remove(id)
                }
            }
            do {
                let text = try await provider.summarize(record.lines, in: language)
                guard let self, !Task.isCancelled, self.summaryTokens[id] == token else { return nil }
                try store.saveSummary(text, id: id)
                return text
            } catch {
                guard let self, !Task.isCancelled, self.summaryTokens[id] == token else { return nil }
                self.summaryErrors[id] = error.localizedDescription
                return nil
            }
        }
        summaryTasks[id] = task
        return await task.value
    }

    public func forget(recordID: String) {
        summaryTokens[recordID] = nil
        summaryTasks.removeValue(forKey: recordID)?.cancel()
        summarizingRecordIDs.remove(recordID)
        summaryErrors[recordID] = nil
    }
}
