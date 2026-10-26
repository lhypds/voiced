import SwiftUI

/// Searching the saved transcripts, shared by the history on macOS and iOS. A line matches when
/// its text or its translation contains the query, ignoring case, as the search in the main
/// window does.
public struct HistorySearchResult: Identifiable, Equatable, Sendable {
    public let record: TranscriptRecord
    /// The first line that matches, newest record first and earliest line first within it.
    public let firstMatch: TranscriptLine
    /// The text of `firstMatch` that contains the query: the line itself, or its translation.
    public let matchedText: String
    /// How many lines of the record match.
    public let matchCount: Int

    public var id: String { record.id }
}

public enum HistorySearch {
    /// The query with surrounding spaces removed, or nil when nothing is left to search for.
    public static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The records with at least one matching line, in the order given.
    public static func results(in records: [TranscriptRecord], for query: String) -> [HistorySearchResult] {
        guard let query = normalized(query) else { return [] }
        return records.compactMap { record in
            var first: (line: TranscriptLine, text: String)?
            var count = 0
            for line in record.lines {
                guard let text = matchedText(of: line, query: query) else { continue }
                count += 1
                if first == nil { first = (line, text) }
            }
            guard let first else { return nil }
            return HistorySearchResult(record: record, firstMatch: first.line, matchedText: first.text, matchCount: count)
        }
    }

    /// The line's text when it contains the query, else its translation when that does.
    static func matchedText(of line: TranscriptLine, query: String) -> String? {
        if line.text.localizedCaseInsensitiveContains(query) { return line.text }
        if let translation = line.translation?.text, translation.localizedCaseInsensitiveContains(query) {
            return translation
        }
        return nil
    }

    /// `text` with every occurrence of the query drawn bold in `color`, for showing why a
    /// record matched.
    public static func highlighted(_ text: String, query: String, color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        guard let query = normalized(query) else { return attributed }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive], range: searchStart..<text.endIndex, locale: .current) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = color
                // Bold within the font the row already uses, whatever its size.
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = range.upperBound
        }
        return attributed
    }
}
