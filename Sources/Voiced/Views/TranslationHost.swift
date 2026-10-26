import VoicedCore
import SwiftUI
import Translation

/// Runs the controller's translator as translation tasks on the view it is attached to. The
/// Translation framework issues sessions only to a view, and shows its language download prompt
/// in that view's window, so this sits on the main window's content. Nothing on macOS 14.
struct TranslationHost: ViewModifier {
    let translator: (any SentenceTranslating)?

    func body(content: Content) -> some View {
        if #available(macOS 15, *), let translator = translator as? AppleTranslator {
            content.modifier(TranslationTaskHost(translator: translator))
        } else {
            content
        }
    }
}

@available(macOS 15, *)
private struct TranslationTaskHost: ViewModifier {
    @ObservedObject var translator: AppleTranslator

    /// One task per pair, each on its own invisible view: a view runs a single translation task,
    /// and keyed by the pair, a task stays put while other pairs come and go.
    func body(content: Content) -> some View {
        content.background {
            ForEach(translator.pairs, id: \.self) { pair in
                Color.clear.translationTask(AppleTranslator.configuration(for: pair)) { session in
                    await translator.serve(session, for: pair)
                }
            }
        }
    }
}
