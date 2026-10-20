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

        XCTAssertEqual(settings.appLanguage, .chinese)
        XCTAssertEqual(settings.recognitionLanguage, .automatic)
        XCTAssertEqual(settings.recognitionEngine, .turbo)
        XCTAssertEqual(settings.timestampMode, .current)
        XCTAssertFalse(settings.showTimestampDate)
        XCTAssertTrue(settings.noiseReduction)
        XCTAssertEqual(settings.speechEnergyFloor, LiveTranscriber.defaultSpeechEnergyFloor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "reading must not create the file")
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
        settings.showTimestampDate = true

        let reloaded = AppSettings(fileURL: fileURL)
        XCTAssertEqual(reloaded.appLanguage, .japanese)
        XCTAssertEqual(reloaded.recognitionLanguage.code, "ja")
        XCTAssertEqual(reloaded.recognitionEngine, .accurate)
        XCTAssertEqual(reloaded.timestampMode, .relative)
        XCTAssertTrue(reloaded.showTimestampDate)
    }

    func testStorageKeysAreStable() throws {
        let settings = AppSettings(fileURL: fileURL)
        settings.appLanguage = .english
        settings.recognitionLanguage = RecognitionLanguage.choice(id: "zh")
        settings.recognitionEngine = .accurate
        settings.timestampMode = .relative
        settings.showTimestampDate = true
        settings.noiseReduction = false

        XCTAssertEqual(try storedValue("appLanguage") as? String, "english")
        XCTAssertEqual(try storedValue("noiseReduction") as? Bool, false)
        XCTAssertEqual(try storedValue("recognitionLanguage") as? String, "zh")
        XCTAssertEqual(try storedValue("recognitionEngine") as? String, "accurate")
        XCTAssertEqual(try storedValue("timestampMode") as? String, "relative")
        XCTAssertEqual(try storedValue("showTimestampDate") as? Bool, true)
    }

    func testUnknownStoredValuesFallBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"appLanguage": "klingon", "recognitionLanguage": "xx"}"#.utf8).write(to: fileURL)

        let settings = AppSettings(fileURL: fileURL)
        XCTAssertEqual(settings.appLanguage, .chinese)
        XCTAssertEqual(settings.recognitionLanguage, .automatic)
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
