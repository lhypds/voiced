import AppKit
import Foundation

/// Where the sentences from the iPhone go.
enum Target: String, CaseIterable, Identifiable {
    /// Typed at the cursor of whichever app has the focus.
    case cursor
    /// Sent to Claude Code running in a Terminal window.
    case claude
    /// Sent to Codex running in a Terminal window.
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The command that starts the agent; nil for the cursor.
    var command: String? {
        switch self {
        case .cursor: nil
        case .claude: "claude"
        case .codex: "codex"
        }
    }
}

/// Sends sentences to Claude Code or Codex in a Terminal window that this service opens.
///
/// The first sentence opens a window, changes to the work folder and starts the agent with the
/// sentence as its first prompt, so nothing has to wait for the agent to come up. Each later
/// sentence brings that window to the front and is pasted there followed by Return. A new window
/// is opened when the old one was closed, its agent has exited, or the target or folder changed.
@MainActor
enum AgentTerminal {
    private struct Session {
        let windowID: Int
        let target: Target
        let folder: String
    }

    private static var session: Session?
    /// How long Terminal gets to bring the window to the front before the paste.
    private static let focusDelay: Duration = .milliseconds(300)

    /// Sends `text` to the agent for `target`, which must not be `.cursor`. Returns an error
    /// message when it could not be sent.
    static func send(_ text: String, to target: Target, in folder: String) -> String? {
        guard let command = target.command else { return nil }

        if let session, session.target == target, session.folder == folder, isRunning(session.windowID) {
            guard KeyboardTyper.isTrusted else { return "No Accessibility permission to type in Terminal" }
            if let error = run("""
                tell application "Terminal"
                    set index of window id \(session.windowID) to 1
                    activate
                end tell
                """).error {
                return error
            }
            Task {
                try? await Task.sleep(for: focusDelay)
                KeyboardTyper.type(text, pressReturn: true)
            }
            return nil
        }

        let shellCommand = "cd \(shellQuoted(folder)) && \(command) \(shellQuoted(text))"
        let result = run("""
            tell application "Terminal"
                activate
                do script \(appleScriptQuoted(shellCommand))
                return id of front window
            end tell
            """)
        if let error = result.error { return error }
        guard let windowID = result.value?.int32Value, windowID != 0 else { return "Terminal did not open a window" }
        session = Session(windowID: Int(windowID), target: target, folder: folder)
        log("Started \(target.title) in \(folder) (Terminal window \(windowID))")
        return nil
    }

    /// Whether the window still exists and runs something besides its shell, the agent.
    private static func isRunning(_ windowID: Int) -> Bool {
        let result = run("""
            tell application "Terminal"
                if not (exists window id \(windowID)) then return false
                return busy of selected tab of window id \(windowID)
            end tell
            """)
        return result.value?.booleanValue ?? false
    }

    private static func run(_ source: String) -> (value: NSAppleEventDescriptor?, error: String?) {
        guard let script = NSAppleScript(source: source) else { return (nil, "Invalid AppleScript") }
        var errorInfo: NSDictionary?
        let value = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            log("Terminal: \(message)")
            return (nil, "Terminal: \(message)")
        }
        return (value, nil)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
