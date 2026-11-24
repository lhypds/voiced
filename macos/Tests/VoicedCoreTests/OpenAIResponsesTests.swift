import XCTest
@testable import VoicedCore

final class OpenAIResponsesTests: XCTestCase {
    func testRequestCarriesInstructionsInputAndTheSearchTool() throws {
        let request = try OpenAIResponses.request(instructions: "Be brief.", input: "What is a Merkle tree?", apiKey: "sk-test", model: "gpt-5.5", webSearch: true)

        XCTAssertEqual(request.url, OpenAIResponses.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["instructions"] as? String, "Be brief.")
        XCTAssertEqual(body["input"] as? String, "What is a Merkle tree?")
        XCTAssertEqual(body["tools"] as? [[String: String]], [["type": "web_search"]])

        let plain = try OpenAIResponses.request(instructions: "Be brief.", input: "Hi", apiKey: "sk-test")
        let plainBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plain.httpBody)) as? [String: Any])
        XCTAssertNil(plainBody["tools"])
        XCTAssertEqual(plainBody["model"] as? String, OpenAIChatCompletion.defaultModel)
    }

    func testTextIsJoinedFromTheMessagesAmongTheOutputItems() throws {
        let data = Data("""
        {"output": [
            {"type": "web_search_call", "id": "ws_1", "status": "completed", "action": {"type": "search", "query": "merkle tree"}},
            {"type": "message", "id": "msg_1", "role": "assistant", "content": [
                {"type": "output_text", "text": "  First part.", "annotations": [{"type": "url_citation", "url": "https://example.com"}]}
            ]},
            {"type": "message", "id": "msg_2", "role": "assistant", "content": [{"type": "refusal", "refusal": "no"}, {"type": "output_text", "text": "Second part.\\n"}]}
        ]}
        """.utf8)
        XCTAssertEqual(try OpenAIResponses.text(from: data, response: response(status: 200)), "First part.\nSecond part.")
    }

    func testErrorsAndEmptyAnswersThrow() {
        let error = Data(#"{"error": {"message": "Unsupported model", "type": "invalid_request_error"}}"#.utf8)
        XCTAssertThrowsError(try OpenAIResponses.text(from: error, response: response(status: 400))) { thrown in
            XCTAssertEqual(thrown as? OpenAIResponses.Failure, .server(status: 400, message: "Unsupported model"))
        }
        let failed = Data(#"{"status": "failed", "error": {"message": "Search failed"}, "output": []}"#.utf8)
        XCTAssertThrowsError(try OpenAIResponses.text(from: failed, response: response(status: 200))) { thrown in
            XCTAssertEqual(thrown as? OpenAIResponses.Failure, .server(status: 200, message: "Search failed"))
        }
        let empty = Data(#"{"output": [{"type": "web_search_call", "status": "completed"}]}"#.utf8)
        XCTAssertThrowsError(try OpenAIResponses.text(from: empty, response: response(status: 200))) { thrown in
            XCTAssertEqual(thrown as? OpenAIResponses.Failure, .emptyAnswer)
        }
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        do {
            _ = try await OpenAIResponses.complete(instructions: "x", input: "y", apiKey: "", webSearch: true)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? OpenAIResponses.Failure, .missingKey)
        }
    }

    private func response(status: Int) -> URLResponse {
        HTTPURLResponse(url: OpenAIResponses.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
