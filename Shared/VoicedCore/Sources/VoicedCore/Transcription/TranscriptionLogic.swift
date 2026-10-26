import Foundation
import WhisperKit

/// Recognition policy shared by desktop, mobile, and the file-input tool.
public enum TranscriptionLogic {
    public static func decodingOptions(for language: RecognitionLanguage, promptTokens: [Int]? = nil) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language.code,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: language.isAutomatic,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            // Timings let the shared pipeline split long Whisper segments at punctuation.
            wordTimestamps: true,
            promptTokens: promptTokens,
            logProbThreshold: -0.8,
            noSpeechThreshold: 0.4
        )
    }

    public static func transcriptLines(from segments: [TranscriptionSegment], recordingStartedAt: Date) -> [TranscriptLine] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(id: "\(segment.id)-\(segment.start)-\(segment.end)", start: segment.start,
                                  end: segment.end, recordedAt: recordingStartedAt.addingTimeInterval(TimeInterval(segment.start)), text: text)
        }
    }

    public static func export(
        _ lines: [TranscriptLine],
        mode: TimestampMode = .relative,
        showDate: Bool = false,
        displayTexts: (TranscriptLine) -> (primary: String, secondary: String?) = { ($0.text, nil) }
    ) -> String {
        lines.map { line in
            let texts = displayTexts(line)
            let entry = "[\(line.timestamp(mode: mode, showDate: showDate))] \(texts.primary)"
            return texts.secondary.map { entry + "\n" + $0 } ?? entry
        }.joined(separator: "\n")
    }
}

public extension RecordingSession {
    /// Both platforms commit the same sentences and keep the same unfinished trailing text.
    @discardableResult
    mutating func update(segments: [TranscriptionSegment], assembler: SentenceAssembler) -> Bool {
        let lines = TranscriptionLogic.transcriptLines(from: segments, recordingStartedAt: startedAt)
        return update(latest: assembler.sentences(from: lines), completed: assembler.sentences(from: lines, includeTrailing: false))
    }
}
