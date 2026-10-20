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

    /// Looks up a persisted choice by id, falling back to automatic detection.
    static func choice(id: String?) -> RecognitionLanguage {
        choices.first { $0.id == id } ?? .automatic
    }
}
