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
    /// to skim it. A Chinese, Japanese or Korean character carries about a word, so it counts
    /// for several Latin letters. Never shorter than a glance nor longer than a paragraph takes
    /// to skim, whatever the service wrote.
    var readingTime: TimeInterval {
        var seconds = 2.0
        for scalar in (topic + text).unicodeScalars where !scalar.properties.isWhitespace {
            seconds += Self.isWordCharacter(scalar) ? 0.18 : 0.04
        }
        return min(max(seconds, 4), 25)
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

/// Asks OpenAI, which answers with a JSON list of hints. Only the new lines, a few lines of
/// context and the earlier topics are sent, not the whole transcript. With `webSearch` the
/// model may look things up on the web through the service's search tool, which goes through
/// the Responses API; otherwise the chat completions API answers from what the model knows.
struct OpenAIHintProvider: TranscriptHinting {
    typealias Failure = OpenAIChatCompletion.Failure

    /// How many earlier lines go along as context.
    static let contextLineCount = 6

    let apiKey: String
    var model: String = OpenAIChatCompletion.defaultModel
    var webSearch = false
    var session: URLSession = .shared

    func hints(
        for newLines: [TranscriptLine],
        context: [TranscriptLine],
        explained: [String],
        in language: AppLanguage
    ) async throws -> [TranscriptHint] {
        guard !newLines.isEmpty else { return [] }
        let instructions = Self.instructions(language: language, webSearch: webSearch)
        let input = Self.input(newLines: newLines, context: context, explained: explained)
        let answer = if webSearch {
            try await OpenAIResponses.complete(instructions: instructions, input: input, apiKey: apiKey, model: model, webSearch: true, session: session)
        } else {
            try await OpenAIChatCompletion.complete(instructions: instructions, input: input, apiKey: apiKey, model: model, jsonAnswer: true, session: session)
        }
        return Self.hints(from: answer, newLines: newLines)
    }

    static func request(
        newLines: [TranscriptLine],
        context: [TranscriptLine],
        explained: [String],
        language: AppLanguage,
        apiKey: String,
        model: String = OpenAIChatCompletion.defaultModel,
        webSearch: Bool = false
    ) throws -> URLRequest {
        let instructions = instructions(language: language, webSearch: webSearch)
        let input = input(newLines: newLines, context: context, explained: explained)
        if webSearch {
            return try OpenAIResponses.request(instructions: instructions, input: input, apiKey: apiKey, model: model, webSearch: true)
        }
        return try OpenAIChatCompletion.request(instructions: instructions, input: input, apiKey: apiKey, model: model, jsonAnswer: true)
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

    static func instructions(language: AppLanguage, webSearch: Bool = false) -> String {
        let search = webSearch ? """
         You may search the web to check a fact or to find out what a recent, local or unfamiliar \
        thing is; prefer that to guessing. Put nothing but the hint in "text": no links, URLs, \
        citations or source names.
        """ : ""
        return """
        You follow a live transcript of recorded speech and add brief hints for the listener. The \
        transcript was produced by automatic speech recognition, so it may contain misheard words \
        or garbled sentences. Look only at the numbered new lines, and find (a) questions about a \
        definite thing or fact that general knowledge can answer, such as what something is, who \
        someone is, where or when something happened or how something works, and (b) obscure \
        things a general listener may not know: rare or technical terms, names, products, places, \
        events, works or concepts. For a question, answer it in a short paragraph of three to five \
        sentences, giving the answer first and then the reasoning or background that makes it \
        clear. For an obscure thing, explain in three to five sentences what it is, where it comes \
        from or is used, and why it matters in this context. Give no hint for a question that is \
        vague, incomplete, garbled, rhetorical or addressed to the other people in the conversation \
        (asking for their opinion, plans, agreement or confirmation), nor for everyday content, \
        small talk, greetings or anything listed as already explained. Never guess what a garbled \
        or misheard sentence was meant to say, and never comment on the transcript or its errors: \
        when the meaning is not clear, there is no hint. Write the hints in \(language.englishName). \
        Answer with a JSON object only, of the form {"hints": [{"line": 1, "topic": "...", \
        "text": "..."}]}, where "line" is the number of the new line the hint belongs to, "topic" \
        names the thing or restates the question in a few words, and "text" is the hint. Most \
        lines need no hint; then answer {"hints": []}.\(search)
        """
    }

    /// The hints in the service's JSON answer, each attached to the new line it names; a hint
    /// naming no valid line goes to the last new line. Entries without a topic or text, and an
    /// answer with no such object in it, give no hints. The object may sit inside other text,
    /// as when the model searched the web and wrote around it, and links and citation marks the
    /// search left in the hints are dropped.
    static func hints(from answer: String, newLines: [TranscriptLine]) -> [TranscriptHint] {
        guard let last = newLines.last,
              let object = jsonObject(in: answer),
              let entries = object["hints"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            let topic = withoutCitations((entry["topic"] as? String) ?? "")
            let text = withoutCitations((entry["text"] as? String) ?? "")
            guard !topic.isEmpty, !text.isEmpty else { return nil }
            let number = entry["line"] as? Int ?? Int((entry["line"] as? String) ?? "") ?? 0
            let line = newLines.indices.contains(number - 1) ? newLines[number - 1] : last
            return TranscriptHint(lineID: line.id, topic: topic, text: text)
        }
    }

    /// The first JSON object in `text`: the whole text, or else the span from its first brace
    /// to its last, for an answer that wraps the object in prose or a code fence.
    static func jsonObject(in text: String) -> [String: Any]? {
        if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return object
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\((?:https?://|www\.)[^)\s]*\)"#)
    private static let citationMark = try! NSRegularExpression(pattern: #"\s*(?:【[^】]*】|\((?:https?://|www\.)[^)\s]*\)|\[\d+\])"#)
    private static let bareURL = try! NSRegularExpression(pattern: #"\s*(?:https?://|www\.)\S+"#)

    /// `text` without the links and citation marks a web search leaves behind: a Markdown link
    /// keeps its title, and bracketed source marks, bare URLs and numbered references go.
    static func withoutCitations(_ text: String) -> String {
        var result = text
        for (expression, template) in [(markdownLink, "$1"), (citationMark, ""), (bareURL, "")] {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
