import XCTest
@testable import Voiced

final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "VoicedTests.AppSettings"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.appLanguage, .chinese)
        XCTAssertEqual(settings.recognitionLanguage, .automatic)
        XCTAssertEqual(settings.recognitionEngine, .turbo)
        XCTAssertEqual(settings.timestampMode, .current)
        XCTAssertFalse(settings.showTimestampDate)
        XCTAssertEqual(settings.speechEnergyFloor, LiveTranscriber.defaultSpeechEnergyFloor)
    }

    func testSpeechEnergyFloorRoundTripsAndClamps() {
        let settings = AppSettings(defaults: defaults)

        settings.speechEnergyFloor = 0.01
        XCTAssertEqual(AppSettings(defaults: defaults).speechEnergyFloor, 0.01, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: "speechEnergyFloor"), 0.01, accuracy: 0.0001)

        settings.speechEnergyFloor = 5
        XCTAssertEqual(settings.speechEnergyFloor, LiveTranscriber.speechEnergyFloorRange.upperBound)
    }

    func testValuesRoundTrip() {
        let settings = AppSettings(defaults: defaults)

        settings.appLanguage = .japanese
        settings.recognitionLanguage = RecognitionLanguage.choice(id: "ja")
        settings.recognitionEngine = .accurate
        settings.timestampMode = .relative
        settings.showTimestampDate = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.appLanguage, .japanese)
        XCTAssertEqual(reloaded.recognitionLanguage.code, "ja")
        XCTAssertEqual(reloaded.recognitionEngine, .accurate)
        XCTAssertEqual(reloaded.timestampMode, .relative)
        XCTAssertTrue(reloaded.showTimestampDate)
    }

    func testStorageKeysAreStable() {
        let settings = AppSettings(defaults: defaults)
        settings.appLanguage = .english
        settings.recognitionLanguage = RecognitionLanguage.choice(id: "zh")
        settings.recognitionEngine = .accurate
        settings.timestampMode = .relative
        settings.showTimestampDate = true

        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "english")
        XCTAssertEqual(defaults.string(forKey: "recognitionLanguage"), "zh")
        XCTAssertEqual(defaults.string(forKey: "recognitionEngine"), "accurate")
        XCTAssertEqual(defaults.string(forKey: "timestampMode"), "relative")
        XCTAssertTrue(defaults.bool(forKey: "showTimestampDate"))
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        defaults.set("klingon", forKey: "appLanguage")
        defaults.set("xx", forKey: "recognitionLanguage")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appLanguage, .chinese)
        XCTAssertEqual(settings.recognitionLanguage, .automatic)
    }
}
