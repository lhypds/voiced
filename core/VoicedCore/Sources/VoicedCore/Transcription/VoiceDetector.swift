import CoreML
import Foundation

/// Speech detection with the Silero VAD model, in its Core ML build from FluidInference: a small
/// recurrent network trained to tell speech from everything else, including music, so it filters
/// sound the energy gate alone lets through. It judges the audio in 32 ms chunks and carries its
/// recurrent state from one chunk to the next, so chunks must be fed in order without gaps.
///
/// Call `process` with audio in any chunk sizes; it returns one probability per chunk completed.
/// Not thread-safe: call it from one thread at a time.
public final class SileroVoiceDetector: @unchecked Sendable {
    /// Samples per judged chunk at 16 kHz.
    public static let chunkLength = 512
    /// Samples of the previous chunk the model sees again ahead of the current one.
    private static let contextLength = 64
    private static let stateLength = 128
    /// Probability at or above which a chunk counts as speech. Silero's own default.
    public static let speechThreshold: Float = 0.5

    private let model: MLModel
    private let input: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = [Float](repeating: 0, count: SileroVoiceDetector.contextLength)
    private var pending: [Float] = []

    /// Loads the compiled model from `modelFolder` (an `.mlmodelc` directory). The model is tiny,
    /// so it runs on the CPU; that keeps it off the Neural Engine Whisper is using.
    public init(modelFolder: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelFolder, configuration: configuration)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.contextLength + Self.chunkLength)], dataType: .float32)
        hidden = try Self.zeroState()
        cell = try Self.zeroState()
    }

    /// Forgets everything heard so far. Call before a new capture.
    public func reset() throws {
        hidden = try Self.zeroState()
        cell = try Self.zeroState()
        context = [Float](repeating: 0, count: Self.contextLength)
        pending = []
    }

    /// Judges every chunk completed by `samples`, returning its speech probability; audio that does
    /// not fill a chunk yet is kept for the next call.
    public func process(_ samples: [Float]) throws -> [Float] {
        pending.append(contentsOf: samples)
        var probabilities: [Float] = []
        var start = 0
        while start + Self.chunkLength <= pending.count {
            probabilities.append(try predict(Array(pending[start..<start + Self.chunkLength])))
            start += Self.chunkLength
        }
        pending.removeFirst(start)
        return probabilities
    }

    private func predict(_ chunk: [Float]) throws -> Float {
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for (index, value) in context.enumerated() {
                buffer[index] = value
            }
            for (index, value) in chunk.enumerated() {
                buffer[Self.contextLength + index] = value
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": input,
            "hidden_state": hidden,
            "cell_state": cell,
        ])
        let output = try model.prediction(from: features)
        guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
              let newHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let newCell = output.featureValue(for: "new_cell_state")?.multiArrayValue
        else { throw UnexpectedOutput() }
        hidden = newHidden
        cell = newCell
        context = Array(chunk.suffix(Self.contextLength))
        return probability[0].floatValue
    }

    private static func zeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(shape: [1, NSNumber(value: stateLength)], dataType: .float32)
        state.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.update(repeating: 0)
        }
        return state
    }

    private struct UnexpectedOutput: LocalizedError {
        public var errorDescription: String? { "The speech detection model returned no verdict." }
    }
}

/// The detector's verdicts for a capture: one flag per 32 ms chunk, positioned by capture sample
/// index so they stay valid while the transcriber drops audio from the front of its buffer.
public struct VoiceActivity: Equatable {
    public static let chunkLength = SileroVoiceDetector.chunkLength
    /// Capture index of the first sample of `chunks[0]`.
    public private(set) var start = 0
    public private(set) var chunks: [Bool] = []

    /// Capture index just past the last judged sample.
    public var end: Int { start + chunks.count * Self.chunkLength }

    public mutating func append(_ flags: [Bool]) {
        chunks.append(contentsOf: flags)
    }

    /// Forgets the chunks that end at or before `captureIndex`.
    public mutating func discard(before captureIndex: Int) {
        let count = min(chunks.count, max(0, (captureIndex - start) / Self.chunkLength))
        guard count > 0 else { return }
        chunks.removeFirst(count)
        start += count * Self.chunkLength
    }

    /// Chunks after a range that are still looked at for speech. The detector's recurrent state
    /// needs a few hundred milliseconds of a voice before its probability crosses the threshold, so
    /// it calls the onset of an utterance quiet; in a word as short as "你好" that onset is nearly
    /// the whole word, and Whisper places the word there. Measured lags were 0.2 to 0.3 s.
    public static let onsetLagChunks = 10

    /// Whether the detector heard speech in `range` of the capture: true when any chunk overlapping
    /// it, or any of the `onsetLagChunks` after it, is speech. A range no judged chunk overlaps, such
    /// as the audio still waiting to fill a chunk, is left to the caller's other checks and counts
    /// as speech.
    public func containsSpeech(in range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        let first = max(0, (range.lowerBound - start) / Self.chunkLength)
        let last = (range.upperBound - 1 - start) / Self.chunkLength
        guard first <= min(chunks.count - 1, last), range.upperBound > start else { return true }
        return chunks[first...min(chunks.count - 1, last + Self.onsetLagChunks)].contains(true)
    }
}
