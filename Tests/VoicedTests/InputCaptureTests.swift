import AVFoundation
import XCTest
@testable import Voiced

final class InputCaptureResamplerTests: XCTestCase {
    private func sine(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<frames {
                data[i] = amplitude * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    func testBluetoothRateComesOutAt16kWithTheSignalIntact() throws {
        let resampler = InputCapture.Resampler()
        var total = 0
        for _ in 0..<5 {
            let chunk = try XCTUnwrap(resampler.chunk(from: sine(sampleRate: 24000, channels: 1, frames: 2400)))
            total += chunk.count
            // 0.5 * sqrt(0.5) for a sine, allowing for the converter's ramp on the first chunk.
            XCTAssertGreaterThan(rms(chunk), 0.25)
        }
        // 5 chunks of 100 ms at 16 kHz, less the converter's own latency.
        XCTAssertGreaterThan(total, 7500)
        XCTAssertLessThanOrEqual(total, 8000)
    }

    func testStereo48kBecomesMono() throws {
        let chunk = try XCTUnwrap(InputCapture.Resampler().chunk(from: sine(sampleRate: 48000, channels: 2, frames: 4800)))
        // 100 ms less the converter's priming latency, which the next chunk makes up.
        XCTAssertGreaterThan(chunk.count, 1300)
        XCTAssertLessThanOrEqual(chunk.count, 1600)
        XCTAssertGreaterThan(rms(chunk), 0.25)
    }

    func testTargetFormatPassesThrough() throws {
        let chunk = try XCTUnwrap(InputCapture.Resampler().chunk(from: sine(sampleRate: 16000, channels: 1, frames: 1600)))
        XCTAssertEqual(chunk.count, 1600)
        XCTAssertEqual(rms(chunk), 0.5 * Float(0.5).squareRoot(), accuracy: 0.01)
    }

    func testFormatChangeMidStreamIsFollowed() throws {
        let resampler = InputCapture.Resampler()
        _ = try XCTUnwrap(resampler.chunk(from: sine(sampleRate: 48000, channels: 1, frames: 4800)))
        let chunk = try XCTUnwrap(resampler.chunk(from: sine(sampleRate: 24000, channels: 1, frames: 2400)))
        XCTAssertGreaterThan(chunk.count, 1400)
        XCTAssertGreaterThan(rms(chunk), 0.25)
    }

    func testEmptyBufferGivesNothing() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        XCTAssertNil(InputCapture.Resampler().chunk(from: empty))
    }
}
