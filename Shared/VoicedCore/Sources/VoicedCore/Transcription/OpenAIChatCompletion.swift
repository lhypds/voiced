import Foundation

/// The OpenAI chat completions call the AI features share: one request carrying a system
/// instruction and a user message, answered with a single text. The text sent goes to the
/// service, unlike recognition and translation, which stay on the machine; the user opts in by
/// entering a key.
public enum OpenAIChatCompletion {
    public enum Failure: LocalizedError, Equatable {
        case missingKey
        /// The service answered with an error status; `message` is its own explanation when it gave one.
        case server(status: Int, message: String?)
        case emptyAnswer

        public var errorDescription: String? {
            switch self {
            case .missingKey: "No API key"
            case .server(let status, let message): message ?? "HTTP \(status)"
            case .emptyAnswer: "The service returned no text"
            }
        }
    }

    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// The model used until the user picks another: OpenAI's most efficient general model as
    /// of October 2026, cheap and quick enough for live hints, and the replacement it names
    /// for the retired small GPT-4.1 and GPT-4o models.
    public static let defaultModel = "gpt-6-luna"
    /// Names offered in Settings, cheapest first, from OpenAI's model list of October 2026;
    /// the service decides whether a name still exists.
    public static let knownModels = ["gpt-6-luna", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.5", "gpt-6-sol", "gpt-6.1-sol", "gpt-6-astra"]

    /// `name` with surrounding whitespace dropped, or the default when nothing is left.
    public static func modelName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// Sends `instructions` and `input` and returns the answer's text.
    /// - Parameter jsonAnswer: Asks the service to answer with a JSON object, which the
    ///   instructions must mention and describe.
    public static func complete(
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

    public static func request(instructions: String, input: String, apiKey: String, model: String = defaultModel, jsonAnswer: Bool = false) throws -> URLRequest {
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
    public static func text(from data: Data, response: URLResponse) throws -> String {
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

/// The OpenAI Responses API call used when the model may search the web: the same instruction
/// and input, answered with a single text, with the service's web search tool switched on.
/// Citations the model weaves into its text are stripped by the callers that parse it.
public enum OpenAIResponses {
    public typealias Failure = OpenAIChatCompletion.Failure

    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public static func complete(
        instructions: String,
        input: String,
        apiKey: String,
        model: String = OpenAIChatCompletion.defaultModel,
        webSearch: Bool = false,
        session: URLSession = .shared
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        let request = try request(instructions: instructions, input: input, apiKey: apiKey, model: model, webSearch: webSearch)
        let (data, response) = try await session.data(for: request)
        return try text(from: data, response: response)
    }

    /// The answer is asked for as plain text even when JSON is wanted: whether the structured
    /// output setting can be combined with the search tool is not documented, and the callers
    /// find the JSON object inside the text anyway.
    public static func request(instructions: String, input: String, apiKey: String, model: String = OpenAIChatCompletion.defaultModel, webSearch: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": OpenAIChatCompletion.modelName(model),
            "instructions": instructions,
            "input": input,
        ]
        if webSearch {
            body["tools"] = [["type": "web_search"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Joins the text of every message in the answer's output, which also lists the searches
    /// made and may carry a refusal, or throws with what the service said went wrong.
    public static func text(from data: Data, response: URLResponse) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw Failure.server(status: status, message: message)
        }
        if let message {
            throw Failure.server(status: (response as? HTTPURLResponse)?.statusCode ?? 200, message: message)
        }
        let output = object?["output"] as? [[String: Any]] ?? []
        let texts = output
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyAnswer }
        return text
    }
}
