import Foundation
@preconcurrency import WhisperKit

/// Finds, downloads and loads the Core ML model behind a `RecognitionEngine`.
enum WhisperModelStore {
    /// Where WhisperKit's downloader puts repositories, under the user's Documents folder.
    private static let cacheRoot = "huggingface/models"
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
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = documents
            .appending(path: cacheRoot)
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
    static func load(modelFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }
}
