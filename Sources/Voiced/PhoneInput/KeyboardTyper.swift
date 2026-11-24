import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types text into whichever app has the keyboard focus, as if pasted there by the user.
///
/// The text goes through the clipboard and Command-V rather than as synthesized key strokes: an
/// active Chinese or Japanese input method would catch key strokes and compose them again, while
/// a paste arrives as it is in any app, terminals included. The clipboard's previous contents are
/// put back once the paste has been read, unless something else has replaced them meanwhile.
///
/// Posting events to other apps needs the Accessibility permission.
@MainActor
enum KeyboardTyper {
    /// How long the focused app gets to read the clipboard before it is restored.
    private static let restoreDelay: Duration = .milliseconds(500)
    /// How long a terminal gets to take in a paste before Return follows it.
    private static let returnDelay: Duration = .milliseconds(150)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's prompt to grant the Accessibility permission, when it is missing.
    @discardableResult
    static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The clipboard as it was before the first of a run of pastes, and the change count of the
    /// latest paste. A sentence arriving while the previous one's restore is pending must not save
    /// that sentence as the clipboard to restore.
    private static var original: [[NSPasteboard.PasteboardType: Data]]?
    private static var pastedChangeCount = 0

    static func type(_ text: String, pressReturn: Bool) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        if original == nil || pasteboard.changeCount != pastedChangeCount {
            original = pasteboard.pasteboardItems?.map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
            } ?? []
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount
        pastedChangeCount = changeCount
        post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        Task {
            if pressReturn {
                try? await Task.sleep(for: returnDelay)
                post(key: CGKeyCode(kVK_Return), flags: [])
            }
            try? await Task.sleep(for: restoreDelay)
            // A later paste restores the clipboard itself; a copy made meanwhile is kept.
            guard pastedChangeCount == changeCount else { return }
            defer { original = nil }
            guard pasteboard.changeCount == changeCount, let original else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(original.map { types in
                let item = NSPasteboardItem()
                types.forEach { item.setData($1, forType: $0) }
                return item
            })
        }
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
