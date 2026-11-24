import Foundation
import NaturalLanguage

/// Translates lines in one language into another: "when the speech is Chinese, translate it into
/// Japanese". The rules are tried in order and the first that fits a line is used.
public struct TranslationRule: Identifiable, Equatable, Sendable {
    /// Only tells the rules apart in the settings list; not stored.
    public let id: UUID
    /// The language a line must be in; nil fits a line in any language no earlier rule names.
    public var source: AppLanguage?
    public var target: AppLanguage

    public init(id: UUID = UUID(), source: AppLanguage?, target: AppLanguage) {
        self.id = id
        self.source = source
        self.target = target
    }

    /// The rule stored as a JSON object, `{"source": "chinese", "target": "japanese"}`, with no
    /// source for a rule that fits any language.
    public var stored: [String: String] {
        var object = ["target": target.rawValue]
        object["source"] = source?.rawValue
        return object
    }

    /// Nil when the object names a language this version does not know.
    public init?(stored object: [String: String]) {
        guard let target = object["target"].flatMap(AppLanguage.init(rawValue:)) else { return nil }
        let source = object["source"].map(AppLanguage.init(rawValue:))
        // A source that is present but unknown must not widen the rule to every language.
        if case .some(.none) = source { return nil }
        self.init(source: source ?? nil, target: target)
    }
}

/// The languages a translation session works between, as `AppLanguage.code` codes. A nil
/// source leaves it to the translator to identify.
public struct LanguagePair: Hashable, Sendable {
    public init(source: String?, target: String) {
        self.source = source
        self.target = target
    }
    public let source: String?
    public let target: String
}

extension [TranslationRule] {
    /// The rules with each source kept only in its first rule. A later rule for the same source
    /// could never be used, and would read as if it were.
    public var withoutRepeatedSources: [TranslationRule] {
        var seen: [AppLanguage?] = []
        return filter { rule in
            guard !seen.contains(rule.source) else { return false }
            seen.append(rule.source)
            return true
        }
    }

    /// The rule a line in `language` is translated by, or nil to leave the line as it is. A rule
    /// naming the language wins; failing that, the first rule for any language, unless the line
    /// is already in that rule's target. A line of unknown language only fits a rule for any
    /// language.
    public func rule(for language: String?) -> TranslationRule? {
        if let language, let named = first(where: { $0.source?.code == language }) {
            return named.target.code == language ? nil : named
        }
        return first { $0.source == nil && $0.target.code != language }
    }
}

/// Tells which language a recognized sentence is in, for picking its translation rule when the
/// speech is not pinned to one language.
public enum LineLanguage {
    /// ISO 639-1 code of the language of `text`, such as `zh` for both Chinese scripts, or nil
    /// when it cannot tell.
    public static func code(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue.split(separator: "-").first.map(String.init)
    }
}
