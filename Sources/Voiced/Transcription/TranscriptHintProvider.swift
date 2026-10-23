import Foundation

/// A note the AI attached to a transcript line: a short explanation of something obscure the
/// line mentioned, or an answer to a question it asked.
struct TranscriptHint: Identifiable, Equatable, Sendable {
    let id: String
    /// The line the hint is shown under.
    let lineID: String
    /// What the hint is about: the thing's name, or the question, in a few words.
    let topic: String
    let text: String

    init(id: String = UUID().uuidString, lineID: String, topic: String, text: String) {
        self.id = id
        self.lineID = lineID
        self.topic = topic
        self.text = text
    }

    /// How long the hint stays on screen unasked, in seconds: a moment to notice it, then time
    /// to read it at an unhurried pace. A Chinese, Japanese or Korean character carries about a
    /// word, so it counts for several Latin letters. Never shorter than a glance nor longer than
    /// a long paragraph takes, whatever the service wrote.
    var readingTime: TimeInterval {
        var seconds = 3.0
        for scalar in (topic + text).unicodeScalars where !scalar.properties.isWhitespace {
            seconds += Self.isWordCharacter(scalar) ? 0.25 : 0.05
        }
        return min(max(seconds, 5), 40)
    }

    /// Han ideographs, kana and hangul: scripts where one character reads like a word.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }
}

/// Finds what in newly recognized lines deserves a hint, and writes the hints.
protocol TranscriptHinting: Sendable {
    /// Hints for `newLines`, in the given interface language. `context` holds the lines spoken
    /// before them, for understanding only; `explained` lists the topics of earlier hints, which
    /// are not given again. Empty when nothing in the new lines calls for a hint.
    func hints(
        for newLines: [TranscriptLine],
        context: [TranscriptLine],
        explained: [String],
        in language: AppLanguage
    ) async throws -> [TranscriptHint]
}

/// Asks OpenAI's chat completions API, which answers with a JSON list of hints. Only the new
/// lines, a few lines of context and the earlier topics are sent, not the whole transcript.
struct OpenAIHintProvider: TranscriptHinting {
    typealias Failure = OpenAIChatCompletion.Failure

    /// How many earlier lines go along as context.
    static let contextLineCount = 6

    let apiKey: String
    var model: String = OpenAIChatCompletion.defaultModel
    var session: URLSession = .shared

    func hints(
        for newLines: [TranscriptLine],
        context: [TranscriptLine],
        explained: [String],
        in language: AppLanguage
    ) async throws -> [TranscriptHint] {
        guard !newLines.isEmpty else { return [] }
        let answer = try await OpenAIChatCompletion.complete(
            instructions: Self.instructions(language: language),
            input: Self.input(newLines: newLines, context: context, explained: explained),
            apiKey: apiKey,
            model: model,
            jsonAnswer: true,
            session: session
        )
        return Self.hints(from: answer, newLines: newLines)
    }

    static func request(
        newLines: [TranscriptLine],
        context: [TranscriptLine],
        explained: [String],
        language: AppLanguage,
        apiKey: String,
        model: String = OpenAIChatCompletion.defaultModel
    ) throws -> URLRequest {
        try OpenAIChatCompletion.request(
            instructions: instructions(language: language),
            input: input(newLines: newLines, context: context, explained: explained),
            apiKey: apiKey,
            model: model,
            jsonAnswer: true
        )
    }

    /// The new lines numbered from 1, after the context lines and before the topics already covered.
    static func input(newLines: [TranscriptLine], context: [TranscriptLine], explained: [String]) -> String {
        var parts: [String] = []
        let context = context.suffix(contextLineCount)
        if !context.isEmpty {
            parts.append("Earlier lines, for context only:\n" + context.map(\.text).joined(separator: "\n"))
        }
        parts.append("New lines:\n" + newLines.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n"))
        if !explained.isEmpty {
            parts.append("Topics already explained, do not repeat them:\n" + explained.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func instructions(language: AppLanguage) -> String {
        """
        You follow a live transcript of recorded speech and add brief hints for the listener. The \
        transcript was produced by automatic speech recognition, so it may contain misheard words; \
        infer the intended meaning where it is clear. Look only at the numbered new lines, and find \
        (a) questions somebody asked and (b) obscure things a general listener may not know: rare \
        or technical terms, names, products, places, events, works or concepts. For a question, \
        answer it in a short paragraph of three to five sentences, giving the answer first and then \
        the reasoning or background that makes it clear. For an obscure thing, explain in three to \
        five sentences what it is, where it comes from or is used, and why it matters in this \
        context. Skip everyday content, small talk, greetings and anything listed as already \
        explained. Write the hints in \(language.englishName). Answer with a JSON object only, of the form \
        {"hints": [{"line": 1, "topic": "...", "text": "..."}]}, where "line" is the number of the \
        new line the hint belongs to, "topic" names the thing or restates the question in a few \
        words, and "text" is the hint. Most lines need no hint; then answer {"hints": []}.
        """
    }

    /// The hints in the service's JSON answer, each attached to the new line it names; a hint
    /// naming no valid line goes to the last new line. Entries without a topic or text, and an
    /// answer that is not the expected object, give no hints.
    static func hints(from answer: String, newLines: [TranscriptLine]) -> [TranscriptHint] {
        guard let last = newLines.last,
              let object = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any],
              let entries = object["hints"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            let topic = (entry["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !topic.isEmpty, !text.isEmpty else { return nil }
            let number = entry["line"] as? Int ?? Int((entry["line"] as? String) ?? "") ?? 0
            let line = newLines.indices.contains(number - 1) ? newLines[number - 1] : last
            return TranscriptHint(lineID: line.id, topic: topic, text: text)
        }
    }
}
