import Foundation

/// A spoken language the user can pin recognition to. `code == nil` means auto detect.
struct RecognitionLanguage: Identifiable, Hashable, Sendable {
    /// Whisper language code, or nil for automatic detection.
    let code: String?
    /// Name shown in the picker, written in the language itself. Unused for `.automatic`.
    let nativeName: String

    var id: String { code ?? "auto" }
    var isAutomatic: Bool { code == nil }
    /// Chinese and Japanese transcripts are joined with full-width punctuation.
    var usesCJKPunctuation: Bool { code == "zh" || code == "ja" }

    static let automatic = RecognitionLanguage(code: nil, nativeName: "Auto")

    static let choices: [RecognitionLanguage] = [
        .automatic,
        RecognitionLanguage(code: "zh", nativeName: "中文"),
        RecognitionLanguage(code: "en", nativeName: "English"),
        RecognitionLanguage(code: "ja", nativeName: "日本語"),
        RecognitionLanguage(code: "ko", nativeName: "한국어"),
        RecognitionLanguage(code: "es", nativeName: "Español"),
        RecognitionLanguage(code: "fr", nativeName: "Français"),
        RecognitionLanguage(code: "de", nativeName: "Deutsch"),
        RecognitionLanguage(code: "pt", nativeName: "Português"),
        RecognitionLanguage(code: "ru", nativeName: "Русский"),
    ]

    /// The choices the picker offers with a model: only the fine-tuned language for a
    /// specialized one, which recognizes nothing else well; otherwise every language, plus
    /// automatic detection when the model can do it.
    static func choices(for engine: RecognitionEngine) -> [RecognitionLanguage] {
        if let code = engine.specializedLanguage {
            return choices.filter { $0.code == code }
        }
        return choices.filter { engine.supportsAutomaticDetection || !$0.isAutomatic }
    }

    /// The language a model starts with: automatic detection when it offers that, otherwise the
    /// first language it supports.
    static func defaultChoice(for engine: RecognitionEngine) -> RecognitionLanguage {
        let supported = choices(for: engine)
        return supported.first { $0.isAutomatic } ?? supported.first ?? .automatic
    }

    /// Looks up a persisted choice by id, falling back to automatic detection.
    static func choice(id: String?) -> RecognitionLanguage {
        choices.first { $0.id == id } ?? .automatic
    }
}
