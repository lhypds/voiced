import AVFoundation
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Microphone capture with spectral subtraction applied before anything downstream sees the audio:
/// the recognizer, the voice detector, the level meter and the session recorder all get the cleaned
/// signal. Wraps WhisperKit's own `AudioProcessor` for device handling and resampling.
final class DenoisingAudioSource: AudioProcessing, @unchecked Sendable {
    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: false)
    }

    private let lock = NSLock()
    private let inner = AudioProcessor()
    private let denoiser: SpectralDenoiser
    private var samples = ContiguousArray<Float>()
    private var energy: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    private var callback: (([Float]) -> Void)?

    init(profile: NoiseProfile) {
        denoiser = SpectralDenoiser(profile: profile)
    }

    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }

    var audioSamples: ContiguousArray<Float> { lock.withLock { samples } }
    var relativeEnergy: [Float] { lock.withLock { energy.map(\.rel) } }

    func purgeAudioSamples(keepingLast keep: Int) {
        lock.withLock {
            if samples.count > keep {
                samples.removeFirst(samples.count - keep)
            }
        }
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        lock.withLock {
            samples = []
            energy = []
            self.callback = callback
        }
        try inner.startRecordingLive(inputDeviceID: inputDeviceID) { [weak self] chunk in
            self?.ingest(chunk)
        }
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        AsyncThrowingStream.makeStream(of: [Float].self)
    }

    func pauseRecording() {
        inner.pauseRecording()
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        if let callback {
            lock.withLock { self.callback = callback }
        }
        try inner.resumeRecordingLive(inputDeviceID: inputDeviceID) { [weak self] chunk in
            self?.ingest(chunk)
        }
    }

    /// Stops the capture and emits the audio still inside the denoiser, so nothing is cut off.
    func stopRecording() {
        inner.stopRecording()
        append(lock.withLock { denoiser.flush() })
    }

    /// Runs on the capture thread with each raw chunk.
    private func ingest(_ chunk: [Float]) {
        // The inner processor keeps its own copy of everything it captures; nobody reads it.
        inner.purgeAudioSamples(keepingLast: 0)
        append(lock.withLock { denoiser.process(chunk) })
    }

    /// Stores cleaned audio and its energy, one entry per chunk like the processor it replaces.
    private func append(_ cleaned: [Float]) {
        guard !cleaned.isEmpty else { return }
        let callback: (([Float]) -> Void)? = lock.withLock {
            samples.append(contentsOf: cleaned)
            let quietest = energy.suffix(relativeEnergyWindow).reduce(Float.infinity) { min($0, $1.avg) }
            let relative = AudioProcessor.calculateRelativeEnergy(of: cleaned, relativeTo: quietest)
            let signal = AudioProcessor.calculateEnergy(of: cleaned)
            energy.append((relative, signal.avg, signal.max, signal.min))
            return self.callback
        }
        callback?(cleaned)
    }
}
