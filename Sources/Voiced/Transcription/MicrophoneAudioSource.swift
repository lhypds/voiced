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

    /// While set, the input is stored as silence.
    private let mute: InputMute?

    init(profile: NoiseProfile?, mute: InputMute? = nil) {
        denoiser = profile.map { SpectralDenoiser(profile: $0) }
        self.mute = mute
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
final class InputMute: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }
}
