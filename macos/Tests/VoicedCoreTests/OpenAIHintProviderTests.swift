import XCTest
@testable import VoicedCore

final class OpenAIHintProviderTests: XCTestCase {
    private let context = [
        TranscriptLine(id: "a", start: 0, end: 1, recordedAt: Date(timeIntervalSince1970: 0), text: "We talked about the schedule."),
    ]
    private let newLines = [
        TranscriptLine(id: "b", start: 1, end: 2, recordedAt: Date(timeIntervalSince1970: 61), text: "The data lives in a Merkle tree."),
        TranscriptLine(id: "c", start: 2, end: 3, recordedAt: Date(timeIntervalSince1970: 62), text: "What is the capital of Mongolia?"),
    ]

    func testRequestAsksForJSONInTheInterfaceLanguage() throws {
        let request = try OpenAIHintProvider.request(newLines: newLines, context: context, explained: ["Kubernetes"], language: .chinese, apiKey: "sk-test")

        XCTAssertEqual(request.url, OpenAIChatCompletion.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, OpenAIChatCompletion.defaultModel)
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]?.contains("in Chinese") == true, "hints are asked for in the interface language")
        XCTAssertEqual(messages[1]["content"], OpenAIHintProvider.input(newLines: newLines, context: context, explained: ["Kubernetes"]))
    }

    func testRequestCarriesTheChosenModel() throws {
        let request = try OpenAIHintProvider.request(newLines: newLines, context: [], explained: [], language: .english, apiKey: "sk-test", model: "gpt-5.6-terra")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-terra")

        let blank = try OpenAISummarizer.request(for: newLines, language: .english, apiKey: "sk-test", model: "  ")
        let blankBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(blank.httpBody)) as? [String: Any])
        XCTAssertEqual(blankBody["model"] as? String, OpenAIChatCompletion.defaultModel, "a blank name falls back to the default")
    }

    func testWebSearchGoesThroughTheResponsesAPIWithTheSearchTool() throws {
        let request = try OpenAIHintProvider.request(newLines: newLines, context: context, explained: [], language: .french, apiKey: "sk-test", model: "gpt-5.5", webSearch: true)

        XCTAssertEqual(request.url, OpenAIResponses.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["tools"] as? [[String: String]], [["type": "web_search"]])
        XCTAssertEqual(body["input"] as? String, OpenAIHintProvider.input(newLines: newLines, context: context, explained: []))
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("in French"))
        XCTAssertTrue(instructions.contains("search the web"), "the model is told it may search")
        XCTAssertNil(body["text"], "no structured output setting alongside the search tool")
        XCTAssertFalse(OpenAIHintProvider.instructions(language: .french).contains("search the web"), "without search the model is not told to")
    }

    func testInputNumbersTheNewLinesAfterTheContextAndBeforeEarlierTopics() {
        let input = OpenAIHintProvider.input(newLines: newLines, context: context, explained: ["Kubernetes"])

        XCTAssertEqual(input, """
        Earlier lines, for context only:
        We talked about the schedule.

        New lines:
        1. The data lives in a Merkle tree.
        2. What is the capital of Mongolia?

        Topics already explained, do not repeat them:
        - Kubernetes
        """)
    }

    func testInputLeavesOutEmptyContextAndTopics() {
        let input = OpenAIHintProvider.input(newLines: newLines, context: [], explained: [])
        XCTAssertTrue(input.hasPrefix("New lines:\n1. "))
        XCTAssertFalse(input.contains("already explained"))
    }

    func testOnlyTheLastContextLinesAreSent() {
        let many = (0..<10).map { TranscriptLine(id: "\($0)", start: 0, end: 1, recordedAt: Date(), text: "Line \($0)") }
        let input = OpenAIHintProvider.input(newLines: newLines, context: many, explained: [])
        XCTAssertFalse(input.contains("Line 3"))
        XCTAssertTrue(input.contains("Line 4"))
        XCTAssertTrue(input.contains("Line 9"))
    }

    func testHintsAreAttachedToTheNumberedLines() {
        let answer = """
        {"hints": [
            {"line": 1, "topic": "Merkle tree", "text": "A hash tree used to verify data."},
            {"line": "2", "topic": "Capital of Mongolia", "text": "Ulaanbaatar."}
        ]}
        """
        let hints = OpenAIHintProvider.hints(from: answer, newLines: newLines)

        XCTAssertEqual(hints.map(\.lineID), ["b", "c"])
        XCTAssertEqual(hints.map(\.topic), ["Merkle tree", "Capital of Mongolia"])
        XCTAssertEqual(hints.map(\.text), ["A hash tree used to verify data.", "Ulaanbaatar."])
        XCTAssertEqual(Set(hints.map(\.id)).count, 2, "every hint has its own identity")
    }

    func testHintsAreFoundInsideProseAndStrippedOfCitations() {
        let answer = """
        Here is what I found:
        ```json
        {"hints": [{"line": 1, "topic": "Merkle tree 【3†source】", "text": "A hash tree ([Wikipedia](https://en.wikipedia.org/wiki/Merkle_tree)) used to verify data (https://example.com/x). See https://example.com/y [2]"}]}
        ```
        """
        let hints = OpenAIHintProvider.hints(from: answer, newLines: newLines)
        XCTAssertEqual(hints.map(\.topic), ["Merkle tree"])
        XCTAssertEqual(hints.map(\.text), ["A hash tree (Wikipedia) used to verify data. See"])
    }

    func testHintsNamingNoValidLineGoToTheLastNewLine() {
        let answer = #"{"hints": [{"line": 7, "topic": "T", "text": "X"}, {"topic": "U", "text": "Y"}]}"#
        let hints = OpenAIHintProvider.hints(from: answer, newLines: newLines)
        XCTAssertEqual(hints.map(\.lineID), ["c", "c"])
    }

    func testIncompleteEntriesAndMalformedAnswersGiveNoHints() {
        let partial = #"{"hints": [{"line": 1, "topic": "  ", "text": "X"}, {"line": 1, "topic": "T"}]}"#
        XCTAssertEqual(OpenAIHintProvider.hints(from: partial, newLines: newLines), [])
        XCTAssertEqual(OpenAIHintProvider.hints(from: #"{"hints": []}"#, newLines: newLines), [])
        XCTAssertEqual(OpenAIHintProvider.hints(from: "Nothing to note.", newLines: newLines), [])
        XCTAssertEqual(OpenAIHintProvider.hints(from: #"{"hints": [{"line": 1, "topic": "T", "text": "X"}]}"#, newLines: []), [])
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        do {
            _ = try await OpenAIHintProvider(apiKey: "").hints(for: newLines, context: [], explained: [], in: .english)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? OpenAIHintProvider.Failure, .missingKey)
        }
    }

    func testNoNewLinesMakesNoRequest() async throws {
        let hints = try await OpenAIHintProvider(apiKey: "").hints(for: [], context: context, explained: [], in: .english)
        XCTAssertEqual(hints, [])
    }
}

final class TranscriptHintReadingTimeTests: XCTestCase {
    func testShortHintsStayForAGlance() {
        XCTAssertEqual(TranscriptHint(lineID: "a", topic: "T", text: "X").readingTime, 4)
    }

    func testLongerHintsStayLongerAndNeverPastTheCap() {
        let short = TranscriptHint(lineID: "a", topic: "Merkle tree", text: "A hash tree used to verify data.")
        let long = TranscriptHint(lineID: "a", topic: "Merkle tree", text: String(repeating: "A hash tree used to verify data. ", count: 10))
        let endless = TranscriptHint(lineID: "a", topic: "T", text: String(repeating: "word ", count: 500))
        XCTAssertGreaterThanOrEqual(short.readingTime, 4)
        XCTAssertGreaterThan(long.readingTime, short.readingTime)
        XCTAssertEqual(endless.readingTime, 25)
    }

    func testACJKCharacterCountsAsAWord() {
        let chinese = TranscriptHint(lineID: "a", topic: "默克尔树", text: "一种用于校验数据的哈希树。")
        let english = TranscriptHint(lineID: "a", topic: "Merkle", text: "A hash tree ok")
        XCTAssertEqual(chinese.topic.count + chinese.text.count, (english.topic + english.text).filter { $0 != " " }.count, "same character count")
        XCTAssertGreaterThan(chinese.readingTime, english.readingTime)
    }
}
