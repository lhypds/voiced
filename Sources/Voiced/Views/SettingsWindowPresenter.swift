import AppKit
import SwiftUI

/// Content size of the settings window: a fixed width, and a height the user drags.
struct SettingsWindowSize {
    let width: CGFloat
    /// Lowest height the user can drag the window to.
    let minHeight: CGFloat
    /// Height of the first opening, before the user has resized the window.
    let defaultHeight: CGFloat
}

/// Shows `content` in its own window, centered over the hosting window, while `isPresented` is true.
///
/// A SwiftUI sheet on macOS hangs from the window's title bar, so a tall sheet over a tall window
/// sits against the top edge. This window is placed with its center on the hosting window's
/// center, or with its top edge on the hosting window's top edge when it is taller. From then on
/// it is an independent window: both it and the hosting window can be focused, dragged and
/// brought to the front, and neither blocks the other. (A modal session would block the hosting
/// window, but SwiftUI stops updating its views inside the nested modal loop, so the close
/// button's change to `isPresented` never arrived.) The window keeps `size.width`; its height is
/// the user's to drag, from `size.minHeight` up, and it reopens at the last height.
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
    let size: SettingsWindowSize
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
                    coordinator.present(content, over: parent, size: size)
                }
                coordinator.window?.level = level
                coordinator.bringToFront(for: focusRequest)
            } else {
                coordinator.dismiss()
            }
        }
    }

    final class Coordinator {
        /// The content height the user last left the window at.
        private static var heightKey: String { "SettingsWindowHeight" }

        private(set) var window: NSWindow?
        private weak var parent: NSWindow?
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

        func present<V: View>(_ content: V, over parent: NSWindow, size: SettingsWindowSize) {
            // The hosting view sits inside a plain container rather than being the window's
            // content: as the content view (or a hosting controller's view) SwiftUI sizes the
            // window itself, and with a full-size content view and flexible height every layout
            // pass grew it by the title bar's height until it filled the screen.
            let hosting = NSHostingView(rootView: content)
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            // The hidden title bar still counts as a safe area and would push the content down.
            hosting.safeAreaRegions = []
            let savedHeight = UserDefaults.standard.double(forKey: Self.heightKey)
            let height = max(size.minHeight, savedHeight > 0 ? savedHeight : size.defaultHeight)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: size.width, height: height),
                styleMask: [.titled, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: height))
            hosting.frame = container.bounds
            container.addSubview(hosting)
            window.contentView = container
            window.contentMinSize = NSSize(width: size.width, height: size.minHeight)
            window.contentMaxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
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

            // Centered on the window, unless this window is taller than it: then its top edge
            // sits on the hosting window's top edge rather than sticking out above it.
            let frame = window.frame
            let top = frame.height > parent.frame.height ? parent.frame.maxY : parent.frame.midY + frame.height / 2
            let origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: top - frame.height)
            window.setFrameOrigin(origin)

            self.window = window
            self.parent = parent
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        func dismiss() {
            guard let window else { return }
            UserDefaults.standard.set(Double(window.contentLayoutRect.height), forKey: Self.heightKey)
            window.orderOut(nil)
            window.contentView = nil
            self.window = nil
            handledFocusRequest = nil
            parent?.makeKeyAndOrderFront(nil)
        }
    }
}
