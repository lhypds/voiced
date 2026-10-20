import Foundation

/// Which WhisperKit model drives recognition. Shown in Settings by model name.
enum RecognitionEngine: String, CaseIterable, Identifiable, Sendable {
    /// OpenAI Whisper large-v3 Turbo: faster, lighter.
    case turbo
    /// OpenAI Whisper large-v3: more accurate, slower.
    case accurate
    /// Belle-whisper-large-v3-turbo-zh: Whisper large-v3 Turbo fine-tuned on Mandarin by the BELLE
    /// team. The full large-v3 fine-tune exists too, but its Core ML conversion is unquantized
    /// (slower than real time here) and that checkpoint emits no punctuation, so lines could not be
    /// split; it is not offered.
    case belleTurbo

    var id: String { rawValue }

    /// Model name shown in Settings, the same in every interface language.
    var displayName: String {
        switch self {
        case .turbo: "Whisper Large v3 Turbo"
        case .accurate: "Whisper Large v3"
        case .belleTurbo: "Belle Whisper Large v3 Turbo zh"
        }
    }

    /// Whether the model was fine-tuned for Mandarin only. Other languages suffer with it.
    var isChineseSpecialized: Bool {
        switch self {
        case .turbo, .accurate: false
        case .belleTurbo: true
        }
    }

    /// Hugging Face repository holding the Core ML model folder.
    var repo: String {
        switch self {
        case .turbo, .accurate: "argmaxinc/whisperkit-coreml"
        case .belleTurbo: "wolfofbackstreet/BELLE-2_Belle-whisper-large-v3-turbo-zh-whisperkit-4bit"
        }
    }

    /// The model folder's name, which is also what WhisperKit searches the repository for.
    var modelFolderName: String {
        switch self {
        case .turbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .accurate: "openai_whisper-large-v3-v20240930_626MB"
        case .belleTurbo: "BELLE-2_Belle-whisper-large-v3-turbo-zh-whisperkit-4bit"
        }
    }

    /// Search string for WhisperKit's downloader: the folder name without the "openai_whisper-"
    /// prefix it adds itself when several folders match.
    var modelVariant: String {
        switch self {
        case .turbo: "large-v3-v20240930_turbo_632MB"
        case .accurate: "large-v3-v20240930_626MB"
        case .belleTurbo: modelFolderName
        }
    }
}
