import Foundation

/// Finds and downloads the Core ML build of the Silero VAD model behind `SileroVoiceDetector`.
/// It is cached next to the Whisper models, under `~/Documents/huggingface/models`.
enum VoiceDetectorModelStore {
    static let repo = "FluidInference/silero-vad-coreml"
    static let modelFolderName = "silero-vad-unified-v6.0.0.mlmodelc"
    /// Every file of the compiled model. All must exist before the cache is trusted.
    private static let files = [
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
        "analytics/coremldata.bin",
    ]

    /// The local folder of the fully downloaded model, or nil if it still has to be downloaded.
    static func cachedModelFolder() -> URL? {
        guard let folder = modelFolder() else { return nil }
        let fileManager = FileManager.default
        let isComplete = files.allSatisfy { fileManager.fileExists(atPath: folder.appending(path: $0).path) }
        return isComplete ? folder : nil
    }

    /// Downloads the model from Hugging Face into the cache and returns its folder. About 1 MB.
    static func download() async throws -> URL {
        guard let folder = modelFolder() else { throw NoCacheDirectory() }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "voiced-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        for file in files {
            let remote = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(modelFolderName)/\(file)")!
            let (downloaded, response) = try await URLSession.shared.download(from: remote)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw DownloadFailed(file: file)
            }
            let destination = staging.appending(path: file)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: downloaded, to: destination)
        }
        try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        try fileManager.moveItem(at: staging, to: folder)
        return folder
    }

    private static func modelFolder() -> URL? {
        WhisperModelStore.cacheDirectory?.appending(path: repo).appending(path: modelFolderName)
    }

    private struct NoCacheDirectory: LocalizedError {
        var errorDescription: String? { "The Documents folder could not be found." }
    }

    private struct DownloadFailed: LocalizedError {
        let file: String
        var errorDescription: String? { "The speech detection model could not be downloaded (\(file))." }
    }
}
