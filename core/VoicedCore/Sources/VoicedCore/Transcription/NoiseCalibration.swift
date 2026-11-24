import Foundation
import WhisperKit

public enum NoiseCalibration {
    /// How long the input is sampled.
    public static let duration: TimeInterval = 2
    /// Headroom above the loudest noise frame. The floor sits comfortably over the noise so a
    /// small fluctuation does not trigger a decode, while speech, which is several times louder
    /// than room noise, still clears it.
    public static let margin: Float = 1.5
    /// Frame length used by the voice detector, so the measurement matches what it sees.
    private static let frameLength = Int(0.1 * Double(WhisperKit.sampleRate))

    /// Energy floor for the given background-noise samples: the loudest 100 ms frame times
    /// `margin`, clamped to the transcriber's range. Nil when there is less than one full frame.
    public static func floor(forNoise samples: [Float]) -> Float? {
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

    public static func measure(capture: any AudioCapturing, deviceID: DeviceID? = nil) async throws -> [Float] {
        try Task.checkCancellation()
        let recorded = Recorded()
        defer { capture.stop() }
        try capture.start(deviceID: deviceID) { recorded.append($0) }
        try await Task.sleep(for: .seconds(duration))
        return recorded.samples
    }

    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Float] = []
        var samples: [Float] { lock.withLock { values } }
        func append(_ chunk: [Float]) { lock.withLock { values.append(contentsOf: chunk) } }
    }
}
