import Foundation

/// Produces a short summary of a transcript, in the given interface language.
public protocol TranscriptSummarizing: Sendable {
    func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String
}

/// Summarizes through OpenAI's chat completions API. The whole transcript goes to the service.
public struct OpenAISummarizer: TranscriptSummarizing {
    public init(apiKey: String, model: String = OpenAIChatCompletion.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public typealias Failure = OpenAIChatCompletion.Failure

    public static let endpoint = OpenAIChatCompletion.endpoint
    public static let model = OpenAIChatCompletion.defaultModel

    public let apiKey: String
    public var model: String = OpenAIChatCompletion.defaultModel
    public var session: URLSession = .shared

    public func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String {
        try await OpenAIChatCompletion.complete(
            instructions: Self.instructions(language: language),
            input: Self.transcript(lines),
            apiKey: apiKey,
            model: model,
            session: session
        )
    }

    public static func request(for lines: [TranscriptLine], language: AppLanguage, apiKey: String, model: String = OpenAIChatCompletion.defaultModel) throws -> URLRequest {
        try OpenAIChatCompletion.request(instructions: instructions(language: language), input: transcript(lines), apiKey: apiKey, model: model)
    }

    /// Takes the text out of the service's answer, or throws with what it said went wrong.
    public static func summary(from data: Data, response: URLResponse) throws -> String {
        try OpenAIChatCompletion.text(from: data, response: response)
    }

    /// The transcript as the service sees it: one line per sentence, with the clock time each
    /// started so the summary can refer to when things were said.
    public static func transcript(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\($0.timestamp(mode: .current, showDate: false))] \($0.text)" }.joined(separator: "\n")
    }

    public static func instructions(language: AppLanguage) -> String {
        """
        You summarize a transcript of recorded speech. The transcript was produced by automatic \
        speech recognition, so it may contain misheard words; infer the intended meaning where it \
        is clear. Write a concise summary in \(language.englishName): first a short paragraph with \
        the main points, then a bulleted list of the key details, decisions or facts mentioned. \
        Use only what the transcript says; do not add anything. Answer with the summary only.
        """
    }
}
