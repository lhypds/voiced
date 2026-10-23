import XCTest
@testable import Voiced

final class OpenAISummarizerTests: XCTestCase {
    private let lines = [
        TranscriptLine(id: "a", start: 0, end: 1, recordedAt: Date(timeIntervalSince1970: 0), text: "First sentence."),
        TranscriptLine(id: "b", start: 1, end: 2, recordedAt: Date(timeIntervalSince1970: 61), text: "Second sentence."),
    ]

    func testRequestCarriesTheKeyModelAndTranscript() throws {
        let request = try OpenAISummarizer.request(for: lines, language: .japanese, apiKey: "sk-test")

        XCTAssertEqual(request.url, OpenAISummarizer.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, OpenAISummarizer.model)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]?.contains("in Japanese") == true, "the summary is asked for in the interface language")
        XCTAssertEqual(messages[1]["content"], OpenAISummarizer.transcript(lines))
    }

    func testTranscriptListsOneTimestampedLinePerSentence() {
        let transcript = OpenAISummarizer.transcript(lines)
        let rows = transcript.split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].hasSuffix("] First sentence."))
        XCTAssertTrue(rows[0].hasPrefix("["))
        XCTAssertTrue(rows[1].hasSuffix("] Second sentence."))
    }

    func testAnswerTextIsTakenFromTheFirstChoice() throws {
        let data = Data(#"{"choices": [{"message": {"role": "assistant", "content": "  A summary.\n"}}]}"#.utf8)
        XCTAssertEqual(try OpenAISummarizer.summary(from: data, response: response(status: 200)), "A summary.")
    }

    func testServerErrorsCarryTheServicesMessage() {
        let data = Data(#"{"error": {"message": "Incorrect API key provided", "type": "invalid_request_error"}}"#.utf8)
        XCTAssertThrowsError(try OpenAISummarizer.summary(from: data, response: response(status: 401))) { error in
            XCTAssertEqual(error as? OpenAISummarizer.Failure, .server(status: 401, message: "Incorrect API key provided"))
            XCTAssertEqual(error.localizedDescription, "Incorrect API key provided")
        }
        XCTAssertThrowsError(try OpenAISummarizer.summary(from: Data("<html>".utf8), response: response(status: 502))) { error in
            XCTAssertEqual(error as? OpenAISummarizer.Failure, .server(status: 502, message: nil))
            XCTAssertEqual(error.localizedDescription, "HTTP 502")
        }
    }

    func testAnEmptyAnswerIsAnError() {
        let data = Data(#"{"choices": [{"message": {"content": ""}}]}"#.utf8)
        XCTAssertThrowsError(try OpenAISummarizer.summary(from: data, response: response(status: 200))) { error in
            XCTAssertEqual(error as? OpenAISummarizer.Failure, .emptyAnswer)
        }
        XCTAssertThrowsError(try OpenAISummarizer.summary(from: Data("{}".utf8), response: response(status: 200)))
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        do {
            _ = try await OpenAISummarizer(apiKey: "").summarize(lines, in: .english)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? OpenAISummarizer.Failure, .missingKey)
        }
    }

    private func response(status: Int) -> URLResponse {
        HTTPURLResponse(url: OpenAISummarizer.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
