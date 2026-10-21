import Foundation
import Translation

/// Translates sentences into one target language on the device.
@MainActor
protocol SentenceTranslating: AnyObject {
    /// Sets the languages later `translate` calls work with, as `AppLanguage.code` codes; a nil
    /// source means the translator identifies it, and a nil target stops translation.
    func setLanguages(source: String?, target: String?)
    /// `text` in the target language. Throws when the system cannot translate it, or when
    /// translation is stopped while the call waits.
    func translate(_ text: String) async throws -> TranslatedText
}

/// Apple's on-device translation, available from macOS 15.
///
/// The framework hands out a `TranslationSession` only through SwiftUI's `translationTask`, and
/// only for as long as that task runs, so `TranslationHost` attaches the task to the main window
/// with this object's `configuration` and `serve` keeps it running. `translate` waits for a
/// session when none is serving yet, as right after the languages change.
@available(macOS 15, *)
@MainActor
final class AppleTranslator: ObservableObject, SentenceTranslating {
    /// What the host view's translation task runs with; nil while translation is off.
    @Published private(set) var configuration: TranslationSession.Configuration?
    private var session: TranslationSession?
    /// Callers of `translate` waiting for a session; resumed with nil when translation stops.
    private var waiting: [CheckedContinuation<TranslationSession?, Never>] = []

    func setLanguages(source: String?, target: String?) {
        guard let target else {
            configuration = nil
            session = nil
            resumeWaiting(with: nil)
            return
        }
        let wanted = TranslationSession.Configuration(
            source: source.map { Locale.Language(identifier: $0) },
            target: Locale.Language(identifier: target)
        )
        // Setting an equal configuration again would still restart the task.
        guard configuration?.source != wanted.source || configuration?.target != wanted.target else { return }
        session = nil
        configuration = wanted
    }

    /// Runs as the host view's translation task until SwiftUI cancels it, on a configuration
    /// change or when the window goes away.
    func serve(_ session: TranslationSession) async {
        self.session = session
        // Downloads the language packs the pair needs, asking the user first. A failure, such as
        // a declined download, surfaces on the first `translate` instead.
        try? await session.prepareTranslation()
        guard !Task.isCancelled, self.session === session else { return }
        resumeWaiting(with: session)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
        if self.session === session {
            self.session = nil
        }
    }

    func translate(_ text: String) async throws -> TranslatedText {
        guard let session = await currentSession(), let target = session.targetLanguage else {
            throw CancellationError()
        }
        let targetCode = target.languageCode?.identifier ?? target.minimalIdentifier
        do {
            let response = try await session.translate(text)
            return TranslatedText.from(
                original: text,
                translated: response.targetText,
                sourceLanguage: response.sourceLanguage.languageCode?.identifier,
                targetLanguage: targetCode
            )
        } catch TranslationError.unsupportedLanguagePairing, TranslationError.nothingToTranslate {
            // Speech identified as the target language itself, or a line with no words in it:
            // there is nothing to show, and asking again would not change that.
            return TranslatedText(language: targetCode, text: "")
        }
    }

    private func currentSession() async -> TranslationSession? {
        if let session { return session }
        guard configuration != nil else { return nil }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func resumeWaiting(with session: TranslationSession?) {
        let waiting = self.waiting
        self.waiting = []
        for continuation in waiting {
            continuation.resume(returning: session)
        }
    }
}
