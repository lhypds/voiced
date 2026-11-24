import ArgmaxCore
import Foundation
@preconcurrency import WhisperKit

/// One of the Core ML components WhisperKit loads, in load order.
public enum ModelComponent: Int, CaseIterable, Sendable {
    case featureExtractor
    case textDecoder
    case audioEncoder
}

/// Finds, downloads and loads the Core ML model behind a `RecognitionEngine`.
public enum WhisperModelStore {
    /// Where WhisperKit's downloader puts repositories, under the user's Documents folder.
    private static let cacheRoot = "huggingface/models"
    /// The model cache: one folder per Hugging Face repository. Nil without a Documents folder.
    public static var cacheDirectory: URL? {
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
    public static func cachedModelFolder(for engine: RecognitionEngine) -> URL? {
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
    public static func download(
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
    /// another and reports nothing but a debug log line as each begins. The first load of a model
    /// compiles it for the Neural Engine, which takes minutes for a large model (2 to 9 minutes
    /// here), so `onComponent` is the only sign of life to show meanwhile. The system keeps the
    /// compiled program under the app's code-signing identifier and the macOS build, so every
    /// later load of that model, in any later launch or rebuild of the app, takes a few seconds;
    /// a macOS update starts the compiles over. `TranscriptionController` compiles the other
    /// downloaded models in the background so a switch does not wait for one.
    ///
    /// Without `onComponent` the load leaves WhisperKit's shared logging alone, so a background
    /// load does not silence the progress of one being shown.
    public static func load(
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
            if onComponent != nil {
                Logging.updateCallback(nil)
                Logging.updateLogLevel(.none)
            }
        }
        return try await WhisperKit(config)
    }

    /// The component a WhisperKit log line announces the loading of, if any. Visible for tests.
    public static func component(startingIn message: String) -> ModelComponent? {
        switch message {
        case "Loading feature extractor": .featureExtractor
        case "Loading text decoder": .textDecoder
        case "Loading audio encoder": .audioEncoder
        default: nil
        }
    }
}
