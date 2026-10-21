import AVFoundation

/// A system voice the user can pick to read translations.
struct SpeechVoice: Identifiable, Equatable, Sendable {
    /// `AVSpeechSynthesisVoice.identifier`, which stays the same across launches.
    let id: String
    let name: String
    /// BCP 47 tag of the voice's language and region, such as `zh-TW`.
    let language: String
    /// Whether it is an enhanced or premium voice, downloaded in System Settings.
    let isHighQuality: Bool
}

/// Reads translations aloud with the system's speech voices, one after another in the order
/// they are handed in.
@MainActor
final class TranslationSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    /// Queues `text` to be spoken in the language with ISO 639-1 code `language`, by the voice
    /// `voiceID` names, or by the default voice for the language when that is nil or no longer
    /// installed.
    func speak(_ text: String, language: String, voiceID: String?) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.defaultVoice(for: language)
        synthesizer.speak(utterance)
    }

    /// Drops what is being spoken and everything queued after it.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The installed voices that speak `language`, by region and then name. Novelty voices such
    /// as Bells or Bubbles are left out.
    static func voices(for language: String) -> [SpeechVoice] {
        installedVoices(for: language)
            .map { voice in
                SpeechVoice(id: voice.identifier, name: voice.name, language: voice.language, isHighQuality: voice.quality != .default)
            }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    /// The voice for `language` when none is picked: the system's own voice when it speaks that
    /// language, so the user's region and choice in System Settings carry over, or else the best
    /// installed one.
    static func defaultVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let systemLanguage = AVSpeechSynthesisVoice.currentLanguageCode()
        if code(of: systemLanguage) == language, let voice = AVSpeechSynthesisVoice(language: systemLanguage) {
            return voice
        }
        return installedVoices(for: language).max { $0.quality.rawValue < $1.quality.rawValue }
    }

    private static func installedVoices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            code(of: voice.language) == language && !voice.voiceTraits.contains(.isNoveltyVoice)
        }
    }

    /// The language part of a BCP 47 tag such as `zh-CN`.
    private static func code(of tag: String) -> String {
        tag.split(separator: "-").first.map { $0.lowercased() } ?? tag
    }
}
