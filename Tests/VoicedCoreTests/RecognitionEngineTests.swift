import XCTest
@testable import VoicedCore

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
        for engine in [RecognitionEngine.turbo, .accurate, .medium, .small] {
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

    func testGeneralModelsOfferEveryLanguageAndSpecializedOnesOnlyTheirOwn() {
        XCTAssertEqual(RecognitionLanguage.choices(for: .turbo), RecognitionLanguage.choices)
        XCTAssertEqual(RecognitionLanguage.choices(for: .accurate), RecognitionLanguage.choices)
        XCTAssertEqual(RecognitionLanguage.choices(for: .belleTurbo).map(\.code), ["zh"])
        XCTAssertEqual(RecognitionLanguage.choices(for: .kotoba).map(\.code), ["ja"])
        XCTAssertFalse(RecognitionLanguage.choices(for: .kotoba).contains(.automatic))
    }

    func testEachModelStartsWithAutomaticDetectionWhenItHasItOtherwiseItsFirstLanguage() {
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .turbo), .automatic)
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .accurate), .automatic)
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .belleTurbo).code, "zh")
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .kotoba).code, "ja")
        for engine in RecognitionEngine.allCases {
            XCTAssertTrue(RecognitionLanguage.choices(for: engine).contains(RecognitionLanguage.defaultChoice(for: engine)))
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
