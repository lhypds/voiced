import Foundation

public enum TimestampMode: String, CaseIterable, Identifiable, Sendable {
    case relative
    case current

    public var id: String { rawValue }
}

/// Which of a translated line's two texts is the main one, shown at full size; the other is
/// shown under it in small grey type.
public enum TranslationEmphasis: String, CaseIterable, Identifiable, Sendable {
    case original
    case translation

    public var id: String { rawValue }
}

/// What a click on a transcript row does.
public enum LineClickAction: String, CaseIterable, Identifiable, Sendable {
    /// Copies the row's text to the clipboard.
    case copy
    /// Plays the record's audio from the moment the row was spoken; a second click stops it.
    case play

    public var id: String { rawValue }
}

/// A line's translation into one language. Empty `text` records that the line was already in
/// that language, so nothing is shown and the line is not translated again.
public struct TranslatedText: Equatable, Codable, Sendable {
    public init(language: String, text: String) {
        self.language = language
        self.text = text
    }
    /// Code of the language the text is in, as in `AppLanguage.code`.
    public let language: String
    public let text: String

    /// The text to show, or nil when the line needed no translation.
    public var displayText: String? { text.isEmpty ? nil : text }

    /// The translation to keep from a translator's answer for `original`: empty when the answer
    /// is in the original's own language or came back unchanged, so the sentence is shown once.
    public static func from(original: String, translated: String, sourceLanguage: String?, targetLanguage: String) -> TranslatedText {
        let translated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = translated == original.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceLanguage == targetLanguage || unchanged {
            return TranslatedText(language: targetLanguage, text: "")
        }
        return TranslatedText(language: targetLanguage, text: translated)
    }
}

/// One displayed sentence of the transcript.
public struct TranscriptLine: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    /// Seconds from the start of the recording session.
    public let start: Float
    public let end: Float
    /// Wall-clock time at which this line started.
    public let recordedAt: Date
    public let text: String
    /// The sentence in another language, once translated. Missing from files written before
    /// translation existed.
    public let translation: TranslatedText?

    public init(id: String, start: Float, end: Float, recordedAt: Date, text: String, translation: TranslatedText? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.recordedAt = recordedAt
        self.text = text
        self.translation = translation
    }

    public func timestamp(mode: TimestampMode, showDate: Bool) -> String {
        switch mode {
        case .relative: Self.relativeTimestamp(seconds: start)
        case .current: Self.clockTimestamp(for: recordedAt, showDate: showDate)
        }
    }

    /// The line with new text. Any translation belonged to the old text and is dropped.
    public func replacingText(_ newText: String) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: recordedAt, text: newText)
    }

    /// The same line under another id.
    public func replacingID(_ newID: String) -> TranscriptLine {
        TranscriptLine(id: newID, start: start, end: end, recordedAt: recordedAt, text: text, translation: translation)
    }

    public func translated(_ translation: TranslatedText) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: recordedAt, text: text, translation: translation)
    }

    /// Whether the line still has to be translated into `language`.
    public func needsTranslation(into language: String) -> Bool {
        translation?.language != language
    }

    /// Joins `next` onto this line, keeping this line's start and taking `next`'s end.
    public func merged(with next: TranscriptLine, separator: String) -> TranscriptLine {
        TranscriptLine(
            id: "\(id)|\(next.id)",
            start: start,
            end: next.end,
            recordedAt: recordedAt,
            text: text + separator + next.text
        )
    }

    private static func relativeTimestamp(seconds: Float) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3_600 {
            return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func clockTimestamp(for date: Date, showDate: Bool) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        guard showDate else { return time }
        return String(format: "%04d-%02d-%02d ", c.year ?? 0, c.month ?? 0, c.day ?? 0) + time
    }
}

extension Array where Element == TranscriptLine {
    /// These lines with every repeated id given a `#2`-style suffix, so each row has its own
    /// identity on screen. Files written before ids were kept unique can repeat one.
    public func withUniqueIDs() -> [TranscriptLine] {
        var taken: Set<String> = []
        return map { line in
            var id = line.id
            var attempt = 2
            while !taken.insert(id).inserted {
                id = "\(line.id)#\(attempt)"
                attempt += 1
            }
            return id == line.id ? line : line.replacingID(id)
        }
    }

    /// These lines, carrying over the translations of `previous` lines with the same id and text.
    /// The recording session rebuilds the transcript without translations on every commit; the
    /// translations live in the lines the controller shows.
    public func keepingTranslations(from previous: [TranscriptLine]) -> [TranscriptLine] {
        let translated = Dictionary(previous.compactMap { line in line.translation.map { (line.id, (line.text, $0)) } }, uniquingKeysWith: { first, _ in first })
        return map { line in
            guard line.translation == nil, let (text, translation) = translated[line.id], text == line.text else { return line }
            return line.translated(translation)
        }
    }
}
