import VoicedCore
import Foundation
@preconcurrency import WhisperKit

/// Listens to the input for a moment while the user keeps quiet, and derives an energy floor
/// just above the background noise so steady room noise is never mistaken for speech.
enum NoiseFloorCalibration {
    static let duration = NoiseCalibration.duration
    static let margin = NoiseCalibration.margin
    static func floor(forNoise samples: [Float]) -> Float? { NoiseCalibration.floor(forNoise: samples) }

    /// Records `duration` seconds from the device and returns the 16 kHz mono samples.
    /// The caller is responsible for obtaining microphone permission first.
    static func measure(inputDeviceID: DeviceID) async throws -> [Float] {
        try await NoiseCalibration.measure(capture: InputCapture(), deviceID: inputDeviceID)
    }
}
