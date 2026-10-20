import Foundation

/// One saved transcript in the history. A record is created the first time a transcript gets a line
/// and updated every time more lines are committed, so it always mirrors what was on screen.
struct TranscriptRecord: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var lines: [TranscriptLine]

    init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date? = nil, lines: [TranscriptLine]) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lines = lines
    }

    /// Opening words of the transcript, used as the title in the history list.
    var preview: String {
        lines.first?.text ?? ""
    }
}
