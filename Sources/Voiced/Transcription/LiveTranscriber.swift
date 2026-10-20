import Foundation
@preconcurrency import WhisperKit

/// Receives the results of a `LiveTranscriber`. All methods are awaited by the transcriber, so the
/// decode loop does not continue until the delegate has handled each decode or pause.
protocol LiveTranscriberDelegate: AnyObject, Sendable {
    /// Partial text of the decode in flight. `decode` identifies the decode so stale updates can be ignored.
    func transcriber(_ transcriber: LiveTranscriber, didUpdateLiveText text: String, decode: Int) async
    /// A finished decode of all audio still in the buffer, with times in seconds since `start()`.
    /// Returns the end time of the last committed sentence; audio before it is dropped.
    func transcriber(_ transcriber: LiveTranscriber, didDecode segments: [TranscriptionSegment], decode: Int) async -> Float
    /// The speaker paused after the last decode. Returns the end time of the last committed sentence.
    func transcriberDidDetectPause(_ transcriber: LiveTranscriber) async -> Float
    func transcriber(_ transcriber: LiveTranscriber, didFailWith error: Error) async
}

/// Captures audio from one input device and decodes it with WhisperKit in a loop.
///
/// Audio before the committed point reported by the delegate is removed from the buffer, so no later
/// decode can revise or merge committed speech. Decoding, committing and discarding are strictly
/// sequential. A pause is reported once per silence of `silenceDelay` after the last decode.
actor LiveTranscriber {
    private static let sampleRate = Float(WhisperKit.sampleRate)
    /// Do not start a decode until at least this much new audio has arrived.
    private static let minimumDecodeSeconds: Float = 1
    private static let pollInterval: Duration = .milliseconds(100)
    /// Audio kept when trimming silence, so the onset of the next utterance is never cut off.
    private static let silenceTailSeconds: Float = 2
    /// Number of recent tokens checked for repetition loops, which abort a decode early.
    private static let compressionCheckWindow = 60
    /// WhisperKit's segment boundary tends to sit at the onset of the next sentence, clipping its first
    /// word. When discarding committed audio the cut is therefore moved back to the start of the pause
    /// that leads into the boundary, searching up to this far before it.
    static let cutSearchBefore: Float = 0.5
    private static let cutSearchAfter: Float = 0.1
    private static let cutFrameSeconds: Float = 0.02
    /// A quiet stretch must be at least this long to count as the pause between sentences; shorter
    /// gaps are between words of the committed sentence and must not be used, or its last word
    /// would stay in the buffer and be transcribed again.
    private static let minimumPauseSeconds: Float = 0.1
    /// A frame must be at least this much quieter than the loudest frame nearby to count as quiet.
    private static let dipRatio: Float = 0.3
    /// Default minimum RMS of a 100 ms frame for audio to count as speech, matching WhisperKit's
    /// `EnergyVAD` default. Room noise stays well below it; decoding it only yields hallucinations,
    /// and WhisperKit does not implement `noSpeechProb`, so nothing else would catch them.
    /// Quiet sources such as a speaker across the room need a lower floor; see `speechEnergyFloor`.
    static let defaultSpeechEnergyFloor: Float = 0.02
    /// Range the user can move the floor within.
    static let speechEnergyFloorRange: ClosedRange<Float> = 0.002...0.05
    private static let speechFrameSeconds: Float = 0.1
    /// A segment must cover at least this much audio above the floor, and at least this fraction of
    /// its span, to count as speech. A single click or breath passes neither.
    private static let minimumSpeechSeconds: Float = 0.2
    private static let minimumSpeechFraction: Float = 0.2
    /// Segments whose average token log probability is below this are noise WhisperKit guessed at.
    /// Real speech scores around -0.1; hallucinations over noise have been observed near -9.
    private static let minimumAverageLogProb: Float = -1.5
    /// Audio kept after the last frame of speech when preparing a decode. Whisper tends to
    /// hallucinate closing phrases over trailing room noise, so the tail is not sent to it.
    private static let decodeTailSeconds: Float = 0.5

    private let whisperKit: WhisperKit
    private let audioProcessor: any AudioProcessing
    private let options: DecodingOptions
    private let inputDeviceID: DeviceID
    private let silenceThreshold: Float
    private let silenceDelay: TimeInterval
    /// Minimum frame RMS that counts as speech. Adjustable while running via `setSpeechEnergyFloor`.
    private var speechEnergyFloor: Float
    private weak var delegate: (any LiveTranscriberDelegate)?
    /// Optional diagnostics sink for buffer and decode activity.
    private let log: (@Sendable (String) -> Void)?
    /// Receives the RMS of the newest 100 ms of audio on every poll, for level meters.
    private let levelHandler: (@Sendable (Float) -> Void)?

    private var isRunning = false
    /// Seconds of audio removed from the front of the buffer so far.
    private var discardedSeconds: Float = 0
    /// Buffer length when the last decode started; audio after it has not been decoded yet.
    private var decodedSampleCount = 0
    private var lastVoiceAt = Date()
    /// True after a decode, until the pause that follows has been reported.
    private var awaitingPause = false
    private var decodeCount = 0
    private var lastCommittedEnd: Float = 0

    /// - Parameter audioProcessor: capture source; defaults to the model's own processor.
    ///   Injectable so the pipeline can be driven from a file in tests.
    init(
        whisperKit: WhisperKit,
        options: DecodingOptions,
        inputDeviceID: DeviceID,
        silenceThreshold: Float,
        silenceDelay: TimeInterval,
        speechEnergyFloor: Float = LiveTranscriber.defaultSpeechEnergyFloor,
        delegate: any LiveTranscriberDelegate,
        audioProcessor: (any AudioProcessing)? = nil,
        levelHandler: (@Sendable (Float) -> Void)? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.whisperKit = whisperKit
        self.audioProcessor = audioProcessor ?? whisperKit.audioProcessor
        self.options = options
        self.inputDeviceID = inputDeviceID
        self.silenceThreshold = silenceThreshold
        self.silenceDelay = silenceDelay
        self.speechEnergyFloor = speechEnergyFloor
        self.delegate = delegate
        self.levelHandler = levelHandler
        self.log = log
    }

    /// Applies a new energy floor to all later voice checks and decodes.
    func setSpeechEnergyFloor(_ floor: Float) {
        speechEnergyFloor = floor
    }

    /// Starts capturing and decoding. The caller is responsible for obtaining microphone permission first.
    func start() throws {
        guard !isRunning else { return }
        try audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID, callback: nil)
        isRunning = true
        discardedSeconds = 0
        decodedSampleCount = 0
        lastVoiceAt = Date()
        awaitingPause = false
        lastCommittedEnd = 0
        Task { await run() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        audioProcessor.stopRecording()
    }

    // MARK: - Loop

    private func run() async {
        while isRunning {
            do {
                try await step()
            } catch is CancellationError {
                break
            } catch {
                stop()
                await delegate?.transcriber(self, didFailWith: error)
                break
            }
        }
    }

    private func step() async throws {
        let samples = audioProcessor.audioSamples
        if let levelHandler {
            let frame = Int(Self.speechFrameSeconds * Self.sampleRate)
            levelHandler(Self.rms(samples.suffix(frame)))
        }
        let newSamples = samples.count - decodedSampleCount
        let newSeconds = Float(newSamples) / Self.sampleRate
        let now = Date()
        // WhisperKit's relative-energy VAD adapts to the speaker's own level, so on its own it
        // fires on clicks and breaths; the absolute floor over at least `minimumSpeechSeconds` rules those out.
        let hasVoice = newSamples > 0
            && AudioProcessor.isVoiceDetected(
                in: audioProcessor.relativeEnergy,
                nextBufferInSeconds: newSeconds,
                silenceThreshold: silenceThreshold
            )
            && Self.speechSeconds(samples, from: decodedSampleCount, to: samples.count, floor: speechEnergyFloor) >= Self.minimumSpeechSeconds
        if hasVoice {
            lastVoiceAt = now
        }

        if hasVoice, newSeconds >= Self.minimumDecodeSeconds {
            log?("decode start: buffer \(bufferSpan(samples.count)), new \(newSeconds)s")
            try await decode(samples)
            return
        }
        if awaitingPause, now.timeIntervalSince(lastVoiceAt) >= silenceDelay {
            awaitingPause = false
            if Self.speechSeconds(samples, from: decodedSampleCount, to: samples.count, floor: speechEnergyFloor) > 0 {
                // The tail of the last word arrived after the previous decode started but was too
                // short to trigger another one. Decode it before the pause commits the sentence.
                log?("final decode before pause: buffer \(bufferSpan(samples.count)), new \(newSeconds)s")
                try await decode(samples)
                return
            }
            log?("pause: buffer \(bufferSpan(samples.count)), new \(newSeconds)s")
            if let delegate {
                discardCommittedAudio(before: await delegate.transcriberDidDetectPause(self))
            }
        }
        if !hasVoice, !awaitingPause {
            // Everything decoded so far has been committed or found empty: drop it, keeping a short
            // tail plus any audio the VAD has not released for decoding yet, so the next utterance
            // starts near the front of the buffer and memory stays bounded.
            let undecoded = max(0, samples.count - decodedSampleCount)
            trimBuffer(keepingLast: undecoded + Int(Self.silenceTailSeconds * Self.sampleRate), reason: "trim")
        }
        try await Task.sleep(for: Self.pollInterval)
    }

    private func decode(_ buffer: ContiguousArray<Float>) async throws {
        decodedSampleCount = buffer.count
        decodeCount += 1
        let decodeID = decodeCount
        let base = discardedSeconds
        let options = options
        let log = log
        let delegate = delegate
        let liveText = LiveTextAccumulator()
        let floor = speechEnergyFloor
        let samples = Self.droppingTrailingNoise(buffer, floor: floor)
        if samples.count < buffer.count {
            log?("decode input trimmed to \(Float(samples.count) / Self.sampleRate)s of \(Float(buffer.count) / Self.sampleRate)s")
        }
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options) { [weak self] progress in
            let text = liveText.text(adding: progress)
            if let self, let delegate {
                Task { await delegate.transcriber(self, didUpdateLiveText: text, decode: decodeID) }
            }
            let stop = Self.shouldStopEarly(progress: progress, options: options)
            if stop == false {
                log?("decode aborted early after \(progress.tokens.count) tokens, avgLogprob \(progress.avgLogprob ?? 0)")
            }
            return stop
        }
        let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptionSegment? in
            let from = Int(segment.start * Self.sampleRate)
            let to = Int(segment.end * Self.sampleRate)
            guard Self.coversSpeech(samples, from: from, to: to, floor: floor) else {
                log?("dropped hallucinated segment over quiet audio: \(segment.text.trimmingCharacters(in: .whitespaces))")
                return nil
            }
            guard segment.avgLogprob >= Self.minimumAverageLogProb else {
                log?("dropped low-confidence segment (avgLogprob \(segment.avgLogprob)): \(segment.text.trimmingCharacters(in: .whitespaces))")
                return nil
            }
            let text = HallucinationFilter.strip(Self.droppingPartialCharacters(segment.text))
            guard !text.isEmpty else {
                log?("dropped hallucinated phrase: \(segment.text.trimmingCharacters(in: .whitespaces))")
                return nil
            }
            var shifted = segment
            shifted.start += base
            shifted.end += base
            shifted.text = text
            return shifted
        }
        awaitingPause = true
        log?("decode end: \(segments.count) segments, buffer now \(bufferSpan(audioProcessor.audioSamples.count))")
        guard isRunning, let delegate else { return }
        discardCommittedAudio(before: await delegate.transcriber(self, didDecode: segments, decode: decodeID))
    }

    // MARK: - Buffer management

    /// Drops audio before the committed point, cutting at the quietest moment shortly before it so a
    /// word that straddles WhisperKit's segment boundary is not clipped.
    private func discardCommittedAudio(before committedEnd: Float) {
        guard committedEnd > lastCommittedEnd else { return }
        lastCommittedEnd = committedEnd
        let samples = audioProcessor.audioSamples
        let target = Int((committedEnd - discardedSeconds) * Self.sampleRate)
        guard target > 0 else { return }
        let cut = min(Self.quietestCut(in: samples, around: target), samples.count)
        trimBuffer(keepingLast: samples.count - cut, reason: "discard")
    }

    /// Start of the pause that leads into `target`, or `target` itself when the boundary is not
    /// preceded by a pause of at least `minimumPauseSeconds`.
    private static func quietestCut(in samples: ContiguousArray<Float>, around target: Int) -> Int {
        let frame = Int(cutFrameSeconds * sampleRate)
        let lower = max(0, target - Int(cutSearchBefore * sampleRate))
        let upper = min(samples.count, target + Int(cutSearchAfter * sampleRate))
        let clampedTarget = min(target, samples.count)
        guard upper - lower >= frame * 2 else { return clampedTarget }

        var levels: [Float] = []
        var start = lower
        while start + frame <= upper {
            var sum: Float = 0
            for value in samples[start..<(start + frame)] {
                sum += value * value
            }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        guard let loudest = levels.max(), loudest > 0 else { return clampedTarget }
        let quiet = levels.map { $0 <= loudest * dipRatio }

        // Walk back from the boundary through quiet frames; that stretch is the pause before the next sentence.
        let boundaryFrame = min(levels.count - 1, max(0, (clampedTarget - lower) / frame))
        var pauseStart = boundaryFrame
        var pauseEnd = boundaryFrame
        // Allow the boundary itself to sit on the first sound of the next word.
        while pauseStart > 0, !quiet[pauseStart] { pauseStart -= 1; pauseEnd = pauseStart; if boundaryFrame - pauseStart > 2 { return clampedTarget } }
        while pauseStart > 0, quiet[pauseStart - 1] { pauseStart -= 1 }
        guard quiet[pauseEnd], Float(pauseEnd - pauseStart + 1) * cutFrameSeconds >= minimumPauseSeconds else {
            return clampedTarget
        }
        return lower + pauseStart * frame
    }

    /// Whisper's tokenizer is byte-level, so a multi-byte character can be split across tokens or
    /// segment boundaries; the incomplete bytes decode to U+FFFD. Dropping it leaves the rest intact.
    static func droppingPartialCharacters(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    private static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples { sum += value * value }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Whether each 100 ms frame of `samples[from..<to]` reaches `floor`.
    private static func speechFrames<C: RandomAccessCollection>(
        _ samples: C, from: Int, to: Int, floor: Float
    ) -> [Bool] where C.Element == Float, C.Index == Int {
        let frame = Int(speechFrameSeconds * sampleRate)
        let lower = max(samples.startIndex, from)
        let upper = min(samples.endIndex, to)
        guard upper > lower else { return [] }
        var flags: [Bool] = []
        var start = lower
        while start < upper {
            let end = min(start + frame, upper)
            var sum: Float = 0
            for value in samples[start..<end] {
                sum += value * value
            }
            flags.append((sum / Float(end - start)).squareRoot() >= floor)
            start = end
        }
        return flags
    }

    /// Seconds of audio in the range whose 100 ms frames reach the floor; used to decide whether to decode.
    private static func speechSeconds<C: RandomAccessCollection>(
        _ samples: C, from: Int, to: Int, floor: Float
    ) -> Float where C.Element == Float, C.Index == Int {
        Float(speechFrames(samples, from: from, to: to, floor: floor).filter { $0 }.count) * speechFrameSeconds
    }

    /// True when the range holds enough speech energy, in duration and in proportion, to be a real segment.
    private static func coversSpeech<C: RandomAccessCollection>(
        _ samples: C, from: Int, to: Int, floor: Float
    ) -> Bool where C.Element == Float, C.Index == Int {
        let frames = speechFrames(samples, from: from, to: to, floor: floor)
        let speech = frames.filter { $0 }.count
        guard !frames.isEmpty else { return false }
        return Float(speech) * speechFrameSeconds >= minimumSpeechSeconds
            && Float(speech) / Float(frames.count) >= minimumSpeechFraction
    }

    /// The buffer cut shortly after its last frame of speech energy.
    private static func droppingTrailingNoise(_ buffer: ContiguousArray<Float>, floor: Float) -> [Float] {
        let frames = speechFrames(buffer, from: 0, to: buffer.count, floor: floor)
        guard let lastSpeech = frames.lastIndex(of: true) else { return Array(buffer) }
        let frame = Int(speechFrameSeconds * sampleRate)
        let keep = min(buffer.count, (lastSpeech + 1) * frame + Int(decodeTailSeconds * sampleRate))
        return Array(buffer.prefix(keep))
    }

    private func trimBuffer(keepingLast keep: Int, reason: String) {
        let total = audioProcessor.audioSamples.count
        let removed = total - keep
        guard removed > 0 else { return }
        audioProcessor.purgeAudioSamples(keepingLast: keep)
        discardedSeconds += Float(removed) / Self.sampleRate
        decodedSampleCount = max(0, decodedSampleCount - removed)
        log?("\(reason): dropped \(Float(removed) / Self.sampleRate)s, buffer \(bufferSpan(keep)), undecoded \(Float(keep - decodedSampleCount) / Self.sampleRate)s")
    }

    private func bufferSpan(_ count: Int) -> String {
        String(format: "%.2f-%.2f", discardedSeconds, discardedSeconds + Float(count) / Self.sampleRate)
    }

    /// Mirrors WhisperKit's streaming heuristic: abort a decode that is looping or has low confidence.
    private static func shouldStopEarly(progress: TranscriptionProgress, options: DecodingOptions) -> Bool? {
        if progress.tokens.count > compressionCheckWindow {
            let recent: [Int] = progress.tokens.suffix(compressionCheckWindow)
            if TextUtilities.compressionRatio(of: recent) > options.compressionRatioThreshold ?? 0 {
                return false
            }
        }
        if let avgLogprob = progress.avgLogprob, let threshold = options.logProbThreshold, avgLogprob < threshold {
            return false
        }
        return nil
    }
}

/// Rebuilds the full in-flight text of one decode from WhisperKit's progress callbacks.
///
/// `TranscriptionProgress.text` only covers the decoding window currently being worked on and
/// restarts for each new 30 s window. Earlier windows are kept so the live row shows everything.
/// A restart caused by a temperature fallback re-decodes the same window, so it replaces the
/// current piece instead of adding one.
private final class LiveTextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var finishedWindows: [String] = []
    private var current = ""
    private var fallbacks = 0

    func text(adding progress: TranscriptionProgress) -> String {
        lock.withLock {
            let fallbacksNow = Int(progress.timings.totalDecodingFallbacks)
            if progress.text.count < current.count, fallbacksNow == fallbacks {
                finishedWindows.append(current)
            }
            fallbacks = fallbacksNow
            current = progress.text
            return (finishedWindows + [current])
                .map { LiveTranscriber.droppingPartialCharacters($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }
}
