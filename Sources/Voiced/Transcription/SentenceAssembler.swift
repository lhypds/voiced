import Foundation

/// Turns raw recognition segments into sentence-sized transcript lines.
///
/// Pure value type with no WhisperKit dependency so the merging rules can be unit tested.
struct SentenceAssembler: Sendable {
    /// A silence of at least this many seconds between segments ends the current sentence
    /// even when it has no terminal punctuation.
    static let sentenceGap: Float = 0.6
    /// A sentence that has grown this long without punctuation is closed when the next segment
    /// arrives, so continuous speech still gets committed and the pending audio stays bounded.
    static let maxSentenceSeconds: Float = 15
    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]
    private static let cjkClausePunctuation: Set<Character> = ["、", "，", "。", "！", "？", "．", "：", "；"]
    private static let asciiClausePunctuation: Set<Character> = [",", ".", "!", "?", ":", ";"]

    /// Whisper language code the speech is in, or nil for automatic detection.
    let languageCode: String?

    init(languageCode: String?) {
        self.languageCode = languageCode
    }

    /// Whether to join and terminate with full-width (Chinese/Japanese) punctuation.
    var usesCJKPunctuation: Bool {
        languageCode == "zh" || languageCode == "ja"
    }

    /// Merges consecutive segments until one ends with terminal punctuation or a long pause follows.
    ///
    /// - Parameter includeTrailing: when false, the sentence at the end of the audio is dropped, even
    ///   if it is punctuated, because the next decode of the same audio may still extend or revise it.
    ///   Only sentences that are followed by more speech are returned.
    func sentences(from segments: [TranscriptLine], includeTrailing: Bool = true) -> [TranscriptLine] {
        var sentences: [TranscriptLine] = []
        var pending: TranscriptLine?

        for segment in segments {
            if let current = pending {
                let pauseBefore = segment.start - current.end >= Self.sentenceGap
                let tooLong = segment.end - current.start > Self.maxSentenceSeconds
                if !endsSentence(current.text), pauseBefore || tooLong {
                    sentences.append(terminated(current))
                    pending = segment
                } else {
                    pending = current.merged(with: segment, separator: joiningSeparator(after: current.text))
                }
            } else {
                pending = segment
            }

            if let current = pending, endsSentence(current.text) {
                sentences.append(current)
                pending = nil
            }
        }

        if let pending {
            if includeTrailing {
                sentences.append(pending)
            }
        } else if !includeTrailing, !sentences.isEmpty {
            // The last segment closed a sentence exactly at the end of the audio.
            sentences.removeLast()
        }
        return sentences
    }

    /// Builds the live preview text from the recognizer's not-yet-confirmed fragments.
    func draft(from parts: [String]) -> String {
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.joined(separator: joiningSeparator(after: cleaned.first ?? ""))
    }

    /// Appends a sentence terminator unless the line already ends with one.
    func terminated(_ line: TranscriptLine) -> TranscriptLine {
        endsSentence(line.text) ? line : line.replacingText(line.text + terminator)
    }

    func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return Self.sentenceTerminators.contains(last)
    }

    /// Separator to insert after `text` when appending more speech.
    /// Latin words get a space; CJK text gets a clause comma unless it already ends with punctuation.
    func joiningSeparator(after text: String) -> String {
        guard let last = text.last else { return "" }
        if Self.cjkClausePunctuation.contains(last) {
            return ""
        }
        if Self.asciiClausePunctuation.contains(last) || (last.isASCII && (last.isLetter || last.isNumber)) {
            return " "
        }
        return usesCJKPunctuation ? clauseComma : " "
    }

    private var terminator: String {
        usesCJKPunctuation ? "。" : "."
    }

    private var clauseComma: String {
        languageCode == "ja" ? "、" : "，"
    }
}
