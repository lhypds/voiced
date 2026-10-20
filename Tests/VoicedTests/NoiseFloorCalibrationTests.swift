import XCTest
@testable import Voiced

final class NoiseFloorCalibrationTests: XCTestCase {
    /// 100 ms at 16 kHz, the frame the voice detector measures.
    private let frame = 1600

    func testSilenceGivesTheLowestFloor() {
        let floor = NoiseFloorCalibration.floor(forNoise: [Float](repeating: 0, count: frame * 20))
        XCTAssertEqual(floor, LiveTranscriber.speechEnergyFloorRange.lowerBound)
    }

    func testFloorSitsAboveTheLoudestFrame() throws {
        // Nineteen quiet frames and one at RMS 0.01: the floor follows the loud one.
        var samples = [Float](repeating: 0.002, count: frame * 19)
        samples += [Float](repeating: 0.01, count: frame)
        let floor = try XCTUnwrap(NoiseFloorCalibration.floor(forNoise: samples))
        XCTAssertEqual(floor, 0.01 * NoiseFloorCalibration.margin, accuracy: 0.0001)
    }

    func testLoudNoiseIsClampedToTheRange() {
        let floor = NoiseFloorCalibration.floor(forNoise: [Float](repeating: 0.5, count: frame * 5))
        XCTAssertEqual(floor, LiveTranscriber.speechEnergyFloorRange.upperBound)
    }

    func testPartialTrailingFrameIsIgnored() throws {
        // A loud burst shorter than a frame at the end must not set the floor.
        var samples = [Float](repeating: 0.004, count: frame)
        samples += [Float](repeating: 0.5, count: frame / 2)
        let floor = try XCTUnwrap(NoiseFloorCalibration.floor(forNoise: samples))
        XCTAssertEqual(floor, 0.004 * NoiseFloorCalibration.margin, accuracy: 0.0001)
    }

    func testLessThanOneFrameGivesNoFloor() {
        XCTAssertNil(NoiseFloorCalibration.floor(forNoise: []))
        XCTAssertNil(NoiseFloorCalibration.floor(forNoise: [Float](repeating: 0.1, count: frame - 1)))
    }
}
