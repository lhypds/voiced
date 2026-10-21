import AVFoundation
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Microphone capture for the recognizer, on the app's own `InputCapture` rather than WhisperKit's
/// engine, which cannot start on a Bluetooth headset. With a noise profile the audio goes through
/// spectral subtraction before anything downstream sees it: the recognizer, the voice detector,
/// the level meter and the session recorder all get the cleaned signal.
final class MicrophoneAudioSource: AudioProcessing, @unchecked Sendable {
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
    private let capture = InputCapture()
    /// Nil captures the input as it is.
    private let denoiser: SpectralDenoiser?
    private var samples = ContiguousArray<Float>()
    private var energy: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    private var callback: (([Float]) -> Void)?

    init(profile: NoiseProfile?) {
        denoiser = profile.map { SpectralDenoiser(profile: $0) }
    }

    /// Same default as WhisperKit's processor, which this replaces.
    var relativeEnergyWindow: Int = 20

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
        try capture.start(deviceID: inputDeviceID) { [weak self] chunk in
            self?.ingest(chunk)
        }
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        AsyncThrowingStream.makeStream(of: [Float].self)
    }

    func pauseRecording() {
        capture.pause()
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        if let callback {
            lock.withLock { self.callback = callback }
        }
        try capture.resume()
    }

    /// Stops the capture and emits the audio still inside the denoiser, so nothing is cut off.
    func stopRecording() {
        capture.stop()
        if let rest = lock.withLock({ denoiser?.flush() }) {
            append(rest)
        }
    }

    /// Runs on the capture thread with each raw chunk.
    private func ingest(_ chunk: [Float]) {
        append(lock.withLock { denoiser?.process(chunk) ?? chunk })
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
