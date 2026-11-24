import SwiftUI
import VoicedCore

@main
struct VoicedIOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
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

/// Keeps the app in portrait when "Allow landscape" is off in Settings. UIKit asks the app
/// delegate which orientations the windows may take, so this is installed as the delegate.
final class OrientationLock: NSObject, UIApplicationDelegate {
    /// Every orientation the Info.plist lists while landscape is allowed.
    private static var allowed: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
    }

    /// Applies the setting and turns a window that is in landscape back to portrait at once.
    @MainActor
    static func apply(allowLandscape: Bool) {
        allowed = allowLandscape ? .all : .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if !allowLandscape {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
