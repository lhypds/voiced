import XCTest
@testable import Voiced

final class RecognitionEngineTests: XCTestCase {
    /// The stored keys and cache folders are what existing installs rely on; changing them would
    /// reset the user's choice or re-download a cached model.
    func testKeysAndFoldersAreStable() {
        XCTAssertEqual(RecognitionEngine.turbo.rawValue, "turbo")
        XCTAssertEqual(RecognitionEngine.accurate.rawValue, "accurate")
        XCTAssertEqual(RecognitionEngine.turbo.repo, "argmaxinc/whisperkit-coreml")
        XCTAssertEqual(RecognitionEngine.turbo.modelFolderName, "openai_whisper-large-v3-v20240930_turbo_632MB")
        XCTAssertEqual(RecognitionEngine.accurate.modelFolderName, "openai_whisper-large-v3-v20240930_626MB")
    }

    func testOpenAIFoldersCarryThePrefixTheDownloaderAdds() {
        for engine in [RecognitionEngine.turbo, .accurate] {
            XCTAssertEqual(engine.modelFolderName, "openai_whisper-" + engine.modelVariant)
        }
    }

    func testSpecializedModelsAreSearchedByFolderName() {
        XCTAssertEqual(RecognitionEngine.belleTurbo.specializedLanguage, "zh")
        XCTAssertEqual(RecognitionEngine.kotoba.specializedLanguage, "ja")
        XCTAssertNil(RecognitionEngine.turbo.specializedLanguage)
        for engine in [RecognitionEngine.belleTurbo, .kotoba] {
            XCTAssertEqual(engine.modelVariant, engine.modelFolderName)
            XCTAssertTrue(engine.repo.contains("/"))
        }
    }

    func testDisplayNamesAreDistinct() {
        XCTAssertEqual(Set(RecognitionEngine.allCases.map(\.displayName)).count, RecognitionEngine.allCases.count)
    }
}

final class WhisperModelStoreTests: XCTestCase {
    func testComponentIsRecognizedFromWhisperKitLogLines() {
        XCTAssertEqual(WhisperModelStore.component(startingIn: "Loading feature extractor"), .featureExtractor)
        XCTAssertEqual(WhisperModelStore.component(startingIn: "Loading text decoder"), .textDecoder)
        XCTAssertEqual(WhisperModelStore.component(startingIn: "Loading audio encoder"), .audioEncoder)
        XCTAssertNil(WhisperModelStore.component(startingIn: "Loaded audio encoder in 1.20s"))
        XCTAssertNil(WhisperModelStore.component(startingIn: "Decoding Seek: 0"))
    }

    func testComponentsAreInLoadOrder() {
        XCTAssertEqual(ModelComponent.allCases.map(\.rawValue), [0, 1, 2])
    }
}
