import AppKit
import SwiftUI

/// Shows `content` in a panel centered over the hosting window while `isPresented` is true.
///
/// A SwiftUI sheet on macOS hangs from the window's title bar, so a tall sheet over a tall window
/// sits against the top edge. This panel is placed with its center on the window's center, or
/// with its top edge on the window's top edge when it is taller than the window, and follows
/// the window as a child window. Like a sheet it blocks the window underneath, which
/// ignores the mouse while the panel is up. (A modal session would block it too, but SwiftUI
/// stops updating the window's views inside the nested modal loop, so the close button's change
/// to `isPresented` never arrived.) When its content grows, the panel keeps its top edge and
/// extends downwards, the way a sheet does.
struct SettingsWindowPresenter<Content: View>: NSViewRepresentable {
    /// A plain value, not a binding: the presenting view reads it in its body, so a change
    /// re-evaluates that body and reaches `updateNSView`. A binding alone would not be read
    /// until `updateNSView`, which SwiftUI would then never call again.
    let isPresented: Bool
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
        // Window changes are kept out of the view update that triggered them.
        DispatchQueue.main.async {
            if isPresented {
                if coordinator.panel == nil, let parent = view.window {
                    coordinator.present(content, over: parent)
                }
            } else {
                coordinator.dismiss()
            }
        }
    }

    final class Coordinator {
        private(set) var panel: NSPanel?
        private weak var parent: NSWindow?
        private var resizeObserver: NSObjectProtocol?

        func present<V: View>(_ content: V, over parent: NSWindow) {
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = .preferredContentSize
            // The hidden title bar still counts as a safe area and would push the content down.
            hosting.safeAreaRegions = []
            let panel = NSPanel(contentViewController: hosting)
            panel.styleMask = [.titled, .fullSizeContentView]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = NSColor(Theme.background)
            panel.isReleasedWhenClosed = false
            panel.level = parent.level
            panel.hidesOnDeactivate = false

            let size = hosting.view.fittingSize
            panel.setContentSize(size)
            // Centered on the window, unless the panel is taller than the window: then its top
            // edge sits on the window's top edge rather than sticking out above it.
            let frame = panel.frame
            let top = frame.height > parent.frame.height ? parent.frame.maxY : parent.frame.midY + frame.height / 2
            let origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: top - frame.height)
            panel.setFrameOrigin(origin)

            // Content changes resize the window around its bottom-left corner; pin the top instead.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak panel] _ in
                guard let panel else { return }
                let wanted = NSPoint(x: parent.frame.midX - panel.frame.width / 2, y: top - panel.frame.height)
                if abs(panel.frame.origin.y - wanted.y) > 0.5 || abs(panel.frame.origin.x - wanted.x) > 0.5 {
                    panel.setFrameOrigin(wanted)
                }
            }

            self.panel = panel
            self.parent = parent
            parent.ignoresMouseEvents = true
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
        }

        func dismiss() {
            guard let panel else { return }
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
            self.panel = nil
            parent?.ignoresMouseEvents = false
            parent?.makeKeyAndOrderFront(nil)
        }
    }
}
