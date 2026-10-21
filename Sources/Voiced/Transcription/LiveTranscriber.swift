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
    /// The committed boundary is never exact: WhisperKit's segment timestamp tends to sit at the
    /// onset of the next sentence, clipping its first word, while a word timing ends a little before
    /// the word's sound fades. When discarding committed audio the cut is therefore moved to the
    /// start of the nearest pause, searched up to this far before the boundary...
    static let cutSearchBefore: Float = 0.5
    /// ...and this far after it, so a pause that begins just after the last committed word is used
    /// and that word's tail is not transcribed again as a line of its own.
    private static let cutSearchAfter: Float = 0.5
    /// Without a pause, the cut falls on the quietest frame up to this far after the boundary; any
    /// later and it could land inside the next word.
    private static let cutFallbackAfter: Float = 0.1
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
    /// A decode of at least this much speech that yields no usable segment means Whisper cannot make
    /// sense of the window, usually because it opens on a clipped word; it would fail the same way
    /// on every later decode while the buffer grows, so the buffer is resynced instead.
    private static let resyncSpeechSeconds: Float = 5
    /// How far into the failed window the resync looks for a quiet frame to restart from. Whatever
    /// speech lies before that frame is lost, but a word is a far smaller loss than the whole window.
    private static let resyncSkipSeconds: Float = 1
    private static let resyncSearchSeconds: Float = 2
    /// Audio kept after the last frame of speech when preparing a decode. Whisper tends to
    /// hallucinate closing phrases over trailing room noise, so the tail is not sent to it.
    private static let decodeTailSeconds: Float = 0.5
    /// Audio kept before the first frame of speech when preparing a decode. The buffer can hold
    /// several seconds of room noise ahead of an utterance (the silence tail kept by trimming, or
    /// the lead-in before the first words); Whisper guesses text over that noise, scores it badly
    /// and the real speech behind it suffers, so the lead-in is not sent to it either.
    private static let decodeLeadSeconds: Float = 0.5

    private let whisperKit: WhisperKit
    private let audioProcessor: any AudioProcessing
    private let options: DecodingOptions
    private let inputDeviceID: DeviceID
    private let silenceThreshold: Float
    private let silenceDelay: TimeInterval
    /// Minimum frame RMS that counts as speech. Adjustable while running via `setSpeechEnergyFloor`.
    private var speechEnergyFloor: Float
    /// Judges every captured chunk, so sound that is loud but not speech, such as music, is not
    /// treated as speech by the energy gate. Nil leaves the gate to energy alone.
    private let voiceDetector: SileroVoiceDetector?
    private weak var delegate: (any LiveTranscriberDelegate)?
    /// Optional diagnostics sink for buffer and decode activity.
    private let log: (@Sendable (String) -> Void)?
    /// Receives the RMS of the newest 100 ms of audio on every poll, for level meters.
    private let levelHandler: (@Sendable (Float) -> Void)?
    /// Receives every captured sample exactly once, in order, before it can be dropped from the buffer.
    private let audioSink: (@Sendable ([Float]) -> Void)?

    private var isRunning = false
    /// Samples removed from the front of the buffer so far.
    private var discardedSampleCount = 0
    /// Samples handed to `audioSink` so far, counted from the start of the capture.
    private var capturedSampleCount = 0
    /// Seconds of audio removed from the front of the buffer so far.
    private var discardedSeconds: Float { Float(discardedSampleCount) / Self.sampleRate }
    /// Buffer length when the last decode started; audio after it has not been decoded yet.
    private var decodedSampleCount = 0
    private var lastVoiceAt = Date()
    /// True after a decode, until the pause that follows has been reported.
    private var awaitingPause = false
    private var decodeCount = 0
    private var lastCommittedEnd: Float = 0
    /// The detector's verdicts so far, by capture index.
    private var voiceActivity = VoiceActivity()
    /// Set when the detector throws; the rest of the capture is then judged by energy alone.
    private var voiceDetectorFailed = false

    /// - Parameters:
    ///   - audioProcessor: capture source; defaults to the model's own processor.
    ///     Injectable so the pipeline can be driven from a file in tests.
    ///   - voiceDetector: filters the energy gate's verdicts; see `voiceDetector`.
    ///   - audioSink: receives the raw captured audio, for saving the session to disk.
    init(
        whisperKit: WhisperKit,
        options: DecodingOptions,
        inputDeviceID: DeviceID,
        silenceThreshold: Float,
        silenceDelay: TimeInterval,
        speechEnergyFloor: Float = LiveTranscriber.defaultSpeechEnergyFloor,
        voiceDetector: SileroVoiceDetector? = nil,
        delegate: any LiveTranscriberDelegate,
        audioProcessor: (any AudioProcessing)? = nil,
        levelHandler: (@Sendable (Float) -> Void)? = nil,
        audioSink: (@Sendable ([Float]) -> Void)? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.whisperKit = whisperKit
        self.audioProcessor = audioProcessor ?? whisperKit.audioProcessor
        self.options = options
        self.inputDeviceID = inputDeviceID
        self.silenceThreshold = silenceThreshold
        self.silenceDelay = silenceDelay
        self.speechEnergyFloor = speechEnergyFloor
        self.voiceDetector = voiceDetector
        self.delegate = delegate
        self.levelHandler = levelHandler
        self.audioSink = audioSink
        self.log = log
    }

    /// Applies a new energy floor to all later voice checks and decodes.
    func setSpeechEnergyFloor(_ floor: Float) {
        speechEnergyFloor = floor
    }

    /// Starts capturing and decoding. The caller is responsible for obtaining microphone permission first.
    func start() throws {
        guard !isRunning else { return }
        try voiceDetector?.reset()
        voiceActivity = VoiceActivity()
        voiceDetectorFailed = false
        try audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID, callback: nil)
        isRunning = true
        discardedSampleCount = 0
        capturedSampleCount = 0
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
        captureNewAudio(audioProcessor.audioSamples)
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
        captureNewAudio(samples)
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
            && Self.speechSeconds(samples, from: decodedSampleCount, to: samples.count, floor: speechEnergyFloor, voice: voiceActivity, captureOffset: discardedSampleCount) >= Self.minimumSpeechSeconds
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
            if Self.speechSeconds(samples, from: decodedSampleCount, to: samples.count, floor: speechEnergyFloor, voice: voiceActivity, captureOffset: discardedSampleCount) > 0 {
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
        let options = options
        let log = log
        let delegate = delegate
        let liveText = LiveTextAccumulator()
        let floor = speechEnergyFloor
        let voice = voiceActivity
        let (samples, lead) = Self.decodeInput(buffer, floor: floor, voice: voice, captureOffset: discardedSampleCount)
        if samples.count < buffer.count {
            log?("decode input trimmed to \(bufferSpan(from: lead, count: samples.count)) of \(bufferSpan(buffer.count))")
        }
        let base = discardedSeconds + lead
        let discardedBefore = discardedSampleCount
        /// Capture index of the input's first sample, for looking up the detector's verdicts.
        let inputCaptureStart = discardedSampleCount + Int((lead * Self.sampleRate).rounded())
        let speechInInput = Self.speechSeconds(samples, from: 0, to: samples.count, floor: floor, voice: voice, captureOffset: inputCaptureStart)
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options) { [weak self] progress in
            let text = liveText.text(adding: progress)
            if let self, let delegate {
                Task { await delegate.transcriber(self, didUpdateLiveText: text, decode: decodeID) }
            }
            let stop = Self.shouldStopEarly(progress: progress, options: options)
            if stop == false {
                log?("decode aborted early after \(progress.tokens.count) tokens: repetition loop")
            }
            return stop
        }
        let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptionSegment? in
            let from = Int(segment.start * Self.sampleRate)
            let to = Int(segment.end * Self.sampleRate)
            guard Self.coversSpeech(samples, from: from, to: to, floor: floor, voice: voice, captureOffset: inputCaptureStart) else {
                log?("dropped hallucinated segment over quiet audio: \(segment.text.trimmingCharacters(in: .whitespaces))")
                return nil
            }
            let confidence = Self.averageLogProb(of: segment)
            guard confidence >= Self.minimumAverageLogProb else {
                log?("dropped low-confidence segment (avgLogprob \(confidence)): \(segment.text.trimmingCharacters(in: .whitespaces))")
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
            shifted.words = segment.words?.map { word in
                var word = word
                word.start += base
                word.end += base
                return word
            }
            return shifted
        }.flatMap(Self.splitAtPunctuation)
        awaitingPause = true
        log?("decode end: \(segments.count) segments, buffer now \(bufferSpan(audioProcessor.audioSamples.count))")
        guard isRunning, let delegate else { return }
        discardCommittedAudio(before: await delegate.transcriber(self, didDecode: segments, decode: decodeID))
        if segments.isEmpty, speechInInput >= Self.resyncSpeechSeconds {
            // The committed cut above may have moved the buffer's front since the input was taken.
            let inputStart = Int(lead * Self.sampleRate) - (discardedSampleCount - discardedBefore)
            resync(inputStart: inputStart, input: samples, floor: floor)
        }
    }

    /// Restarts the buffer at a quiet frame shortly into a window Whisper could not transcribe.
    ///
    /// Committed audio is cut at Whisper's segment boundary, which can fall inside the first word of
    /// the next sentence. Whisper then opens on a clipped word and tends to produce nonsense for the
    /// whole window, every decode scores too low to keep anything, nothing gets committed, and the
    /// buffer grows until WhisperKit's 30 s window moves past the bad start on its own: by then half
    /// a minute of speech is gone. Skipping a second to the next quiet frame loses a word at most.
    private func resync(inputStart: Int, input: [Float], floor: Float) {
        let frame = Int(Self.speechFrameSeconds * Self.sampleRate)
        let from = Int(Self.resyncSkipSeconds * Self.sampleRate)
        let to = min(input.count, from + Int(Self.resyncSearchSeconds * Self.sampleRate))
        guard to - from >= frame else { return }
        var quietest = from
        var quietestLevel = Float.infinity
        var start = from
        while start + frame <= to {
            let level = Self.rms(input[start..<(start + frame)])
            if level < floor {
                quietest = start
                break
            }
            if level < quietestLevel {
                quietestLevel = level
                quietest = start
            }
            start += frame
        }
        let cut = inputStart + quietest
        guard cut > 0 else { return }
        trimBuffer(keepingLast: audioProcessor.audioSamples.count - cut, reason: "resync")
    }

    /// Clause and sentence marks a word can end with; a segment is split after each of them.
    private static let splitPunctuation: Set<Character> = ["。", "！", "？", "，", "、", "；", "：", ".", "!", "?", ",", ";", ":"]

    /// The segment cut into pieces after every word that ends with punctuation, using WhisperKit's
    /// word timings, so the sentence assembler can close a sentence inside a Whisper segment.
    ///
    /// Whisper's own segments end where it emits a timestamp token, which for a model fine-tuned
    /// on Chinese, or any model given a prompt, is often only once per window: one segment holding
    /// several punctuated sentences. Without a cut inside it, such a segment becomes one long line
    /// and keeps the buffer growing. Splitting after clause marks as well as sentence marks costs
    /// nothing, because the assembler joins pieces that end with punctuation back without adding
    /// any. A segment without word timings, or whose timings are not in order, is returned whole.
    static func splitAtPunctuation(_ segment: TranscriptionSegment) -> [TranscriptionSegment] {
        guard let words = segment.words, words.count > 1 else { return [segment] }
        var pieces: [TranscriptionSegment] = []
        var text = ""
        var tokens: [Int] = []
        var start: Float?
        var end: Float = segment.start
        for word in words {
            guard word.start >= end - 0.01, word.end >= word.start else { return [segment] }
            if start == nil { start = word.start }
            text += word.word
            tokens += word.tokens
            end = word.end
            if let last = text.last, Self.splitPunctuation.contains(last) {
                pieces.append(piece(of: segment, text: text, tokens: tokens, start: start ?? segment.start, end: end))
                text = ""
                tokens = []
                start = nil
            }
        }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(piece(of: segment, text: text, tokens: tokens, start: start ?? segment.start, end: end))
        }
        let kept = pieces.filter { !$0.text.isEmpty }
        return kept.count > 1 ? kept : [segment]
    }

    private static func piece(of segment: TranscriptionSegment, text: String, tokens: [Int], start: Float, end: Float) -> TranscriptionSegment {
        var piece = segment
        piece.text = text.trimmingCharacters(in: .whitespaces)
        piece.tokens = tokens
        piece.tokenLogProbs = []
        piece.start = max(segment.start, start)
        piece.end = min(segment.end, max(end, piece.start))
        piece.words = nil
        return piece
    }

    /// Mean log probability of the segment's own tokens. WhisperKit stamps every segment of a window
    /// with the window's average, which lets a hallucinated opening drag down the real speech after
    /// it, and a good window carry a hallucinated segment; the per-segment value judges each alone.
    private static func averageLogProb(of segment: TranscriptionSegment) -> Float {
        let values = segment.tokenLogProbs.flatMap(\.values)
        guard !values.isEmpty else { return segment.avgLogprob }
        return values.reduce(0, +) / Float(values.count)
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

    /// Start of the pause (a quiet stretch of at least `minimumPauseSeconds`) nearest to `target`,
    /// within `cutSearchBefore` before it and `cutSearchAfter` after it. Without one, the quietest
    /// frame between `cutSearchBefore` before the boundary and `cutFallbackAfter` after it:
    /// continuous speech such as a news broadcast has no pauses between sentences, and cutting
    /// exactly at the boundary can clip the first word of the next sentence; the dip between two
    /// syllables is a safer cut.
    static func quietestCut(in samples: ContiguousArray<Float>, around target: Int) -> Int {
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
        let boundaryFrame = (clampedTarget - lower) / frame
        let minimumPauseFrames = Int((minimumPauseSeconds / cutFrameSeconds).rounded(.up))

        // Every quiet run long enough to be a pause, by the start frame nearest the boundary.
        var nearestPauseStart: Int?
        var runStart: Int?
        for index in 0...levels.count {
            let isQuiet = index < levels.count && quiet[index]
            if isQuiet {
                if runStart == nil { runStart = index }
            } else if let begin = runStart {
                runStart = nil
                guard index - begin >= minimumPauseFrames else { continue }
                if let nearest = nearestPauseStart, abs(nearest - boundaryFrame) <= abs(begin - boundaryFrame) { continue }
                nearestPauseStart = begin
            }
        }
        if let nearestPauseStart {
            return lower + nearestPauseStart * frame
        }

        let fallbackFrames = min(levels.count, boundaryFrame + Int(cutFallbackAfter / cutFrameSeconds) + 1)
        guard fallbackFrames > 0 else { return clampedTarget }
        let quietestFrame = (0..<fallbackFrames).min { levels[$0] < levels[$1] } ?? 0
        return lower + quietestFrame * frame
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

    /// Whether each 100 ms frame of `samples[from..<to]` is speech: it reaches `floor`, and the
    /// detector heard speech in it when there is one. `captureOffset` is the capture index of
    /// `samples[0]`, which places the frames among the detector's verdicts.
    private static func speechFrames<C: RandomAccessCollection>(
        _ samples: C, from: Int, to: Int, floor: Float, voice: VoiceActivity?, captureOffset: Int
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
            let loud = (sum / Float(end - start)).squareRoot() >= floor
            let offset = captureOffset - samples.startIndex
            flags.append(loud && (voice?.containsSpeech(in: (start + offset)..<(end + offset)) ?? true))
            start = end
        }
        return flags
    }

    /// Seconds of speech in the range, by 100 ms frames; used to decide whether to decode.
    private static func speechSeconds<C: RandomAccessCollection>(
        _ samples: C, from: Int, to: Int, floor: Float, voice: VoiceActivity? = nil, captureOffset: Int = 0
    ) -> Float where C.Element == Float, C.Index == Int {
        Float(speechFrames(samples, from: from, to: to, floor: floor, voice: voice, captureOffset: captureOffset).filter { $0 }.count) * speechFrameSeconds
    }

    /// True when the range holds enough speech, in duration and in proportion, to be a real segment.
    private static func coversSpeech<C: RandomAccessCollection>(
        _ samples: C, from: Int, to: Int, floor: Float, voice: VoiceActivity? = nil, captureOffset: Int = 0
    ) -> Bool where C.Element == Float, C.Index == Int {
        let frames = speechFrames(samples, from: from, to: to, floor: floor, voice: voice, captureOffset: captureOffset)
        let speech = frames.filter { $0 }.count
        guard !frames.isEmpty else { return false }
        return Float(speech) * speechFrameSeconds >= minimumSpeechSeconds
            && Float(speech) / Float(frames.count) >= minimumSpeechFraction
    }

    /// The buffer cut to shortly before its first frame of speech and shortly after its last, with
    /// the number of seconds removed from the front. A buffer without speech is returned whole.
    static func decodeInput(
        _ buffer: ContiguousArray<Float>, floor: Float, voice: VoiceActivity? = nil, captureOffset: Int = 0
    ) -> (samples: [Float], leadSeconds: Float) {
        let frames = speechFrames(buffer, from: 0, to: buffer.count, floor: floor, voice: voice, captureOffset: captureOffset)
        guard let firstSpeech = frames.firstIndex(of: true), let lastSpeech = frames.lastIndex(of: true) else {
            return (Array(buffer), 0)
        }
        let frame = Int(speechFrameSeconds * sampleRate)
        let start = max(0, firstSpeech * frame - Int(decodeLeadSeconds * sampleRate))
        let end = min(buffer.count, (lastSpeech + 1) * frame + Int(decodeTailSeconds * sampleRate))
        return (Array(buffer[start..<end]), Float(start) / sampleRate)
    }

    private func trimBuffer(keepingLast keep: Int, reason: String) {
        let samples = audioProcessor.audioSamples
        // Audio that arrived since the last poll must reach the sink before it can be purged.
        captureNewAudio(samples)
        let total = samples.count
        let removed = total - keep
        guard removed > 0 else { return }
        audioProcessor.purgeAudioSamples(keepingLast: keep)
        discardedSampleCount += removed
        voiceActivity.discard(before: discardedSampleCount)
        decodedSampleCount = max(0, decodedSampleCount - removed)
        log?("\(reason): dropped \(Float(removed) / Self.sampleRate)s, buffer \(bufferSpan(keep)), undecoded \(Float(keep - decodedSampleCount) / Self.sampleRate)s")
    }

    /// Hands the sink and the voice detector the samples at the end of the buffer that they have not
    /// seen yet. The buffer's end sits at `discardedSampleCount + samples.count` in the capture, so
    /// anything past the captured count is new.
    private func captureNewAudio(_ samples: ContiguousArray<Float>) {
        guard audioSink != nil || voiceDetector != nil else { return }
        let captureEnd = discardedSampleCount + samples.count
        let new = captureEnd - capturedSampleCount
        guard new > 0 else { return }
        let fresh = Array(samples.suffix(min(new, samples.count)))
        capturedSampleCount = captureEnd
        audioSink?(fresh)
        if let voiceDetector, !voiceDetectorFailed {
            do {
                voiceActivity.append(try voiceDetector.process(fresh).map { $0 >= SileroVoiceDetector.speechThreshold })
            } catch {
                voiceDetectorFailed = true
                log?("voice detector failed, judging by energy alone from here: \(error)")
            }
        }
    }

    private func bufferSpan(_ count: Int) -> String {
        bufferSpan(from: 0, count: count)
    }

    /// The span of `count` samples starting `offset` seconds into the buffer, in seconds since `start()`.
    private func bufferSpan(from offset: Float, count: Int) -> String {
        let start = discardedSeconds + offset
        return String(format: "%.2f-%.2f", start, start + Float(count) / Self.sampleRate)
    }

    /// Aborts a decode whose recent tokens repeat, which is Whisper stuck in a loop.
    ///
    /// WhisperKit's streaming example also aborts as soon as the average log probability drops below
    /// `logProbThreshold`, but that is judged on the few tokens decoded so far: a window that opens on
    /// a breath or a half word scores badly on its first tokens and the whole window, including the
    /// speech after them, is thrown away. With a steady source such as a news broadcast the same
    /// window opens the same way on every decode, and whole sentences are lost. Confidence is
    /// judged per segment after the decode instead (`minimumAverageLogProb`).
    private static func shouldStopEarly(progress: TranscriptionProgress, options: DecodingOptions) -> Bool? {
        if progress.tokens.count > compressionCheckWindow {
            let recent: [Int] = progress.tokens.suffix(compressionCheckWindow)
            if TextUtilities.compressionRatio(of: recent) > options.compressionRatioThreshold ?? 0 {
                return false
            }
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
