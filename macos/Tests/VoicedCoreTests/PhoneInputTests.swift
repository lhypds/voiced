import XCTest
@testable import VoicedCore

final class PhoneInputTests: XCTestCase {
    func testMessagesSurviveEncodingAndDecoding() {
        var decoder = PhoneInput.Decoder()
        let data = PhoneInput.encode("你好。") + PhoneInput.encode("Line one\nline two")

        XCTAssertEqual(decoder.feed(data).map(\.text), ["你好。", "Line one\nline two"], "a line break inside a sentence does not end its message")
    }

    func testAMessageSplitAcrossReadsWaitsForItsEnd() {
        var decoder = PhoneInput.Decoder()
        let data = PhoneInput.encode("こんにちは。")
        let middle = data.count / 2

        XCTAssertEqual(decoder.feed(data.prefix(middle)), [])
        XCTAssertEqual(decoder.feed(data.suffix(from: middle)).map(\.text), ["こんにちは。"])
    }

    func testLinesThatAreNotMessagesAreDropped() {
        var decoder = PhoneInput.Decoder()
        let data = Data("garbage\n{\"other\":1}\n".utf8) + PhoneInput.encode("ok")

        XCTAssertEqual(decoder.feed(data).map(\.text), ["ok"])
    }

    func testUnknownFieldsAreIgnored() {
        var decoder = PhoneInput.Decoder()

        XCTAssertEqual(decoder.feed(Data("{\"text\":\"hi\",\"later\":true}\n".utf8)).map(\.text), ["hi"])
    }

    func testTheModeTravelsWithTheSentence() {
        var decoder = PhoneInput.Decoder()
        let data = PhoneInput.encode("ls", mode: .typeAndReturn) + PhoneInput.encode("fix the tests", mode: .claude)

        XCTAssertEqual(decoder.feed(data), [PhoneInput.Message(text: "ls", mode: .typeAndReturn),
                                            PhoneInput.Message(text: "fix the tests", mode: .claude)])
    }

    func testTheFolderTravelsWithARunSentenceAndIsOptional() {
        var decoder = PhoneInput.Decoder()
        let data = PhoneInput.encode("fix the tests", mode: .claude, folder: "~/code/voiced")
            + Data("{\"text\":\"old phone\",\"mode\":\"claude\"}\n".utf8)

        XCTAssertEqual(decoder.feed(data), [PhoneInput.Message(text: "fix the tests", mode: .claude, folder: "~/code/voiced"),
                                            PhoneInput.Message(text: "old phone", mode: .claude)])
    }

    func testTheEarlierConversationTravelsWithARunSentence() {
        var decoder = PhoneInput.Decoder()
        let history = [ClaudeExchange(prompt: "what fails?", answer: "Two tests in PhoneInputTests.")]
        let data = PhoneInput.encode("fix them", mode: .claude, line: "l2", record: "r1", history: history)

        XCTAssertEqual(decoder.feed(data), [PhoneInput.Message(text: "fix them", mode: .claude, line: "l2", record: "r1", history: history)])
    }

    func testARunsConclusionIsWhatClaudeWroteLastOrHowItEnded() {
        var run = ClaudeRun(id: "r", line: "l", text: "go", folder: "/", state: .running, startedAt: 1,
                            items: [ClaudeRunItem(kind: .text, text: "Looking."), ClaudeRunItem(kind: .tool, name: "Bash", done: true),
                                    ClaudeRunItem(kind: .text, text: " Done: all green. ")])
        XCTAssertNil(run.conclusion, "nothing is concluded while it runs")
        XCTAssertEqual(run.asStored.state, .stopped, "a run no longer reported counts as stopped")
        XCTAssertNil(run.asStored.startedAt)
        run.state = .done
        XCTAssertEqual(run.conclusion, "Done: all green.")
        XCTAssertEqual(run.asStored, run)
        run.state = .failed
        run.items?.append(ClaudeRunItem(kind: .error, text: "claude not found"))
        XCTAssertEqual(run.conclusion, "(failed: claude not found)")
    }

    func testAMessageWithoutAModeOrWithAnUnknownOneIsTyped() {
        var decoder = PhoneInput.Decoder()
        let data = Data("{\"text\":\"old phone\"}\n{\"text\":\"newer phone\",\"mode\":\"later\"}\n".utf8)

        XCTAssertEqual(decoder.feed(data).map(\.mode), [.type, .type])
    }

    func testLatinSentencesAreFollowedByASpace() {
        XCTAssertEqual(PhoneInput.typedText(for: "Hello there.", pressesReturn: false), "Hello there. ")
        XCTAssertEqual(PhoneInput.typedText(for: "  run the tests ", pressesReturn: false), "run the tests ")
    }

    func testChineseAndJapaneseSentencesAreTypedAsTheyAre() {
        XCTAssertEqual(PhoneInput.typedText(for: "运行测试。", pressesReturn: false), "运行测试。")
        XCTAssertEqual(PhoneInput.typedText(for: "テストを実行して", pressesReturn: false), "テストを実行して")
    }

    func testNothingIsAddedBeforeReturn() {
        XCTAssertEqual(PhoneInput.typedText(for: "Hello there.", pressesReturn: true), "Hello there.")
    }

    func testRunEventsBuildTheRunsAsTheMacSendsThem() {
        var decoder = PhoneInput.EventDecoder()
        func line(_ json: String) -> Data { Data((json + "\n").utf8) }
        let data = line(#"{"type":"snapshot","runs":[{"id":"old","text":"a","folder":"~","state":"done","items":[]}]}"#)
            + line(#"{"type":"run","run":{"id":"r1","line":"L1","text":"fix it","folder":"~","state":"running","startedAt":10}}"#)
            + line(#"{"type":"item","id":"r1","i":0,"item":{"kind":"text","text":""}}"#)
            + line(#"{"type":"delta","id":"r1","i":0,"text":"Hel"}"#)
            + line(#"{"type":"delta","id":"r1","i":0,"text":"lo"}"#)
            + line(#"{"type":"item","id":"r1","i":1,"item":{"kind":"tool","name":"Bash","summary":"ls","done":false}}"#)
            + line(#"{"type":"run","run":{"id":"r1","line":"L1","text":"fix it","folder":"~","state":"running","startedAt":10,"pending":{"id":"p","tool":"Bash","summary":"ls"}}}"#)
            + line(#"{"type":"remove","id":"old"}"#)
        var runs: [String: ClaudeRun] = [:]
        for event in decoder.feed(data) { event.apply(to: &runs) }

        XCTAssertEqual(Set(runs.keys), ["r1"])
        let run = runs["r1"]
        XCTAssertEqual(run?.items?.first?.text, "Hello")
        XCTAssertEqual(run?.activeTool?.name, "Bash")
        XCTAssertEqual(run?.pending?.id, "p", "a state update keeps the items")
        XCTAssertEqual(run?.items?.count, 2)
    }

    func testARunCommandEncodesWithoutText() throws {
        let data = PhoneInput.encode(ClaudeRunCommand(command: .allow, run: "r1", pending: "p"))
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: String]
        XCTAssertEqual(object, ["command": "allow", "run": "r1", "pending": "p"])
    }
}
