import Foundation

/// A spoken language the user can pin recognition to. `code == nil` means auto detect.
public struct RecognitionLanguage: Identifiable, Hashable, Sendable {
    /// Persisted identifier: the Whisper code, "auto", or "zh-Hant" for Traditional Chinese, which
    /// Whisper decodes as plain "zh".
    public let id: String
    /// Whisper language code, or nil for automatic detection.
    public let code: String?
    /// Name shown in the picker, written in the language itself. Unused for `.automatic`.
    public let nativeName: String
    /// Han script Chinese transcripts are converted to, since Whisper mixes both freely.
    public let chineseScript: ChineseScript?

    public init(id: String? = nil, code: String?, nativeName: String, chineseScript: ChineseScript? = nil) {
        self.id = id ?? code ?? "auto"
        self.code = code
        self.nativeName = nativeName
        self.chineseScript = chineseScript
    }

    public var isAutomatic: Bool { code == nil }
    /// Chinese and Japanese transcripts are joined with full-width punctuation.
    public var usesCJKPunctuation: Bool { code == "zh" || code == "ja" }

    public static let automatic = RecognitionLanguage(code: nil, nativeName: "Auto")

    public static let choices: [RecognitionLanguage] = [
        .automatic,
        RecognitionLanguage(code: "zh", nativeName: "简体中文", chineseScript: .simplified),
        RecognitionLanguage(id: "zh-Hant", code: "zh", nativeName: "繁體中文", chineseScript: .traditional),
        RecognitionLanguage(code: "en", nativeName: "English"),
        RecognitionLanguage(code: "ja", nativeName: "日本語"),
        RecognitionLanguage(code: "ko", nativeName: "한국어"),
        RecognitionLanguage(code: "es", nativeName: "Español"),
        RecognitionLanguage(code: "fr", nativeName: "Français"),
        RecognitionLanguage(code: "de", nativeName: "Deutsch"),
        RecognitionLanguage(code: "pt", nativeName: "Português"),
        RecognitionLanguage(code: "ru", nativeName: "Русский"),
    ]

    /// The languages automatic detection can be narrowed to: every choice but automatic itself,
    /// with both Chinese scripts as one Whisper language.
    public static var detectable: [RecognitionLanguage] {
        choices.compactMap { language in
            switch language.code {
            case nil: nil
            case "zh": language.chineseScript == .simplified ? RecognitionLanguage(code: "zh", nativeName: "中文") : nil
            default: language
            }
        }
    }

    /// The choices the picker offers with a model: only the fine-tuned language for a
    /// specialized one, which recognizes nothing else well; otherwise every language, plus
    /// automatic detection when the model can do it.
    public static func choices(for engine: RecognitionEngine) -> [RecognitionLanguage] {
        if let code = engine.specializedLanguage {
            return choices.filter { $0.code == code }
        }
        return choices.filter { engine.supportsAutomaticDetection || !$0.isAutomatic }
    }

    /// The language a model starts with: automatic detection when it offers that, otherwise the
    /// first language it supports.
    public static func defaultChoice(for engine: RecognitionEngine) -> RecognitionLanguage {
        let supported = choices(for: engine)
        return supported.first { $0.isAutomatic } ?? supported.first ?? .automatic
    }

    /// Looks up a persisted choice by id, falling back to automatic detection.
    public static func choice(id: String?) -> RecognitionLanguage {
        choices.first { $0.id == id } ?? .automatic
    }
}

/// The Han script a Chinese transcript is written in.
public enum ChineseScript: Sendable {
    case simplified
    case traditional

    /// `text` with every Han character in this script; anything else is left as it is.
    public func converting(_ text: String) -> String {
        let transform = StringTransform(self == .simplified ? "Hant-Hans" : "Hans-Hant")
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}
