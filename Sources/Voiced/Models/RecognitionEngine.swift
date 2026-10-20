import Foundation

/// Which WhisperKit model variant drives recognition.
enum RecognitionEngine: String, CaseIterable, Identifiable, Sendable {
    /// Large v3 Turbo: faster, lighter.
    case turbo
    /// Full Large v3: more accurate, slower.
    case accurate

    var id: String { rawValue }

    var modelVariant: String {
        switch self {
        case .turbo: "large-v3-v20240930_turbo_632MB"
        case .accurate: "large-v3-v20240930_626MB"
        }
    }

    /// Folder name used by WhisperKit's Hugging Face cache.
    var modelFolderName: String {
        "openai_whisper-\(modelVariant)"
    }
}
