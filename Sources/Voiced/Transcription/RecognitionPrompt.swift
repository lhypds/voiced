import Foundation
import WhisperKit

/// The recognition prompt the user keeps in `~/.voiced/prompt.txt`.
///
/// Whisper has no keyword-boosting API, but it conditions each decode on an optional text prompt
/// (`<|startofprev|>` followed by the prompt tokens). Words in the prompt are far more likely to
/// come out spelled the same way, so a list of names, products and technical terms makes the
/// model prefer them over similar-sounding alternatives. The file is read afresh at the start of
/// every recording and preview, so edits apply without restarting the app.
enum RecognitionPrompt {
    /// Whisper's decoder context is 448 tokens; WhisperKit keeps at most half of it, minus one,
    /// for the prompt and takes the *last* tokens when it has to cut. The prompt is cut here to
    /// the first tokens instead, so the terms at the top of the file are the ones that survive.
    static let maxTokens = 223

    /// Written when the file is created, so the editor opens on an explanation rather than a blank page.
    static let template = """
    # Voiced recognition prompt
    #
    # Words and phrases listed here are preferred by the recognizer: names, products, technical
    # terms and other words it tends to get wrong. Put one term per line, in the language you
    # speak. Lines starting with # are ignored. Changes apply to the next recording.
    #
    # 这里列出的词会被识别器优先采用：人名、产品名、术语等容易识别错的词。每行一个，
    # 用你说话的语言书写。以 # 开头的行会被忽略。修改后下一次识别生效。
    #
    # ここに書いた語は認識時に優先されます。人名、製品名、専門用語など、誤認識しやすい語を
    # 1 行に 1 つずつ、話す言語で書いてください。# で始まる行は無視されます。次の認識から反映されます。

    """

    /// The prompt text: the file's non-comment lines joined with commas, or nil when the file is
    /// missing or holds nothing but comments and blank lines.
    static func load(from url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text(from: contents)
    }

    /// Parses the file's contents. Visible for tests.
    static func text(from contents: String) -> String? {
        let terms = contents
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }

    /// Creates the file with the template when it does not exist yet. Returns the file's URL.
    @discardableResult
    static func ensureFileExists(at url: URL) throws -> URL {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return url }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try template.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The prompt as decoder tokens, cut to `maxTokens`, or nil when there is no prompt.
    /// Whisper's training prompts start with a space, so one is prepended.
    static func tokens(for text: String?, tokenizer: any WhisperTokenizer) -> [Int]? {
        guard let text else { return nil }
        let tokens = tokenizer.encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        guard !tokens.isEmpty else { return nil }
        return Array(tokens.prefix(maxTokens))
    }
}
