import Foundation

/// The OpenAI chat completions call the AI features share: one request carrying a system
/// instruction and a user message, answered with a single text. The text sent goes to the
/// service, unlike recognition and translation, which stay on the machine; the user opts in by
/// entering a key.
enum OpenAIChatCompletion {
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
    /// The model used until the user names another: cheap and quick enough for live hints.
    static let defaultModel = "gpt-4.1-mini"
    /// Names offered in Settings; the service decides whether a name still exists.
    static let knownModels = ["gpt-4.1-nano", "gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o", "gpt-5-nano", "gpt-5-mini", "gpt-5"]

    /// `name` with surrounding whitespace dropped, or the default when nothing is left.
    static func modelName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// Sends `instructions` and `input` and returns the answer's text.
    /// - Parameter jsonAnswer: Asks the service to answer with a JSON object, which the
    ///   instructions must mention and describe.
    static func complete(
        instructions: String,
        input: String,
        apiKey: String,
        model: String = defaultModel,
        jsonAnswer: Bool = false,
        session: URLSession = .shared
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        let request = try request(instructions: instructions, input: input, apiKey: apiKey, model: model, jsonAnswer: jsonAnswer)
        let (data, response) = try await session.data(for: request)
        return try text(from: data, response: response)
    }

    static func request(instructions: String, input: String, apiKey: String, model: String = defaultModel, jsonAnswer: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": modelName(model),
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": input],
            ],
        ]
        if jsonAnswer {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Takes the text out of the service's answer, or throws with what it said went wrong.
    static func text(from data: Data, response: URLResponse) throws -> String {
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
}
