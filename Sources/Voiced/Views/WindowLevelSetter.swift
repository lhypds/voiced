import AppKit
import SwiftUI

/// Pins the hosting window above other apps' windows, or releases it, following `isFloating`.
///
/// Sits in the view hierarchy as an invisible background: the window is only reachable through
/// a view that has been added to it, which is why this is not done from the `App` scene.
struct WindowLevelSetter: NSViewRepresentable {
    let isFloating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The view has no window yet on the first update; it is attached by the next run loop turn.
        DispatchQueue.main.async {
            view.window?.level = isFloating ? .floating : .normal
        }
    }
}
