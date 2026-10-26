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
        scrolled.largeTitleTextAttributes = [.foregroundColor: UIColor(MobileTheme.accent)]
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
