import Foundation
@preconcurrency import WhisperKit

/// Listens to the input for a moment while the user keeps quiet, and derives an energy floor
/// just above the background noise so steady room noise is never mistaken for speech.
enum NoiseFloorCalibration {
    /// How long the input is sampled.
    static let duration: TimeInterval = 2
    /// Headroom above the loudest noise frame. The floor sits comfortably over the noise so a
    /// small fluctuation does not trigger a decode, while speech, which is several times louder
    /// than room noise, still clears it.
    static let margin: Float = 1.5
    /// Frame length used by the voice detector, so the measurement matches what it sees.
    private static let frameLength = Int(0.1 * Double(WhisperKit.sampleRate))

    /// Energy floor for the given background-noise samples: the loudest 100 ms frame times
    /// `margin`, clamped to the transcriber's range. Nil when there is less than one full frame.
    static func floor(forNoise samples: [Float]) -> Float? {
        var loudest: Float?
        var start = 0
        while start + frameLength <= samples.count {
            var sum: Float = 0
            for value in samples[start..<start + frameLength] {
                sum += value * value
            }
            let rms = (sum / Float(frameLength)).squareRoot()
            loudest = max(loudest ?? 0, rms)
            start += frameLength
        }
        guard let loudest else { return nil }
        return min(max(loudest * margin, LiveTranscriber.speechEnergyFloorRange.lowerBound), LiveTranscriber.speechEnergyFloorRange.upperBound)
    }

    /// Records `duration` seconds from the device and returns the 16 kHz mono samples.
    /// The caller is responsible for obtaining microphone permission first.
    static func measure(inputDeviceID: DeviceID) async throws -> [Float] {
        let capture = InputCapture()
        let recorded = Recorded()
        try capture.start(deviceID: inputDeviceID) { chunk in recorded.append(chunk) }
        defer { capture.stop() }
        try await Task.sleep(for: .seconds(duration))
        return recorded.samples
    }

    /// Collects the chunks the capture thread delivers.
    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float] = []

        var samples: [Float] { lock.withLock { stored } }

        func append(_ chunk: [Float]) {
            lock.withLock { stored.append(contentsOf: chunk) }
        }
    }
}
