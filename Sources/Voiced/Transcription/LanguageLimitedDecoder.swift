import CoreML
import Foundation
import WhisperKit

/// WhisperKit's text decoder with automatic language detection narrowed to a set of languages.
///
/// Whisper detects the language from the first decoder step: the most likely of its hundred
/// language tokens wins, so a short or unclear stretch of speech can come out as Welsh or
/// Malay. With `allowedLanguages` set, only those tokens compete. Everything else is passed
/// to the wrapped decoder: `TextDecoder.detectLanguage` cannot be overridden outside WhisperKit.
final class LanguageLimitedDecoder: TextDecoding, WhisperMLModel, @unchecked Sendable {
    private let decoder = TextDecoder()
    private let lock = NSLock()
    private var _allowedLanguages: Set<String>?

    /// Whisper language codes detection may pick from; nil, or a set with fewer than two, leaves
    /// detection to WhisperKit.
    var allowedLanguages: Set<String>? {
        get { lock.withLock { _allowedLanguages } }
        set { lock.withLock { _allowedLanguages = newValue } }
    }

    var model: MLModel? {
        get { decoder.model }
        set { decoder.model = newValue }
    }

    func unloadModel() { decoder.unloadModel() }

    var tokenizer: WhisperTokenizer? {
        get { decoder.tokenizer }
        set { decoder.tokenizer = newValue }
    }

    var isModelMultilingual: Bool {
        get { decoder.isModelMultilingual }
        set { decoder.isModelMultilingual = newValue }
    }

    var logitsFilters: [any LogitsFiltering]? {
        get { decoder.logitsFilters }
        set { decoder.logitsFilters = newValue }
    }

    var supportsWordTimestamps: Bool { decoder.supportsWordTimestamps }
    var logitsSize: Int? { decoder.logitsSize }
    var kvCacheEmbedDim: Int? { decoder.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { decoder.kvCacheMaxSequenceLength }
    var windowSize: Int? { decoder.windowSize }
    var embedSize: Int? { decoder.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await decoder.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt initialPrompt: [Int]) throws -> any DecodingInputsType {
        try decoder.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(_ decoderInputs: any DecodingInputsType, withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await decoder.prefillDecoderInputs(decoderInputs, withOptions: options)
    }

    func decodeText(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options decoderOptions: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> DecodingResult {
        var result = try await decoder.decodeText(from: encoderOutput, using: decoderInputs, sampler: tokenSampler, options: decoderOptions, callback: callback)
        if let tokenizer,
           let promptLength = decoderInputs.initialPrompt.firstIndex(of: tokenizer.specialTokens.startOfTranscriptToken),
           promptLength > 0,
           let weights = result.cache?.alignmentWeights {
            result.cache?.alignmentWeights = try Self.droppingRows(promptLength, of: weights)
        }
        return result
    }

    /// The alignment weights without their first `count` rows.
    ///
    /// The decoder stores one row of weights per decoder step, prompt steps included, but the
    /// result's tokens start at start-of-transcript, and WhisperKit's word timing pairs token `i`
    /// with row `i`. With a recognition prompt (`<|startofprev|>` and the prompt tokens ahead of
    /// start-of-transcript) every word is timed from the weights of a token that many steps
    /// earlier: the timings come out anywhere in the 30 s window, usually near its end, and the
    /// transcriber drops the words as hallucinations over quiet audio. Visible for tests.
    static func droppingRows(_ count: Int, of weights: MLMultiArray) throws -> MLMultiArray {
        guard weights.shape.count == 2, let rows = weights.shape.first?.intValue, count > 0, count < rows
        else { return weights }
        let shifted = try MLMultiArray(shape: weights.shape, dataType: weights.dataType)
        weights.withUnsafeBytes { source in
            shifted.withUnsafeMutableBytes { destination, _ in
                let rowBytes = source.count / rows
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!.advanced(by: count * rowBytes),
                    byteCount: (rows - count) * rowBytes
                )
            }
        }
        return shifted
    }

    static func updateKVCache(keyTensor: MLMultiArray, keySlice: MLMultiArray, valueTensor: MLMultiArray, valueSlice: MLMultiArray, insertAtIndex index: Int) {
        TextDecoder.updateKVCache(keyTensor: keyTensor, keySlice: keySlice, valueTensor: valueTensor, valueSlice: valueSlice, insertAtIndex: index)
    }

    /// Runs the decoder one step from start-of-transcript, as WhisperKit does, and picks the
    /// allowed language with the highest logit.
    func detectLanguage(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options: DecodingOptions,
        temperature: FloatType
    ) async throws -> DecodingResult {
        guard let allowed = allowedLanguages, allowed.count > 1,
              let tokenizer,
              let encoderOutput = encoderOutput as? MLMultiArray,
              let inputs = decoderInputs as? DecodingInputs
        else {
            return try await decoder.detectLanguage(from: encoderOutput, using: decoderInputs, sampler: tokenSampler, options: options, temperature: temperature)
        }
        let candidates = allowed.compactMap { code in tokenizer.convertTokenToId("<|\(code)|>").map { (code, $0) } }

        let start = Date()
        inputs.inputIds[0] = NSNumber(value: tokenizer.specialTokens.startOfTranscriptToken)
        inputs.cacheLength[0] = 0
        let output = try await decoder.predictLogits(
            TextDecoderMLMultiArrayInputType(
                inputIds: inputs.inputIds,
                cacheLength: inputs.cacheLength,
                keyCache: inputs.keyCache,
                valueCache: inputs.valueCache,
                kvCacheUpdateMask: inputs.kvCacheUpdateMask,
                encoderOutputEmbeds: encoderOutput,
                decoderKeyPaddingMask: inputs.decoderKeyPaddingMask
            )
        ) as? TextDecoderMLMultiArrayOutputType
        guard let logits = output?.logits else { throw WhisperError.decodingLogitsFailed() }
        var timings = TranscriptionTimings()
        timings.decodingPredictions = Date().timeIntervalSince(start)

        let language = Self.mostLikely(of: candidates) { logits[[0, 0, NSNumber(value: $0)]].floatValue }
            ?? Constants.defaultLanguageCode
        return DecodingResult(
            language: language,
            languageProbs: [:],
            tokens: [],
            tokenLogProbs: [],
            text: "",
            avgLogProb: 0,
            noSpeechProb: 0,
            temperature: 0,
            compressionRatio: 0,
            timings: timings
        )
    }

    /// The code among `candidates` (code, token) whose token scores highest. Visible for tests.
    static func mostLikely(of candidates: [(code: String, token: Int)], score: (Int) -> Float) -> String? {
        candidates.max { score($0.token) < score($1.token) }?.code
    }
}
