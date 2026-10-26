import Foundation
import NaturalLanguage

/// Decides on the machine, before anything is sent, whether a sentence is worth asking the AI
/// about: everyday speech is not, so most lines never leave the device. The checks are cheap
/// heuristics; the service still judges what it is sent, so a false alarm costs one request and
/// a miss costs one hint.
public enum HintTrigger {
    /// What in a sentence calls for a hint.
    public enum Reason: Equatable {
        /// The sentence asks something.
        case question
        /// A Latin word inside Chinese, Japanese or Korean text, as a term or name usually is.
        case foreignWord
        /// A token mixing letters and digits, an acronym or a camel-cased name: a model, a
        /// product, a standard.
        case codeLikeToken
        /// A long katakana word in Japanese: a loanword or a technical term.
        case katakanaWord
        /// A person, place or organisation the system's name tagger found.
        case name
        /// A word the system's spell checker does not know, in a language it checks.
        case unknownWord
    }

    /// Whether `text` should be sent for hints.
    @MainActor
    public static func shouldAsk(_ text: String) -> Bool {
        reason(for: text) != nil
    }

    /// Why `text` should be sent for hints, or nil when it reads as everyday speech.
    @MainActor
    public static func reason(for text: String) -> Reason? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isQuestion(text) { return .question }
        let language = dominantLanguage(of: text)
        if hasCodeLikeToken(text) { return .codeLikeToken }
        if isCJK(language), hasForeignWord(text) { return .foreignWord }
        if language == .japanese, hasLongKatakanaWord(text) { return .katakanaWord }
        if hasName(text, language: language) { return .name }
        if hasUnknownWord(text, language: language) { return .unknownWord }
        return nil
    }

    // MARK: - Questions

    /// Words and endings that mark a question in the interface languages, matched anywhere.
    private static let questionMarkers: [String] = [
        // Chinese
        "吗", "呢", "什么", "为什么", "怎么", "怎样", "如何", "哪", "谁", "多少", "是不是", "有没有", "能不能", "可不可以",
        // Japanese
        "ですか", "ますか", "なぜ", "どうして", "どう", "何", "誰", "どこ", "いつ", "どれ", "どんな",
    ]
    /// Words that open a question in the Latin-script interface languages, matched at the start.
    private static let questionOpeners: [String] = [
        "what", "why", "how", "who", "whom", "whose", "where", "when", "which", "is", "are", "do", "does", "did", "can", "could", "should", "would", "will",
        "pourquoi", "comment", "qu'est-ce", "est-ce", "quel", "quelle", "quels", "quelles", "où", "quand", "qui",
        "qué", "por qué", "cómo", "dónde", "quién", "cuándo", "cuál", "cuáles",
        "warum", "wie", "was", "wer", "wo", "wann", "welche", "welcher", "welches", "wieso", "weshalb",
    ]

    public static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’」』)） ").union(.whitespaces))
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }
        if questionMarkers.contains(where: { trimmed.contains($0) }) { return true }
        let lowered = trimmed.lowercased()
        return questionOpeners.contains { opener in
            lowered.hasPrefix(opener + " ") || lowered.hasPrefix(opener + "'")
        }
    }

    // MARK: - Tokens

    private static let codeLikeToken = try! NSRegularExpression(pattern: #"""
        (?x)
        \b(?:
            [A-Za-z]+[\-_]?\d+[A-Za-z0-9\-_]*     # H100, GPT-4, CUDA12
          | \d+[A-Za-z]{2,}[A-Za-z0-9]*           # 3nm is too common; 4K no; 12GB yes
          | [A-Z]{3,}[A-Za-z0-9]*                 # CUDA, GPU, NASA
          | [A-Za-z]*[a-z][A-Z][A-Za-z]*          # iPhone, macOS, OpenAI: a small letter right before a capital
        )\b
        """#)

    public static func hasCodeLikeToken(_ text: String) -> Bool {
        codeLikeToken.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let latinWord = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z'\-]{3,}"#)

    /// A Latin word of four letters or more, long enough not to be "OK" or "app".
    public static func hasForeignWord(_ text: String) -> Bool {
        latinWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let katakanaWord = try! NSRegularExpression(pattern: #"[ァ-ヺー]{6,}"#)

    /// Six katakana or more in a row: past the everyday loanwords like レストラン.
    public static func hasLongKatakanaWord(_ text: String) -> Bool {
        katakanaWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - System analysis

    private static func dominantLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private static func isCJK(_ language: NLLanguage?) -> Bool {
        [.simplifiedChinese, .traditionalChinese, .japanese, .korean].contains(language)
    }

    /// Whether the name tagger finds a person, place or organisation. It knows English and
    /// Chinese; for other languages it tags nothing.
    public static func hasName(_ text: String, language: NLLanguage?) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        if let language { tagger.setLanguage(language, range: text.startIndex..<text.endIndex) }
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                found = true
            }
            return !found
        }
        return found
    }

    /// Languages the spell checker is asked about; the others have no useful dictionary here.
    private static let spellCheckedLanguages: [NLLanguage: String] = [.english: "en", .french: "fr", .spanish: "es", .german: "de"]

    /// Whether the spell checker flags a word of four letters or more. Unknown to it are
    /// mostly names, jargon and foreign words, which is what a hint is for.
    @MainActor
    public static func hasUnknownWord(_ text: String, language: NLLanguage?) -> Bool {
        guard let language, let code = spellCheckedLanguages[language] else { return false }
        let whole = text as NSString
        var start = 0
        while start < whole.length {
            let range = SystemSpelling.misspelledRange(in: text, startingAt: start, language: code)
            guard range.location != NSNotFound else { return false }
            let word = whole.substring(with: range)
            if word.count >= 4, word.allSatisfy(\.isLetter) { return true }
            start = range.location + range.length
        }
        return false
    }
}
