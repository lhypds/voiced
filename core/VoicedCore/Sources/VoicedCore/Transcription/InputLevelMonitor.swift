import Combine
import Foundation
@preconcurrency import WhisperKit

/// Publishes raw and denoised input levels using the platform capture adapter. Nothing is
/// decoded or saved. Mobile clients stop this meter before starting another audio operation.
@MainActor
public final class InputLevelMonitor: ObservableObject {
    /// RMS of the newest 100 ms of input, 0 while not listening.
    @Published public private(set) var level: Float = 0
    /// RMS of the newest 100 ms of input after noise reduction with the profile from
    /// `setNoiseProfile`; 0 while not listening or without a profile.
    @Published public private(set) var denoisedLevel: Float = 0

    private let denoised = DenoisedWindow()

    private var capture: (any AudioCapturing)?
    private let makeCapture: @Sendable () -> any AudioCapturing
    private var listening = false
    /// The device being listened to, or asked for while permission and capture are pending.
    private var deviceID: DeviceID?
    private var startTask: Task<Void, Never>?

    public nonisolated init(makeCapture: @escaping @Sendable () -> any AudioCapturing) { self.makeCapture = makeCapture }

    /// Starts listening to `deviceID`, replacing any earlier capture; nil stops. Listening to the
    /// current device again is a no-op, so the view can call this on every state change.
    public func listen(to deviceID: DeviceID?, useDefaultInput: Bool = false) {
        guard !listening || deviceID != self.deviceID || (!useDefaultInput && deviceID == nil) else { return }
        stop()
        guard deviceID != nil || useDefaultInput else { return }
        self.deviceID = deviceID
        listening = true
        startTask = Task { [weak self] in
            let granted = await AudioProcessor.requestRecordPermission()
            guard let self, !Task.isCancelled, self.listening, self.deviceID == deviceID else { return }
            guard granted else {
                // Leave the device unset so a later request tries again.
                self.deviceID = nil
                self.listening = false
                return
            }
            self.startCapture(from: deviceID)
        }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        capture?.stop()
        capture = nil
        deviceID = nil
        listening = false
        level = 0
        denoisedLevel = 0
    }

    /// The background noise to subtract for `denoisedLevel`; nil leaves that level at 0.
    public func setNoiseProfile(_ profile: NoiseProfile?) {
        denoised.setProfile(profile)
    }

    private func startCapture(from deviceID: DeviceID?) {
        let capture = makeCapture()
        let window = Window()
        let denoised = denoised
        denoised.restart()
        do {
            try capture.start(deviceID: deviceID) { [weak self, weak capture] chunk in
                // Runs on the capture thread; only the newest frame is ever kept.
                let level = window.append(chunk)
                let denoisedLevel = denoised.append(chunk) ?? 0
                Task { @MainActor in
                    guard let self, self.capture === capture else { return }
                    self.level = level
                    self.denoisedLevel = denoisedLevel
                }
            }
        } catch {
            self.deviceID = nil
            self.listening = false
            return
        }
        self.capture = capture
    }

    /// Runs the capture through spectral subtraction and keeps the newest frame of the result.
    /// The profile is set from the main thread, the audio arrives on the capture thread.
    final class DenoisedWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var profile: NoiseProfile?
        private var denoiser: SpectralDenoiser?
        private var window = Window()

        func setProfile(_ profile: NoiseProfile?) {
            lock.withLock {
                self.profile = profile
                rebuild()
            }
        }

        /// Forgets the audio in flight, for a capture starting afresh.
        func restart() {
            lock.withLock { rebuild() }
        }

        /// Adds the raw chunk and returns the RMS of the newest frame of denoised audio, or nil
        /// without a profile.
        func append(_ chunk: [Float]) -> Float? {
            lock.withLock {
                guard let denoiser else { return nil }
                return window.append(denoiser.process(chunk))
            }
        }

        private func rebuild() {
            denoiser = profile.map { SpectralDenoiser(profile: $0) }
            window = Window()
        }
    }

    /// The newest 100 ms of 16 kHz samples, read and written only on the capture thread.
    final class Window: @unchecked Sendable {
        /// 100 ms at 16 kHz, the frame the voice detector measures.
        static let length = Int(0.1 * Double(WhisperKit.sampleRate))

        private var samples: [Float] = []

        /// Adds the chunk and returns the RMS of the newest frame.
        func append(_ chunk: [Float]) -> Float {
            samples.append(contentsOf: chunk)
            if samples.count > Self.length {
                samples.removeFirst(samples.count - Self.length)
            }
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for value in samples { sum += value * value }
            return (sum / Float(samples.count)).squareRoot()
        }
    }
}
