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

    func testBelleModelsAreSearchedByFolderName() {
        for engine in [RecognitionEngine.belleTurbo] {
            XCTAssertEqual(engine.modelVariant, engine.modelFolderName)
            XCTAssertTrue(engine.isChineseSpecialized)
            XCTAssertTrue(engine.repo.contains("/"))
        }
    }

    func testDisplayNamesAreDistinct() {
        XCTAssertEqual(Set(RecognitionEngine.allCases.map(\.displayName)).count, RecognitionEngine.allCases.count)
    }
}
