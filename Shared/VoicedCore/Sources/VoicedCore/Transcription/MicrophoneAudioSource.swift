import AVFoundation
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Thread-safe audio source used by every platform's capture adapter. With a noise profile,
/// spectral subtraction runs before recognition, voice detection, metering and recording.
public final class MicrophoneAudioSource: AudioProcessing, @unchecked Sendable {
    public static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    public static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    public static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }

    public func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: false)
    }

    private let lock = NSLock()
    private let capture: any AudioCapturing
    /// Nil captures the input as it is.
    private let denoiser: SpectralDenoiser?
    private var samples = ContiguousArray<Float>()
    private var energy: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    private var callback: (([Float]) -> Void)?

    /// While set, the input is stored as silence.
    private let mute: InputMute?

    public init(capture: any AudioCapturing, profile: NoiseProfile? = nil, mute: InputMute? = nil) {
        self.capture = capture
        denoiser = profile.map { SpectralDenoiser(profile: $0) }
        self.mute = mute
    }

    /// Same default as WhisperKit's processor, which this replaces.
    public var relativeEnergyWindow: Int = 20

    public var audioSamples: ContiguousArray<Float> { lock.withLock { samples } }
    public var relativeEnergy: [Float] { lock.withLock { energy.map(\.rel) } }

    public func purgeAudioSamples(keepingLast keep: Int) {
        lock.withLock {
            if samples.count > keep {
                samples.removeFirst(samples.count - keep)
            }
        }
    }

    public func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        lock.withLock {
            samples = []
            energy = []
            self.callback = callback
        }
        try capture.start(deviceID: inputDeviceID) { [weak self] chunk in
            self?.ingest(chunk)
        }
    }

    public func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.stopRecording() }
        do { try startRecordingLive(inputDeviceID: inputDeviceID) { continuation.yield($0) } }
        catch { continuation.finish(throwing: error) }
        return (stream, continuation)
    }

    public func pauseRecording() {
        capture.pause()
    }

    public func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        if let callback {
            lock.withLock { self.callback = callback }
        }
        try capture.resume()
    }

    /// Stops the capture and emits the audio still inside the denoiser, so nothing is cut off.
    public func stopRecording() {
        capture.stop()
        if let rest = lock.withLock({ denoiser?.flush() }) {
            append(rest)
        }
    }

    /// Runs on the capture thread with each raw chunk.
    private func ingest(_ chunk: [Float]) {
        // The denoiser still sees the real input, so its state is current once the mute lifts.
        let processed = lock.withLock { denoiser?.process(chunk) ?? chunk }
        if mute?.isMuted == true {
            appendSilence(count: processed.count)
        } else {
            append(processed)
        }
    }

    /// Stores `count` samples of silence in place of muted input: the capture keeps its length,
    /// so later timestamps stay right, and nothing in it is heard as speech.
    private func appendSilence(count: Int) {
        guard count > 0 else { return }
        let chunk = [Float](repeating: 0, count: count)
        let callback: (([Float]) -> Void)? = lock.withLock {
            samples.append(contentsOf: chunk)
            // An average of infinity keeps the silence out of the quietest level later chunks are
            // measured against; at zero, every sound after the mute would count as loud.
            energy.append((0, .infinity, 0, 0))
            return self.callback
        }
        callback?(chunk)
    }

    /// Stores the audio and its energy, one entry per chunk like the processor this replaces.
    private func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let callback: (([Float]) -> Void)? = lock.withLock {
            samples.append(contentsOf: chunk)
            let quietest = energy.suffix(relativeEnergyWindow).reduce(Float.infinity) { min($0, $1.avg) }
            let relative = AudioProcessor.calculateRelativeEnergy(of: chunk, relativeTo: quietest)
            let signal = AudioProcessor.calculateEnergy(of: chunk)
            energy.append((relative, signal.avg, signal.max, signal.min))
            return self.callback
        }
        callback?(chunk)
    }
}

/// Whether the input is to be ignored, set while the app plays speech that the microphone, or a
/// loopback of the system output, would otherwise pick up and recognize. Read on the capture thread.
public final class InputMute: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var muted = false

    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }
}
