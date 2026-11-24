import Foundation

/// The wire format the iPhone app speaks, as defined by `PhoneInput` in
/// Shared/VoicedCore/Sources/VoicedCore/PhoneInput/PhoneInput.swift: the Mac advertises
/// `serviceType` over Bonjour and every sentence arrives as one JSON object on a line of its own.
/// Kept as a copy so the service does not build WhisperKit; keep the two in step.
enum PhoneInputMessages {
    static let serviceType = "_voiced-input._tcp"

    struct Message: Codable, Equatable, Sendable {
        var text: String
    }

    /// Collects received bytes and hands back the messages completed by them. A message split
    /// across reads waits in the buffer for its end; a line that is not a message is dropped.
    struct Decoder: Sendable {
        private var buffer = Data()

        mutating func feed(_ data: Data) -> [Message] {
            buffer.append(data)
            var messages: [Message] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                if let message = try? JSONDecoder().decode(Message.self, from: line) {
                    messages.append(message)
                }
            }
            return messages
        }
    }

    /// What is typed for a received sentence. Sentences typed one after another must not run
    /// together: one ending in a Latin letter or ASCII punctuation is followed by a space, while
    /// Chinese and Japanese, written without spaces, are typed as they are. Nothing is added
    /// when Return follows, which ends the line anyway.
    static func typedText(for text: String, pressesReturn: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pressesReturn, let last = trimmed.unicodeScalars.last, last.isASCII else { return trimmed }
        return trimmed + " "
    }
}
