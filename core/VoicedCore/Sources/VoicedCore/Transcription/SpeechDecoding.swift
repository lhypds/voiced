import Foundation
@preconcurrency import WhisperKit

/// What `LiveTranscriber` decodes its buffer with: a WhisperKit model, or Apple's built-in
/// recognizer (`AppleSpeechDecoder`). Each call decodes one stretch of 16 kHz mono audio from
/// scratch and returns segments timed from its start, as WhisperKit does.
public protocol SpeechDecoding: AnyObject {
    /// Whisper's tokenizer, for showing in-flight text without the prompt; nil for a decoder
    /// that has none.
    var tokenizer: (any WhisperTokenizer)? { get }
    /// Decodes `samples`. `callback` receives in-flight progress when the decoder reports any;
    /// returning false from it aborts the decode.
    func decode(_ samples: [Float], options: DecodingOptions, callback: TranscriptionCallback?) async throws -> [TranscriptionResult]
}

extension WhisperKit: SpeechDecoding {
    public func decode(_ samples: [Float], options: DecodingOptions, callback: TranscriptionCallback?) async throws -> [TranscriptionResult] {
        try await transcribe(audioArray: samples, decodeOptions: options, callback: callback)
    }
}
