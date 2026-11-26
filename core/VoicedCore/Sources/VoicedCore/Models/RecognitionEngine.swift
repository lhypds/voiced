import Foundation

/// Which model drives recognition: a WhisperKit model, or the recognizer built into the system.
/// Shown in Settings by model name, in the order declared here: Apple's recognizer first, then
/// the general Whisper models from smallest to largest, then the fine-tuned ones.
public enum RecognitionEngine: String, CaseIterable, Identifiable, Sendable {
    /// The speech recognizer built into macOS 26 and iOS 26 (`SpeechAnalyzer`), run through
    /// `AppleSpeechDecoder`. The system downloads and keeps its model per language. Offered only
    /// where `isAvailable`.
    case apple
    /// OpenAI Whisper small: the lightest model offered, loads fastest on iPhone.
    case small
    /// OpenAI Whisper medium: a smaller general model, unquantized.
    case medium
    /// OpenAI Whisper large-v3 Turbo: faster, lighter.
    case turbo
    /// OpenAI Whisper large-v3: more accurate, slower.
    case accurate
    /// Belle-whisper-large-v3-turbo-zh: Whisper large-v3 Turbo fine-tuned on Mandarin by the BELLE
    /// team. The full large-v3 fine-tune exists too, but its Core ML conversion is unquantized
    /// (slower than real time here) and that checkpoint emits no punctuation, so lines could not be
    /// split; it is not offered.
    case belleTurbo
    /// kotoba-whisper-v2.2: Whisper large-v3 distilled to a two-layer decoder and trained on
    /// Japanese television speech by Kotoba Technologies. Its output carries no punctuation and
    /// the conversion has no word timings, so lines follow Whisper's own segment boundaries.
    case kotoba

    public var id: String { rawValue }

    /// The model a new install starts with: Apple's recognizer where the system has it, since it
    /// needs no model download or compile; otherwise Small, the Whisper model that loads fastest.
    public static var platformDefault: RecognitionEngine { RecognitionEngine.apple.isAvailable ? .apple : .small }

    /// Model name shown in Settings, the same in every interface language.
    public var displayName: String {
        switch self {
        case .turbo: "Whisper Large v3 Turbo"
        case .accurate: "Whisper Large v3"
        case .medium: "Whisper Medium"
        case .small: "Whisper Small"
        case .belleTurbo: "Belle Whisper Large v3 Turbo zh"
        case .kotoba: "Kotoba Whisper v2.2 ja"
        case .apple: "Apple Speech"
        }
    }

    /// Whisper language code the model was fine-tuned for, or nil for a general model. Other
    /// languages suffer with a specialized model.
    public var specializedLanguage: String? {
        switch self {
        case .turbo, .accurate, .medium, .small, .apple: nil
        case .belleTurbo: "zh"
        case .kotoba: "ja"
        }
    }

    /// Whether the model is a WhisperKit model, downloaded from Hugging Face and compiled for the
    /// Neural Engine. Apple's recognizer is neither.
    public var isWhisper: Bool { self != .apple }

    /// Whether the model can work out the spoken language itself. A general Whisper model can;
    /// a fine-tuned one is only ever run in its own language, and Apple's recognizer needs one.
    public var supportsAutomaticDetection: Bool {
        isWhisper && specializedLanguage == nil
    }

    /// Ids of the `RecognitionLanguage` choices the model handles, or nil for all of them.
    /// Apple's recognizer has no Russian.
    public var supportedLanguageIDs: Set<String>? {
        switch self {
        case .apple: ["zh", "zh-Hant", "en", "ja", "ko", "es", "fr", "de", "pt"]
        default: nil
        }
    }

    /// Hugging Face repository holding the Core ML model folder.
    public var repo: String {
        switch self {
        case .turbo, .accurate, .medium, .small: "argmaxinc/whisperkit-coreml"
        case .belleTurbo: "wolfofbackstreet/BELLE-2_Belle-whisper-large-v3-turbo-zh-whisperkit-4bit"
        case .kotoba: "yslinear/kotoba-whisper-v2.2-coreml"
        case .apple: ""
        }
    }

    /// The model folder's name, which is also what WhisperKit searches the repository for.
    public var modelFolderName: String {
        switch self {
        case .turbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .accurate: "openai_whisper-large-v3-v20240930_626MB"
        case .medium: "openai_whisper-medium"
        case .small: "openai_whisper-small"
        case .belleTurbo: "BELLE-2_Belle-whisper-large-v3-turbo-zh-whisperkit-4bit"
        case .kotoba: "kotoba-tech_kotoba-whisper-v2.2"
        case .apple: ""
        }
    }

    /// Search string for WhisperKit's downloader: the folder name without the "openai_whisper-"
    /// prefix it adds itself when several folders match.
    public var modelVariant: String {
        switch self {
        case .turbo: "large-v3-v20240930_turbo_632MB"
        case .accurate: "large-v3-v20240930_626MB"
        case .medium: "medium"
        case .small: "small"
        case .belleTurbo, .kotoba, .apple: modelFolderName
        }
    }
}
