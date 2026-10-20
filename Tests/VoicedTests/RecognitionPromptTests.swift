import XCTest
@testable import Voiced

final class RecognitionPromptTests: XCTestCase {
    func testTermsAreJoinedWithCommas() {
        XCTAssertEqual(RecognitionPrompt.text(from: "WhisperKit\nVoiced\n微信\n"), "WhisperKit, Voiced, 微信")
    }

    func testCommentsBlankLinesAndWhitespaceAreIgnored() {
        let contents = """
        # a comment

          Loopback  
        \t
        #another
        BlackHole
        """
        XCTAssertEqual(RecognitionPrompt.text(from: contents), "Loopback, BlackHole")
    }

    func testTemplateAloneYieldsNoPrompt() {
        XCTAssertNil(RecognitionPrompt.text(from: RecognitionPrompt.template))
        XCTAssertNil(RecognitionPrompt.text(from: ""))
        XCTAssertNil(RecognitionPrompt.text(from: "\n\n# only comments\n"))
    }

    func testLoadReturnsNilForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiced-missing-\(UUID().uuidString).txt")
        XCTAssertNil(RecognitionPrompt.load(from: url))
    }

    func testEnsureFileExistsWritesTemplateOnceOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiced-prompt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prompt.txt")

        try RecognitionPrompt.ensureFileExists(at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), RecognitionPrompt.template)
        XCTAssertNil(RecognitionPrompt.load(from: url))

        try "Voiced\n".write(to: url, atomically: true, encoding: .utf8)
        try RecognitionPrompt.ensureFileExists(at: url)
        XCTAssertEqual(RecognitionPrompt.load(from: url), "Voiced")
    }
}
