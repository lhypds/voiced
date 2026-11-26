import AVFoundation
import Foundation
import Speech
@preconcurrency import WhisperKit

extension RecognitionEngine {
    /// Whether the engine can run here. Apple's recognizer needs macOS 26 or iOS 26 and a
    /// device the system offers it on.
    public var isAvailable: Bool {
        guard self == .apple else { return true }
        if #available(macOS 26, iOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    /// The engines Settings offers on this system.
    public static var available: [RecognitionEngine] {
        allCases.filter(\.isAvailable)
    }
}

/// Decodes with the speech recognizer built into the system (`SpeechAnalyzer` with a
/// `SpeechTranscriber`), which runs on the device with a model the system downloads and keeps
/// per language, shared by every app. There is nothing to compile: a decoder is ready in well
/// under a second once the language's assets are installed, and decodes a few seconds of speech
/// in a fraction of one.
///
/// Like Whisper here, it decodes each buffer `LiveTranscriber` hands it from scratch, so the
/// buffer, pause and commit logic stays the same for every engine. It needs a fixed language;
/// there is no automatic detection.
@available(macOS 26, iOS 26, *)
public final class AppleSpeechDecoder: SpeechDecoding, @unchecked Sendable {
    public enum Failure: LocalizedError {
        case unavailable
        case unsupportedLanguage(String)
        case audioConversion

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Apple speech recognition is not available on this Mac."
            case .unsupportedLanguage(let name): "Apple speech recognition does not support \(name)."
            case .audioConversion: "The audio could not be converted for Apple speech recognition."
            }
        }
    }

    /// The locale the recognizer runs in.
    public let locale: Locale
    /// The audio format the recognizer asked for (16 kHz mono 16-bit here).
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var storedContextualStrings: [String] = []

    /// Words the recognizer should prefer: the recognition prompt's terms. Read at every decode.
    public var contextualStrings: [String] {
        get { lock.withLock { storedContextualStrings } }
        set { lock.withLock { storedContextualStrings = newValue } }
    }

    public var tokenizer: (any WhisperTokenizer)? { nil }

    private init(locale: Locale, format: AVAudioFormat) {
        self.locale = locale
        self.format = format
    }

    /// A decoder for `language`, installing the system's assets for it first when they are not
    /// on the device yet. `progress` is called, with a 0...1 fraction, only while downloading.
    public static func prepare(
        for language: RecognitionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppleSpeechDecoder {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let locale = await locale(for: language) else {
            throw Failure.unsupportedLanguage(language.nativeName)
        }
        let module = makeTranscriber(locale: locale)
        if await AssetInventory.status(forModules: [module]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            progress(0)
            let observation = request.progress.observe(\.fractionCompleted) { report, _ in
                progress(min(max(report.fractionCompleted, 0), 1))
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Failure.unavailable
        }
        return AppleSpeechDecoder(locale: locale, format: format)
    }

    /// The recognizer's locale for `language`: in the user's own region when the recognizer has
    /// it (English as spoken in Britain for a British user), otherwise the language's main one.
    static func locale(for language: RecognitionLanguage) async -> Locale? {
        guard let code = language.code else { return nil }
        var candidates: [String] = []
        if language.chineseScript == .traditional {
            candidates = ["zh-TW", "zh-HK"]
        } else if code == "zh" {
            candidates = ["zh-CN"]
        } else {
            if let region = Locale.current.region?.identifier {
                candidates.append("\(code)-\(region)")
            }
            candidates.append(code)
        }
        for identifier in candidates {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                return locale
            }
        }
        return nil
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    public func decode(_ samples: [Float], options: DecodingOptions, callback: TranscriptionCallback?) async throws -> [TranscriptionResult] {
        guard !samples.isEmpty else { return [] }
        let module = Self.makeTranscriber(locale: locale)
        // Lingering keeps the model in memory between the decodes of a recording, each of which
        // uses an analyzer of its own.
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let strings = contextualStrings
        if !strings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = strings
            try await analyzer.setContext(context)
        }
        let buffer = try convert(samples)
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let collector = Task {
            var results: [SpeechTranscriber.Result] = []
            for try await result in module.results where result.isFinal {
                results.append(result)
            }
            return results
        }
        do {
            try await analyzer.start(inputSequence: input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let segments = try await collector.value.enumerated().map { Self.segment(from: $1, id: $0) }
            .filter { !$0.text.isEmpty }
        let text = segments.map(\.text).joined(separator: " ")
        return [TranscriptionResult(text: text, segments: segments, language: options.language ?? "", timings: TranscriptionTimings())]
    }

    /// The samples as one buffer in the recognizer's format.
    private func convert(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WhisperKit.sampleRate), channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { throw Failure.audioConversion }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if format == source { return input }

        guard let converter = AVAudioConverter(from: source, to: format) else { throw Failure.audioConversion }
        let capacity = AVAudioFrameCount((Double(samples.count) * format.sampleRate / source.sampleRate).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.audioConversion }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? Failure.audioConversion }
        return output
    }

    /// A recognizer result as a Whisper segment, with a timing for each word, which is what lets
    /// `LiveTranscriber.splitAtPunctuation` close a sentence inside the result.
    private static func segment(from result: SpeechTranscriber.Result, id: Int) -> TranscriptionSegment {
        var words: [WordTiming] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = tidiedWord(String(result.text[run.range].characters))
            guard !word.isEmpty else { continue }
            words.append(WordTiming(word: word, tokens: [], start: Float(range.start.seconds), end: Float(range.end.seconds), probability: 1))
        }
        return TranscriptionSegment(
            id: id,
            start: Float(result.range.start.seconds),
            end: Float(result.range.end.seconds),
            text: tidiedText(String(result.text.characters)),
            tokenLogProbs: [],
            words: words.isEmpty ? nil : words
        )
    }

    /// Punctuation the recognizer writes with a space in front of it, as in "很好 ，".
    private static let punctuation: Set<Character> = ["。", "！", "？", "，", "、", "；", "：", ".", "!", "?", ",", ";", ":"]

    /// The text without the spaces the recognizer puts before punctuation.
    static func tidiedText(_ text: String) -> String {
        var result = ""
        for character in text {
            if punctuation.contains(character) {
                while result.last?.isWhitespace == true { result.removeLast() }
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A word that is only punctuation loses its leading space; other words keep theirs, which
    /// separates them from the word before, as in Whisper's word timings.
    static func tidiedWord(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, trimmed.count == 1, punctuation.contains(first) { return trimmed }
        return trimmed.isEmpty ? "" : word
    }
}
