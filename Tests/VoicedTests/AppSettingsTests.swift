import XCTest
@testable import Voiced

final class AppSettingsTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicedTests.Settings.\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let settings = AppSettings(fileURL: fileURL)

        XCTAssertEqual(settings.appLanguage, AppLanguage.systemDefault)
        XCTAssertEqual(settings.recognitionLanguage, .automatic)
        XCTAssertEqual(settings.recognitionEngine, .turbo)
        XCTAssertEqual(settings.timestampMode, .current)
        XCTAssertTrue(settings.showTimestampDate)
        XCTAssertTrue(settings.noiseReduction)
        XCTAssertTrue(settings.keepWindowOnTop)
        XCTAssertFalse(settings.translation)
        XCTAssertNil(settings.translationLanguage, "the interface language stands in until one is picked")
        XCTAssertEqual(settings.translationEmphasis, .original)
        XCTAssertFalse(settings.speakTranslation)
        XCTAssertEqual(settings.speechVoices, [:])
        XCTAssertNil(settings.translationRules, "the old target language stands in until rules are saved")
        XCTAssertEqual(settings.speechEnergyFloor, LiveTranscriber.defaultSpeechEnergyFloor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "reading must not create the file")
    }

    func testDetectionLanguagesDefaultToNoneAndDropUnknownCodes() throws {
        let settings = AppSettings(fileURL: fileURL)
        XCTAssertEqual(settings.detectionLanguages, [], "none listed means every language")

        settings.detectionLanguages = ["zh", "en"]
        XCTAssertEqual(AppSettings(fileURL: fileURL).detectionLanguages, ["zh", "en"], "the listed order is kept")

        settings.detectionLanguages = ["ja", "xx", "ja"]
        XCTAssertEqual(AppSettings(fileURL: fileURL).detectionLanguages, ["ja"])

        settings.detectionLanguages = RecognitionLanguage.detectable.compactMap(\.code).reversed()
        XCTAssertEqual(AppSettings(fileURL: fileURL).detectionLanguages, [], "listing every language is the same as none")

        settings.detectionLanguages = []
        XCTAssertNil(try storedValue("detectionLanguages"))
    }

    func testResetForgetsEveryPreference() throws {
        let settings = AppSettings(fileURL: fileURL)
        settings.keepWindowOnTop = false
        settings.recognitionEngine = .accurate
        settings.detectionLanguages = ["zh"]

        settings.reset()

        let reread = AppSettings(fileURL: fileURL)
        XCTAssertTrue(reread.keepWindowOnTop)
        XCTAssertEqual(reread.recognitionEngine, .turbo)
        XCTAssertEqual(reread.detectionLanguages, [])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(object?.isEmpty, true)
    }

    func testSpeechEnergyFloorRoundTripsAndClamps() throws {
        let settings = AppSettings(fileURL: fileURL)

        settings.speechEnergyFloor = 0.01
        XCTAssertEqual(AppSettings(fileURL: fileURL).speechEnergyFloor, 0.01, accuracy: 0.0001)
        XCTAssertEqual(try storedValue("speechEnergyFloor") as? Double ?? 0, 0.01, accuracy: 0.0001)

        settings.speechEnergyFloor = 5
        XCTAssertEqual(settings.speechEnergyFloor, LiveTranscriber.speechEnergyFloorRange.upperBound)
    }

    func testValuesRoundTrip() {
        let settings = AppSettings(fileURL: fileURL)

        settings.appLanguage = .japanese
        settings.recognitionLanguage = RecognitionLanguage.choice(id: "ja")
        settings.recognitionEngine = .accurate
        settings.timestampMode = .relative
        settings.showTimestampDate = false
        settings.keepWindowOnTop = false
        settings.translation = true
        settings.translationLanguage = .german
        settings.translationEmphasis = .translation
        settings.speakTranslation = true
        settings.speechVoices = ["zh": "com.apple.voice.compact.zh-TW.Meijia"]
        settings.translationRules = [
            TranslationRule(source: .chinese, target: .japanese),
            TranslationRule(source: nil, target: .english),
        ]

        let reloaded = AppSettings(fileURL: fileURL)
        XCTAssertEqual(reloaded.appLanguage, .japanese)
        XCTAssertEqual(reloaded.recognitionLanguage.code, "ja")
        XCTAssertEqual(reloaded.recognitionEngine, .accurate)
        XCTAssertEqual(reloaded.timestampMode, .relative)
        XCTAssertFalse(reloaded.showTimestampDate)
        XCTAssertFalse(reloaded.keepWindowOnTop)
        XCTAssertTrue(reloaded.translation)
        XCTAssertEqual(reloaded.translationLanguage, .german)
        XCTAssertEqual(reloaded.translationEmphasis, .translation)
        XCTAssertTrue(reloaded.speakTranslation)
        XCTAssertEqual(reloaded.speechVoices, ["zh": "com.apple.voice.compact.zh-TW.Meijia"])
        XCTAssertEqual(reloaded.translationRules?.map(\.source), [.chinese, nil])
        XCTAssertEqual(reloaded.translationRules?.map(\.target), [.japanese, .english])
    }

    func testStorageKeysAreStable() throws {
        let settings = AppSettings(fileURL: fileURL)
        settings.appLanguage = .english
        settings.recognitionLanguage = RecognitionLanguage.choice(id: "zh")
        settings.recognitionEngine = .accurate
        settings.timestampMode = .relative
        settings.showTimestampDate = true
        settings.noiseReduction = false
        settings.keepWindowOnTop = true
        settings.translation = true
        settings.translationLanguage = .chinese
        settings.translationEmphasis = .translation
        settings.speakTranslation = true

        XCTAssertEqual(try storedValue("appLanguage") as? String, "english")
        XCTAssertEqual(try storedValue("translation") as? Bool, true)
        XCTAssertEqual(try storedValue("translationLanguage") as? String, "chinese")
        XCTAssertEqual(try storedValue("translationEmphasis") as? String, "translation")
        XCTAssertEqual(try storedValue("speakTranslation") as? Bool, true)
        XCTAssertEqual(try storedValue("noiseReduction") as? Bool, false)
        XCTAssertEqual(try storedValue("recognitionLanguage") as? String, "zh")
        XCTAssertEqual(try storedValue("recognitionEngine") as? String, "accurate")
        XCTAssertEqual(try storedValue("timestampMode") as? String, "relative")
        XCTAssertEqual(try storedValue("showTimestampDate") as? Bool, true)
        XCTAssertEqual(try storedValue("keepWindowOnTop") as? Bool, true)
    }

    func testUnknownStoredValuesFallBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"appLanguage": "klingon", "recognitionLanguage": "xx", "translationLanguage": "klingon", "translationEmphasis": "both"}"#.utf8).write(to: fileURL)

        let settings = AppSettings(fileURL: fileURL)
        XCTAssertEqual(settings.appLanguage, AppLanguage.systemDefault)
        XCTAssertEqual(settings.recognitionLanguage, .automatic)
        XCTAssertNil(settings.translationLanguage)
        XCTAssertEqual(settings.translationEmphasis, .original)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(AppSettings(fileURL: fileURL).recognitionEngine, .turbo)
    }

    func testLegacyDefaultsAreImportedOnce() {
        let suiteName = "VoicedTests.AppSettings.Legacy"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("japanese", forKey: "appLanguage")
        defaults.set("accurate", forKey: "recognitionEngine")
        defaults.set(true, forKey: "showTimestampDate")
        defaults.set(0.005, forKey: "speechEnergyFloor")

        AppSettings.importLegacyDefaults(defaults, into: fileURL)

        let settings = AppSettings(fileURL: fileURL)
        XCTAssertEqual(settings.appLanguage, .japanese)
        XCTAssertEqual(settings.recognitionEngine, .accurate)
        XCTAssertTrue(settings.showTimestampDate)
        XCTAssertEqual(settings.speechEnergyFloor, 0.005, accuracy: 0.0001)
        XCTAssertEqual(settings.timestampMode, .current, "keys missing from the defaults keep their default")

        // Once the file exists the defaults are no longer consulted.
        defaults.set("english", forKey: "appLanguage")
        AppSettings.importLegacyDefaults(defaults, into: fileURL)
        XCTAssertEqual(AppSettings(fileURL: fileURL).appLanguage, .japanese)
    }

    func testNothingToImportCreatesNoFile() {
        let suiteName = "VoicedTests.AppSettings.Empty"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        AppSettings.importLegacyDefaults(defaults, into: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func storedValue(_ key: String) throws -> Any? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        return object?[key]
    }
}
