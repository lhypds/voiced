import Foundation

/// Produces a short summary of a transcript, in the given interface language.
protocol TranscriptSummarizing: Sendable {
    func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String
}

/// Summarizes through OpenAI's chat completions API. The whole transcript goes to the service,
/// unlike recognition and translation, which stay on the machine; the user opts in by entering a key.
struct OpenAISummarizer: TranscriptSummarizing {
    enum Failure: LocalizedError, Equatable {
        case missingKey
        /// The service answered with an error status; `message` is its own explanation when it gave one.
        case server(status: Int, message: String?)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .missingKey: "No API key"
            case .server(let status, let message): message ?? "HTTP \(status)"
            case .emptyAnswer: "The service returned no text"
            }
        }
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let model = "gpt-4.1-mini"

    let apiKey: String
    var session: URLSession = .shared

    func summarize(_ lines: [TranscriptLine], in language: AppLanguage) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        let request = try Self.request(for: lines, language: language, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        return try Self.summary(from: data, response: response)
    }

    static func request(for lines: [TranscriptLine], language: AppLanguage, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions(language: language)],
                ["role": "user", "content": transcript(lines)],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Takes the text out of the service's answer, or throws with what it said went wrong.
    static func summary(from data: Data, response: URLResponse) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            throw Failure.server(status: status, message: message)
        }
        let choices = object?["choices"] as? [[String: Any]]
        let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        let text = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw Failure.emptyAnswer }
        return text
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
