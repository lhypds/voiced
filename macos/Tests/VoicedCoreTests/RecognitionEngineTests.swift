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
        XCTAssertEqual(RecognitionLanguage.choices(for: .belleTurbo).map(\.id), ["zh", "zh-Hant"])
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

    func testChineseIsOfferedInBothScriptsButDetectedAsOneLanguage() {
        XCTAssertEqual(RecognitionLanguage.choice(id: "zh").chineseScript, .simplified, "settings saved before the split stay Simplified")
        XCTAssertEqual(RecognitionLanguage.choice(id: "zh-Hant").chineseScript, .traditional)
        XCTAssertEqual(RecognitionLanguage.choice(id: "zh-Hant").code, "zh")
        XCTAssertEqual(RecognitionLanguage.detectable.filter { $0.code == "zh" }.map(\.id), ["zh"])
        XCTAssertEqual(Set(RecognitionLanguage.choices.map(\.id)).count, RecognitionLanguage.choices.count)
    }

    func testAppleSpeechNeedsAFixedLanguageAndHasNoRussian() {
        let choices = RecognitionLanguage.choices(for: .apple)
        XCTAssertFalse(choices.contains(.automatic))
        XCTAssertFalse(choices.contains { $0.code == "ru" })
        XCTAssertEqual(choices.map(\.id), ["zh", "zh-Hant", "en", "ja", "ko", "es", "fr", "de", "pt"])
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .apple, preferredLanguages: ["ja-JP", "zh-Hans-CN"]).id, "ja")
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .apple, preferredLanguages: ["zh-Hant-TW"]).id, "zh-Hant")
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .apple, preferredLanguages: ["zh-HK"]).id, "zh-Hant")
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .apple, preferredLanguages: ["ru-RU", "en-GB"]).id, "en", "Russian is skipped")
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .apple, preferredLanguages: ["ru-RU"]).id, "zh", "nothing supported: the first choice")
        XCTAssertEqual(RecognitionLanguage.defaultChoice(for: .belleTurbo, preferredLanguages: ["en-US"]).id, "zh")
        XCTAssertFalse(RecognitionEngine.apple.isWhisper)
        XCTAssertNil(WhisperModelStore.cachedModelFolder(for: .apple), "nothing to download from Hugging Face")
    }

    @available(macOS 26, *)
    func testAppleSpeechTextLosesTheSpaceBeforePunctuation() {
        XCTAssertEqual(AppleSpeechDecoder.tidiedText("今天天气很好 ，我们去公园散步吧 ，然后一起吃午饭。"), "今天天气很好，我们去公园散步吧，然后一起吃午饭。")
        XCTAssertEqual(AppleSpeechDecoder.tidiedText(" Hello , world . "), "Hello, world.")
        XCTAssertEqual(AppleSpeechDecoder.tidiedWord(" ，"), "，")
        XCTAssertEqual(AppleSpeechDecoder.tidiedWord(" world"), " world", "a word keeps the space that separates it")
        XCTAssertEqual(AppleSpeechDecoder.tidiedWord(" "), "")
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
