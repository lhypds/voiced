import Foundation

/// Produces a short summary of a transcript, in the given interface language.
protocol TranscriptSummarizing: Sendable {
    func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String
}

/// Summarizes through OpenAI's chat completions API. The whole transcript goes to the service.
struct OpenAISummarizer: TranscriptSummarizing {
    typealias Failure = OpenAIChatCompletion.Failure

    static let endpoint = OpenAIChatCompletion.endpoint
    static let model = OpenAIChatCompletion.defaultModel

    let apiKey: String
    var model: String = OpenAIChatCompletion.defaultModel
    var session: URLSession = .shared

    func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String {
        try await OpenAIChatCompletion.complete(
            instructions: Self.instructions(language: language),
            input: Self.transcript(lines),
            apiKey: apiKey,
            model: model,
            session: session
        )
    }

    static func request(for lines: [TranscriptLine], language: AppLanguage, apiKey: String, model: String = OpenAIChatCompletion.defaultModel) throws -> URLRequest {
        try OpenAIChatCompletion.request(instructions: instructions(language: language), input: transcript(lines), apiKey: apiKey, model: model)
    }

    /// Takes the text out of the service's answer, or throws with what it said went wrong.
    static func summary(from data: Data, response: URLResponse) throws -> String {
        try OpenAIChatCompletion.text(from: data, response: response)
    }

    /// The transcript as the service sees it: one line per sentence, with the clock time each
    /// started so the summary can refer to when things were said.
    static func transcript(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\($0.timestamp(mode: .current, showDate: false))] \($0.text)" }.joined(separator: "\n")
    }

    static func instructions(language: AppLanguage) -> String {
        """
        You summarize a transcript of recorded speech. The transcript was produced by automatic \
        speech recognition, so it may contain misheard words; infer the intended meaning where it \
        is clear. Write a concise summary in \(language.englishName): first a short paragraph with \
        the main points, then a bulleted list of the key details, decisions or facts mentioned. \
        Use only what the transcript says; do not add anything. Answer with the summary only.
        """
    }
}
