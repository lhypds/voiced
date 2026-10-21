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
/// the device is assigned, tries again when the device changes its format in between, and, when
/// the format changes under the running engine, puts the tap back with the new format and starts
/// the same engine again. The engine is kept on purpose: a new one would let go of the
/// microphone, the headset would switch back, and the next engine would start the dance over.
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
        guard let format = Self.tapFormat(for: input) else { throw Error.noInputFormat }
        let resampler = Resampler()
        installTap(on: engine, format: format, resampler: resampler)
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
            self.reconfigure(engine, resampler: resampler)
        }
        lock.withLock {
            self.engine = engine
            self.observer = observer
        }
    }

    private func installTap(on engine: AVAudioEngine, format: AVAudioFormat, resampler: Resampler) {
        let bufferSize = AVAudioFrameCount(format.sampleRate * Self.chunkDuration)
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self, weak engine] buffer, _ in
            guard let self, let engine, let chunk = resampler.chunk(from: buffer) else { return }
            self.deliver(chunk, from: engine)
        }
    }

    /// The device changed its format under the running engine, which stopped it: the tap goes
    /// back on with the format the device has now and the engine starts again. A tap the engine
    /// could not create at start, because the change was already under way, is made good here.
    private func reconfigure(_ engine: AVAudioEngine, resampler: Resampler) {
        let input = engine.inputNode
        for attempt in 1...Self.startAttempts {
            guard lock.withLock({ self.engine === engine }) else { return }
            input.removeTap(onBus: 0)
            // The device may still be between formats; a moment later it reports the new one.
            if let format = Self.tapFormat(for: input) {
                installTap(on: engine, format: format, resampler: resampler)
                if (try? engine.start()) != nil { return }
                input.removeTap(onBus: 0)
            }
            guard attempt < Self.startAttempts else { return }
            Thread.sleep(forTimeInterval: Self.retryDelay)
        }
    }

    /// The format a tap on `input` must have: the device's own sample rate and channel count in
    /// the node's sample layout. The node's output format is read for the layout only: it keeps
    /// the rate the device had when the engine was last initialized, and a tap at that rate is
    /// refused (or, after a configuration change, aborts the process) once the device has moved
    /// on. Nil while the device reports no input, as a Bluetooth microphone does for a moment.
    private static func tapFormat(for input: AVAudioInputNode) -> AVAudioFormat? {
        let hardware = input.inputFormat(forBus: 0)
        let layout = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: layout.commonFormat == .otherFormat ? .pcmFormatFloat32 : layout.commonFormat,
            sampleRate: hardware.sampleRate,
            channels: hardware.channelCount,
            interleaved: layout.isInterleaved
        )
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
    final class Resampler {
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
