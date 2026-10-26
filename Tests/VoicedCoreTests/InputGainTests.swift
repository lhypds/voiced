import XCTest
@testable import VoicedCore

final class InputGainTests: XCTestCase {
    func testZeroDecibelsLeavesTheInputAlone() {
        let gain = InputGain()
        XCTAssertEqual(gain.apply([0.1, -0.5]), [0.1, -0.5])
    }

    func testBoostAndCutScaleByDecibelsAndClipAtFullScale() {
        let gain = InputGain()
        gain.decibels = 20
        let boosted = gain.apply([0.05, 0.5, -0.5])
        XCTAssertEqual(boosted[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(boosted[1], 1)
        XCTAssertEqual(boosted[2], -1)
        gain.decibels = -20
        XCTAssertEqual(gain.apply([0.5])[0], 0.05, accuracy: 0.0001)
    }

    func testDecibelsAreClampedToTheSliderRange() {
        let gain = InputGain()
        gain.decibels = 60
        XCTAssertEqual(gain.decibels, InputGain.range.upperBound, accuracy: 0.001)
    }

    func testSettingDefaultsToZeroAndIsClamped() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let settings = AppSettings(fileURL: fileURL)
        XCTAssertEqual(settings.inputGain, 0)
        settings.inputGain = 6
        XCTAssertEqual(AppSettings(fileURL: fileURL).inputGain, 6)
        settings.inputGain = -100
        XCTAssertEqual(settings.inputGain, InputGain.range.lowerBound)
    }
}
