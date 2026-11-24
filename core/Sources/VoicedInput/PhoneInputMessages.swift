import Foundation

/// The wire format the iPhone app speaks, as defined by `PhoneInput` in
/// core/VoicedCore/Sources/VoicedCore/PhoneInput/PhoneInput.swift: the Mac advertises
/// `serviceType` over Bonjour and every sentence arrives as one JSON object on a line of its own.
/// Kept as a copy so the service does not build WhisperKit; keep the two in step.
enum PhoneInputMessages {
    static let serviceType = "_voiced-input._tcp"

    /// What to do with a sentence, chosen on the phone.
    enum Mode: String, Codable, Sendable {
        /// Typed at the cursor and left there.
        case type
        /// Typed at the cursor and followed by Return.
        case typeAndReturn
        /// Carried out by Claude Code in a Terminal window.
        case claude
    }

    struct Message: Codable, Equatable, Sendable {
        var text: String
        /// Missing from phones older than the modes, and unknown for modes added later: both
        /// are typed at the cursor.
        var mode: Mode
        /// The folder Claude Code runs in, for `claude`, set on the phone; `~` stands for the
        /// home folder. Missing or empty: the home folder.
        var folder: String?

        init(text: String, mode: Mode = .type, folder: String? = nil) {
            self.text = text
            self.mode = mode
            self.folder = folder
        }

        init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)) ?? .type
            folder = try? container.decodeIfPresent(String.self, forKey: .folder)
        }

        /// `folder` as a path on this Mac: `~` expanded, the home folder when none was sent.
        var resolvedFolder: String {
            let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if trimmed.isEmpty || trimmed == "~" { return home }
            // Standardized so `~/` and `~` are the same folder and continue one conversation.
            if trimmed.hasPrefix("~/") { return ((home + trimmed.dropFirst(1)) as NSString).standardizingPath }
            return (trimmed as NSString).standardizingPath
        }
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
