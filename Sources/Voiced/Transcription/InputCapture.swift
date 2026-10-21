import AVFoundation
import Foundation
@preconcurrency import WhisperKit

/// Captures one input device on its own `AVAudioEngine` and hands the audio out as 16 kHz mono
/// chunks of about 100 ms, on the capture thread.
///
/// WhisperKit's `AudioProcessor` reads the device's sample rate once, before its engine starts,
/// and installs its tap with that rate. A Bluetooth headset such as AirPods changes its rate the
/// moment its microphone is engaged (48 kHz to 24 kHz), so that engine fails to initialize with
/// "formats don't match" (-10868) and recording never starts. This reads the format only after
/// the device is assigned, tries again when the device changes its format in between, and starts
/// over after a configuration change, which otherwise stops the engine without a word.
final class InputCapture: @unchecked Sendable {
    typealias Chunk = ([Float]) -> Void

    enum Error: LocalizedError {
        /// The device could not be assigned to the engine: it is gone or has no input.
        case deviceUnavailable(OSStatus)
        /// The device reports no input format; a Bluetooth microphone does this for a moment
        /// while it comes up.
        case noInputFormat

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable(let status): "The input device is not available (\(status))."
            case .noInputFormat: "The input device has no input format."
            }
        }
    }

    /// Sample rate of the delivered chunks.
    static let sampleRate = Double(WhisperKit.sampleRate)
    /// Length of a chunk in seconds; the engine's buffer size is chosen to match.
    static let chunkDuration: TimeInterval = 0.1
    /// How many times the engine is started before giving up.
    private static let startAttempts = 3
    /// Pause before another attempt: a Bluetooth microphone takes a moment to settle.
    private static let retryDelay: TimeInterval = 0.15

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var deviceID: DeviceID?
    private var onChunk: Chunk?
    private var observer: (any NSObjectProtocol)?

    deinit { stop() }

    /// Starts capturing from `deviceID`, or the system's default input when nil, replacing any
    /// earlier capture. `onChunk` runs on the capture thread.
    func start(deviceID: DeviceID?, onChunk: @escaping Chunk) throws {
        stop()
        lock.withLock {
            self.deviceID = deviceID
            self.onChunk = onChunk
        }
        try startEngine()
    }

    func pause() {
        lock.withLock { engine }?.pause()
    }

    /// Continues after `pause`, or starts afresh when nothing is capturing.
    func resume() throws {
        if let engine = lock.withLock({ engine }) {
            try engine.start()
        } else {
            try startEngine()
        }
    }

    func stop() {
        let (engine, observer) = lock.withLock {
            defer {
                self.engine = nil
                self.observer = nil
            }
            return (self.engine, self.observer)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Engine

    private func startEngine() throws {
        var attempt = 1
        while true {
            do {
                try startEngineOnce()
                return
            } catch {
                guard attempt < Self.startAttempts else { throw error }
                attempt += 1
                Thread.sleep(forTimeInterval: Self.retryDelay)
            }
        }
    }

    private func startEngineOnce() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID = lock.withLock({ deviceID }) {
            try Self.assign(deviceID, to: input)
        }
        // Only now, with the device assigned, does the node report that device's format.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Error.noInputFormat }
        let resampler = Resampler()
        let bufferSize = AVAudioFrameCount(format.sampleRate * Self.chunkDuration)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self, weak engine] buffer, _ in
            guard let self, let engine, let chunk = resampler.chunk(from: buffer) else { return }
            self.deliver(chunk, from: engine)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.restart(after: engine)
        }
        lock.withLock {
            self.engine = engine
            self.observer = observer
        }
    }

    /// The device changed its format or went away under the running engine, which stopped it.
    /// Builds a new engine for the same device so the capture carries on where the device allows.
    private func restart(after stopped: AVAudioEngine) {
        guard lock.withLock({ engine === stopped }) else { return }
        stop()
        try? startEngine()
    }

    private func deliver(_ chunk: [Float], from engine: AVAudioEngine) {
        guard let onChunk = lock.withLock({ self.engine === engine ? onChunk : nil }) else { return }
        onChunk(chunk)
    }

    private static func assign(_ deviceID: DeviceID, to input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw Error.deviceUnavailable(kAudioUnitErr_InvalidElement) }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<DeviceID>.size)
        )
        guard status == noErr else { throw Error.deviceUnavailable(status) }
    }

    // MARK: - Resampling

    /// Converts the tap's buffers to 16 kHz mono. Used on the capture thread only; the converter
    /// is built from the first buffer and again whenever the format changes.
    private final class Resampler {
        private let target = AVAudioFormat(standardFormatWithSampleRate: InputCapture.sampleRate, channels: 1)!
        private var converter: AVAudioConverter?

        func chunk(from buffer: AVAudioPCMBuffer) -> [Float]? {
            guard buffer.frameLength > 0 else { return nil }
            if buffer.format == target {
                return AudioProcessor.convertBufferToArray(buffer: buffer)
            }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter else { return nil }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            // The input block is asked until the output is full; the buffer goes in exactly once.
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0 else { return nil }
            return AudioProcessor.convertBufferToArray(buffer: output)
        }
    }
}
