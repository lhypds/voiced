import Foundation

enum TimestampMode: String, CaseIterable, Identifiable, Sendable {
    case relative
    case current

    var id: String { rawValue }
}

/// One displayed sentence of the transcript.
struct TranscriptLine: Identifiable, Equatable, Codable, Sendable {
    let id: String
    /// Seconds from the start of the recording session.
    let start: Float
    let end: Float
    /// Wall-clock time at which this line started.
    let recordedAt: Date
    let text: String

    func timestamp(mode: TimestampMode, showDate: Bool) -> String {
        switch mode {
        case .relative: Self.relativeTimestamp(seconds: start)
        case .current: Self.clockTimestamp(for: recordedAt, showDate: showDate)
        }
    }

    func replacingText(_ newText: String) -> TranscriptLine {
        TranscriptLine(id: id, start: start, end: end, recordedAt: recordedAt, text: newText)
    }

    /// Joins `next` onto this line, keeping this line's start and taking `next`'s end.
    func merged(with next: TranscriptLine, separator: String) -> TranscriptLine {
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
