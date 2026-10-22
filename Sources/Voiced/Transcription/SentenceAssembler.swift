import Foundation

/// Turns raw recognition segments into sentence-sized transcript lines.
///
/// Pure value type with no WhisperKit dependency so the merging rules can be unit tested.
struct SentenceAssembler: Sendable {
    /// A silence of at least this many seconds between segments ends the current sentence
    /// even when it has no terminal punctuation.
    static let sentenceGap: Float = 0.6
    /// A sentence that has grown this long without terminal punctuation is closed at the next
    /// segment boundary, so continuous speech still gets committed line by line and the pending
    /// audio stays bounded. Whisper rarely closes Chinese or Japanese sentences with 。, so for
    /// steady sources such as news this is the usual line length: around eight seconds is a clause
    /// or two, which reads well and keeps each decode short.
    static let maxSentenceSeconds: Float = 8
    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]
    private static let cjkClausePunctuation: Set<Character> = ["、", "，", "。", "！", "？", "．", "：", "；"]
    private static let asciiClausePunctuation: Set<Character> = [",", ".", "!", "?", ":", ";"]

    /// Whisper language code the speech is in, or nil for automatic detection.
    let languageCode: String?

    init(languageCode: String?) {
        self.languageCode = languageCode
    }

    /// Script the punctuation of `text` should follow. Decided from the text itself so English in a
    /// Chinese session still gets ASCII marks; the language code only settles kanji-only text.
    func script(of text: String) -> PunctuationNormalizer.Script {
        PunctuationNormalizer.script(of: text, languageCode: languageCode)
    }

    /// Rewrites the punctuation of `text` to match its script: full width for Chinese (，。) and
    /// Japanese (、。), half width for everything else.
    func normalized(_ text: String) -> String {
        PunctuationNormalizer.normalize(text, languageCode: languageCode)
    }

    /// Merges consecutive segments until one ends with terminal punctuation or a long pause follows.
    ///
    /// - Parameter includeTrailing: when false, the sentence at the end of the audio is dropped, even
    ///   if it is punctuated, because the next decode of the same audio may still extend or revise it.
    ///   Only sentences that are followed by more speech are returned.
    func sentences(from segments: [TranscriptLine], includeTrailing: Bool = true) -> [TranscriptLine] {
        var sentences: [TranscriptLine] = []
        var pending: TranscriptLine?

        for raw in segments {
            let segment = raw.replacingText(normalized(raw.text))
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
            .map { normalized($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        return cleaned.joined(separator: joiningSeparator(after: cleaned.first ?? ""))
    }

    /// Appends a sentence terminator unless the line already ends with punctuation. A line cut at a
    /// pause often ends with Whisper's clause comma (各県の知事に対し、); that comma stays, since
    /// the sentence does go on, rather than gaining a 。 after it.
    func terminated(_ line: TranscriptLine) -> TranscriptLine {
        guard let last = line.text.last,
              !Self.cjkClausePunctuation.contains(last), !Self.asciiClausePunctuation.contains(last)
        else { return line }
        return line.replacingText(line.text + terminator(for: line.text))
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
        switch script(of: text) {
        case .chinese: return "，"
        case .japanese: return "、"
        case .latin: return " "
        }
    }

    private func terminator(for text: String) -> String {
        script(of: text) == .latin ? "." : "。"
    }
}
