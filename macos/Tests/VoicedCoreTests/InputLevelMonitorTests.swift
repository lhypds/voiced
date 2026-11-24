import XCTest
@testable import VoicedCore

final class InputLevelMonitorTests: XCTestCase {
    private let frame = InputLevelMonitor.Window.length

    func testLevelIsTheRMSOfTheChunk() {
        let window = InputLevelMonitor.Window()
        XCTAssertEqual(window.append([Float](repeating: 0.5, count: frame)), 0.5, accuracy: 0.0001)
    }

    func testOnlyTheNewestFrameCounts() {
        let window = InputLevelMonitor.Window()
        _ = window.append([Float](repeating: 0.5, count: frame))
        // A full quiet frame pushes the loud one out entirely.
        XCTAssertEqual(window.append([Float](repeating: 0.01, count: frame)), 0.01, accuracy: 0.0001)
    }

    func testShortChunksAccumulateIntoOneFrame() {
        let window = InputLevelMonitor.Window()
        _ = window.append([Float](repeating: 0.3, count: frame / 2))
        let level = window.append([Float](repeating: 0.1, count: frame / 2))
        let expected = ((0.3 * 0.3 + 0.1 * 0.1) / 2).squareRoot()
        XCTAssertEqual(level, Float(expected), accuracy: 0.0001)
    }

    func testEmptyChunkGivesZero() {
        XCTAssertEqual(InputLevelMonitor.Window().append([]), 0)
    }
}

final class DenoisedWindowTests: XCTestCase {
    private let frame = InputLevelMonitor.Window.length

    private func whiteNoise(amplitude: Float, seconds: Float, seed: UInt64) -> [Float] {
        var generator = LinearCongruentialGenerator(seed: seed)
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    func testWithoutAProfileThereIsNoLevel() {
        let window = InputLevelMonitor.DenoisedWindow()
        XCTAssertNil(window.append([Float](repeating: 0.1, count: frame)))
    }

    func testProfiledNoiseComesOutQuieterThanItWentIn() throws {
        let noise = whiteNoise(amplitude: 0.05, seconds: 1, seed: 1)
        let window = InputLevelMonitor.DenoisedWindow()
        window.setProfile(try XCTUnwrap(NoiseProfile(noise: noise)))
        var level: Float = 0
        for start in stride(from: 0, to: noise.count, by: frame) {
            level = try XCTUnwrap(window.append(Array(noise[start..<min(start + frame, noise.count)])))
        }
        let raw = InputLevelMonitor.Window().append(Array(noise.suffix(frame)))
        XCTAssertLessThan(level, raw / 2)
    }

    func testClearingTheProfileStopsTheLevel() throws {
        let window = InputLevelMonitor.DenoisedWindow()
        window.setProfile(try XCTUnwrap(NoiseProfile(noise: [Float](repeating: 0.01, count: frame))))
        XCTAssertNotNil(window.append([Float](repeating: 0.1, count: frame)))
        window.setProfile(nil)
        XCTAssertNil(window.append([Float](repeating: 0.1, count: frame)))
    }
}

private struct LinearCongruentialGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
