import SwiftUI
import VoicedCore

@main
struct VoicedIOSApp: App {
    @StateObject private var model: MobileTranscriber
    init() {
        #if DEBUG
        _model = StateObject(wrappedValue: UITestFixtures.makeModelIfRequested() ?? MobileTranscriber())
        #else
        _model = StateObject(wrappedValue: MobileTranscriber())
        #endif
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundColor = UIColor(MobileTheme.background)
        // Large titles (Settings, History) in the wordmark's face and colour: Gill Sans Bold at the
        // wordmark's 34 pt, following the reader's text size as the wordmark does.
        let titleFont = UIFont(name: "GillSans-Bold", size: 34).map { UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: $0) }
            ?? UIFont.preferredFont(forTextStyle: .largeTitle)
        scrolled.largeTitleTextAttributes = [.foregroundColor: UIColor(MobileTheme.accent), .font: titleFont]
        scrolled.titleTextAttributes = [.foregroundColor: UIColor(MobileTheme.ink)]
        // At the scroll edge the bar must stay transparent: on iOS 26 an opaque bar background is
        // painted over the large title area, so a themed background there hides the title entirely.
        // The screen behind it is MobileTheme.background anyway, so nothing visible is lost.
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = scrolled.largeTitleTextAttributes
        edge.titleTextAttributes = scrolled.titleTextAttributes
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model).buttonStyle(RaisedButtonStyle()) }
    }
}
