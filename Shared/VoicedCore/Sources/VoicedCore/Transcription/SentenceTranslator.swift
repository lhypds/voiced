import Combine
import Foundation
import Translation

/// Translates sentences between pairs of languages on the device.
@MainActor
public protocol SentenceTranslating: AnyObject {
    /// Sets the language pairs later `translate` calls work with; an empty list stops translation.
    func setPairs(_ pairs: [LanguagePair])
    /// `text` translated as `pair` says. Throws when the system cannot translate it, or when the
    /// pair is dropped while the call waits.
    func translate(_ text: String, pair: LanguagePair) async throws -> TranslatedText
}

/// Apple's on-device translation, available from macOS 15 and iOS 18.
///
/// The framework hands out a `TranslationSession` only through SwiftUI's `translationTask`, and
/// only for as long as that task runs, so `TranslationHost` attaches one task per pair to the
/// main window and `serve` keeps each running. `translate` waits for a pair's session when none
/// is serving yet, as right after the pairs change.
@available(macOS 15, iOS 18, *)
@MainActor
public final class AppleTranslator: ObservableObject, SentenceTranslating {
    public init() {}
    /// The pairs the host view runs translation tasks for; empty while translation is off.
    @Published public private(set) var pairs: [LanguagePair] = []
    private var sessions: [LanguagePair: TranslationSession] = [:]
    /// Callers of `translate` waiting for a pair's session; resumed with nil when the pair goes.
    private var waiting: [LanguagePair: [CheckedContinuation<TranslationSession?, Never>]] = [:]

    public func setPairs(_ wanted: [LanguagePair]) {
        guard wanted != pairs else { return }
        for dropped in Set(pairs).subtracting(wanted) {
            sessions[dropped] = nil
            resumeWaiting(for: dropped, with: nil)
        }
        pairs = wanted
    }

    public static func configuration(for pair: LanguagePair) -> TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: pair.source.map { Locale.Language(identifier: $0) },
            target: Locale.Language(identifier: pair.target)
        )
    }

    /// Runs as the host view's translation task for `pair` until SwiftUI cancels it, when the
    /// pair is dropped or the window goes away.
    public func serve(_ session: TranslationSession, for pair: LanguagePair) async {
        sessions[pair] = session
        // Downloads the language packs the pair needs, asking the user first. A failure, such as
        // a declined download, surfaces on the first `translate` instead.
        try? await session.prepareTranslation()
        guard !Task.isCancelled, sessions[pair] === session else { return }
        resumeWaiting(for: pair, with: session)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
        if sessions[pair] === session {
            sessions[pair] = nil
        }
    }

    public func translate(_ text: String, pair: LanguagePair) async throws -> TranslatedText {
        guard let session = await session(for: pair) else { throw CancellationError() }
        do {
            let response = try await session.translate(text)
            return TranslatedText.from(
                original: text,
                translated: response.targetText,
                sourceLanguage: response.sourceLanguage.languageCode?.identifier,
                targetLanguage: pair.target
            )
        } catch TranslationError.unsupportedLanguagePairing, TranslationError.nothingToTranslate {
            // Speech identified as the target language itself, or a line with no words in it:
            // there is nothing to show, and asking again would not change that.
            return TranslatedText(language: pair.target, text: "")
        }
    }

    private func session(for pair: LanguagePair) async -> TranslationSession? {
        if let session = sessions[pair] { return session }
        guard pairs.contains(pair) else { return nil }
        return await withCheckedContinuation { waiting[pair, default: []].append($0) }
    }

    private func resumeWaiting(for pair: LanguagePair, with session: TranslationSession?) {
        let waiting = self.waiting.removeValue(forKey: pair) ?? []
        for continuation in waiting {
            continuation.resume(returning: session)
        }
    }
}
