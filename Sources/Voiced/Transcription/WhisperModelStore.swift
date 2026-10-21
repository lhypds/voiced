import ArgmaxCore
import Foundation
@preconcurrency import WhisperKit

/// One of the Core ML components WhisperKit loads, in load order.
enum ModelComponent: Int, CaseIterable, Sendable {
    case featureExtractor
    case textDecoder
    case audioEncoder
}

/// Finds, downloads and loads the Core ML model behind a `RecognitionEngine`.
enum WhisperModelStore {
    /// Where WhisperKit's downloader puts repositories, under the user's Documents folder.
    private static let cacheRoot = "huggingface/models"
    /// The model cache: one folder per Hugging Face repository. Nil without a Documents folder.
    static var cacheDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: cacheRoot)
    }
    /// Files that must all exist before a cached model is trusted. Guards against interrupted downloads.
    /// Only the three Core ML bundles: community conversions do not always ship a `config.json`,
    /// and WhisperKit reads the model's shape from the bundles themselves.
    private static let requiredFiles = [
        "AudioEncoder.mlmodelc/coremldata.bin",
        "AudioEncoder.mlmodelc/weights/weight.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin",
        "TextDecoder.mlmodelc/coremldata.bin",
        "TextDecoder.mlmodelc/weights/weight.bin",
    ]

    /// The local folder of a fully downloaded model, or nil if it still has to be downloaded.
    static func cachedModelFolder(for engine: RecognitionEngine) -> URL? {
        let fileManager = FileManager.default
        guard let cacheDirectory else { return nil }
        let folder = cacheDirectory
            .appending(path: engine.repo)
            .appending(path: engine.modelFolderName)
        let isComplete = requiredFiles.allSatisfy {
            fileManager.fileExists(atPath: folder.appending(path: $0).path)
        }
        return isComplete ? folder : nil
    }

    /// Downloads the model from Hugging Face, reporting progress as a 0...1 fraction.
    static func download(
        _ engine: RecognitionEngine,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(variant: engine.modelVariant, from: engine.repo) { report in
            progress(min(max(report.fractionCompleted, 0), 1))
        }
    }

    /// Loads an already downloaded model into memory.
    ///
    /// WhisperKit loads the feature extractor, the text decoder and the audio encoder one after
    /// another and reports nothing but a debug log line as each begins. Core ML compiles a model
    /// for the Neural Engine the first time a process loads it, which takes minutes for the
    /// encoder of a large model, so `onComponent` is the only sign of life to show meanwhile.
    static func load(
        modelFolder: URL,
        onComponent: (@Sendable (ModelComponent) -> Void)? = nil
    ) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            textDecoder: LanguageLimitedDecoder(),
            verbose: onComponent != nil,
            logLevel: .debug,
            prewarm: false,
            load: true,
            download: false
        )
        if let onComponent {
            Logging.updateCallback { message in
                if let component = Self.component(startingIn: message) {
                    onComponent(component)
                }
            }
        }
        defer {
            Logging.updateCallback(nil)
            Logging.updateLogLevel(.none)
        }
        return try await WhisperKit(config)
    }

    /// The component a WhisperKit log line announces the loading of, if any. Visible for tests.
    static func component(startingIn message: String) -> ModelComponent? {
        switch message {
        case "Loading feature extractor": .featureExtractor
        case "Loading text decoder": .textDecoder
        case "Loading audio encoder": .audioEncoder
        default: nil
        }
    }
}
