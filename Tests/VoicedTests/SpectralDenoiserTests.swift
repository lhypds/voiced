import XCTest
@testable import Voiced

final class SpectralDenoiserTests: XCTestCase {
    private let sampleRate: Float = 16_000

    private func whiteNoise(amplitude: Float, seconds: Float, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    private func tone(hz: Float, amplitude: Float, seconds: Float) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * sin(2 * .pi * hz * Float($0) / sampleRate) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private func denoise(_ samples: [Float], with profile: NoiseProfile, chunk: Int = 1600) -> [Float] {
        let denoiser = SpectralDenoiser(profile: profile)
        var output: [Float] = []
        var start = 0
        while start < samples.count {
            output += denoiser.process(Array(samples[start..<min(start + chunk, samples.count)]))
            start += chunk
        }
        return output + denoiser.flush()
    }

    func testProfileNeedsAtLeastOneFrame() {
        XCTAssertNil(NoiseProfile(noise: [Float](repeating: 0.1, count: SpectralDenoiser.frameLength - 1)))
        XCTAssertNotNil(NoiseProfile(noise: [Float](repeating: 0.1, count: SpectralDenoiser.frameLength)))
    }

    func testProfileRoundTripsThroughStorage() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: whiteNoise(amplitude: 0.05, seconds: 1, seed: 1)))
        XCTAssertEqual(NoiseProfile(stored: profile.stored), profile)
        XCTAssertNil(NoiseProfile(stored: [1, 2, 3]))
    }

    func testSilentProfilePassesAudioThroughUnchanged() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: [Float](repeating: 0, count: SpectralDenoiser.frameLength)))
        let input = tone(hz: 440, amplitude: 0.5, seconds: 0.5) + whiteNoise(amplitude: 0.1, seconds: 0.5, seed: 2)
        let output = denoise(input, with: profile, chunk: 700)

        XCTAssertEqual(output.count, input.count)
        for (expected, actual) in zip(input, output) {
            XCTAssertEqual(actual, expected, accuracy: 1e-4)
        }
    }

    func testChunkSizeDoesNotChangeTheResult() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: whiteNoise(amplitude: 0.02, seconds: 1, seed: 3)))
        let input = tone(hz: 300, amplitude: 0.2, seconds: 1) + whiteNoise(amplitude: 0.02, seconds: 1, seed: 4)
        let whole = denoise(input, with: profile, chunk: input.count)
        let chunked = denoise(input, with: profile, chunk: 1600)

        XCTAssertEqual(whole.count, chunked.count)
        for (a, b) in zip(whole, chunked) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
    }

    func testBackgroundNoiseIsStronglyReduced() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: whiteNoise(amplitude: 0.02, seconds: 2, seed: 5)))
        // A different realization of the same noise, as the live input would be.
        let input = whiteNoise(amplitude: 0.02, seconds: 2, seed: 6)
        let output = denoise(input, with: profile)

        let before = rms(input[8000...])
        let after = rms(output[8000...])
        XCTAssertLessThan(after, before * 0.2, "expected at least 14 dB of noise reduction, got \(before) -> \(after)")
    }

    func testSpeechLevelToneSurvivesWhileNoiseDrops() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: whiteNoise(amplitude: 0.02, seconds: 2, seed: 7)))
        let speech = tone(hz: 220, amplitude: 0.2, seconds: 1)
        let noise = whiteNoise(amplitude: 0.02, seconds: 1, seed: 8)
        let input = zip(speech, noise).map(+)
        let output = denoise(input, with: profile)

        // Correlating with the clean tone measures how much of it is left.
        let kept = zip(output[1600...], speech[1600...]).reduce(0) { $0 + $1.0 * $1.1 }
            / speech[1600...].reduce(0) { $0 + $1 * $1 }
        XCTAssertGreaterThan(kept, 0.9)
        XCTAssertLessThan(kept, 1.05)
    }

    func testOutputLagsAndFlushCompletesIt() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: [Float](repeating: 0, count: SpectralDenoiser.frameLength)))
        let denoiser = SpectralDenoiser(profile: profile)
        let first = denoiser.process([Float](repeating: 0.1, count: 1600))
        // Whole hops only, less the one hop still waiting for its overlapping neighbour.
        XCTAssertEqual(first.count, 1600 - 1600 % SpectralDenoiser.hopLength - SpectralDenoiser.hopLength)
        XCTAssertEqual(first.count + denoiser.flush().count, 1600)
    }

    func testFlushWithLittleInputEmitsExactlyThatInput() throws {
        let profile = try XCTUnwrap(NoiseProfile(noise: [Float](repeating: 0, count: SpectralDenoiser.frameLength)))
        let denoiser = SpectralDenoiser(profile: profile)
        XCTAssertEqual(denoiser.process([Float](repeating: 0.1, count: 100)).count, 0)
        XCTAssertEqual(denoiser.flush().count, 100)
        XCTAssertEqual(SpectralDenoiser(profile: profile).flush().count, 0)
    }
}

/// Deterministic generator so noise tests are repeatable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
