import AppKit
import SwiftUI

/// Shows `content` in its own window, centered over the hosting window, while `isPresented` is true.
///
/// A SwiftUI sheet on macOS hangs from the window's title bar, so a tall sheet over a tall window
/// sits against the top edge. This window is placed with its center on the hosting window's
/// center, or with its top edge on the hosting window's top edge when it is taller. From then on
/// it is an independent window: both it and the hosting window can be focused, dragged and
/// brought to the front, and neither blocks the other. (A modal session would block the hosting
/// window, but SwiftUI stops updating its views inside the nested modal loop, so the close
/// button's change to `isPresented` never arrived.) When its content grows, the window keeps
/// its top edge and extends downwards, the way a sheet does.
struct SettingsWindowPresenter<Content: View>: NSViewRepresentable {
    /// A plain value, not a binding: the presenting view reads it in its body, so a change
    /// re-evaluates that body and reaches `updateNSView`. A binding alone would not be read
    /// until `updateNSView`, which SwiftUI would then never call again.
    let isPresented: Bool
    /// Bumped by the presenting view each time the user asks for settings. A new value brings
    /// the window to the front even when it is already open behind the hosting window.
    let focusRequest: Int
    /// Mirrors the hosting window's level so the settings window never drops behind it when
    /// "keep on top" is toggled while settings are open.
    let isFloating: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let content = content()
        let level: NSWindow.Level = isFloating ? .floating : .normal
        // Window changes are kept out of the view update that triggered them.
        DispatchQueue.main.async {
            if isPresented {
                if coordinator.window == nil, let parent = view.window {
                    coordinator.present(content, over: parent)
                }
                coordinator.window?.level = level
                coordinator.bringToFront(for: focusRequest)
            } else {
                coordinator.dismiss()
            }
        }
    }

    final class Coordinator {
        private(set) var window: NSWindow?
        private weak var parent: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var handledFocusRequest: Int?

        /// Puts the window in front of the hosting window and of every other app's windows,
        /// once per distinct `request`.
        func bringToFront(for request: Int) {
            guard let window, handledFocusRequest != request else { return }
            handledFocusRequest = request
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        func present<V: View>(_ content: V, over parent: NSWindow) {
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = .preferredContentSize
            // The hidden title bar still counts as a safe area and would push the content down.
            hosting.safeAreaRegions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            // The content draws its own title bar, so the whole background is the drag handle.
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.background)
            window.isReleasedWhenClosed = false
            window.level = parent.level
            window.hidesOnDeactivate = false

            let size = hosting.view.fittingSize
            window.setContentSize(size)
            // Centered on the window, unless this window is taller than it: then its top edge
            // sits on the hosting window's top edge rather than sticking out above it.
            let frame = window.frame
            let top = frame.height > parent.frame.height ? parent.frame.maxY : parent.frame.midY + frame.height / 2
            let origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: top - frame.height)
            window.setFrameOrigin(origin)

            // Content changes resize the window around its bottom-left corner; pin the top
            // instead. The pinned top follows the window wherever the user drags it.
            var pinnedTop = top
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                pinnedTop = window.frame.maxY
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                let wanted = NSPoint(x: window.frame.origin.x, y: pinnedTop - window.frame.height)
                if abs(window.frame.origin.y - wanted.y) > 0.5 {
                    window.setFrameOrigin(wanted)
                }
            })

            self.window = window
            self.parent = parent
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        func dismiss() {
            guard let window else { return }
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            window.orderOut(nil)
            window.contentViewController = nil
            self.window = nil
            handledFocusRequest = nil
            parent?.makeKeyAndOrderFront(nil)
        }
    }
}
