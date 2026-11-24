import AppKit
import Foundation

/// Sends sentences the iPhone marks to be carried out to Claude Code, run in a Terminal window that
/// this service opens.
///
/// Claude Code runs non-interactively (`claude -p`), as the Agent SDK does in ~/code/tm: it carries
/// the sentence out, prints its answer and exits. That way it never stops at the question whether
/// to trust the work folder, which an interactive `claude` asks in every folder it has not seen.
/// The first sentence opens a window in the work folder and starts a conversation; each later one
/// continues it (`--continue`) in the same window, after the run before it has finished. A new
/// window, and a new conversation, are started when the old window was closed or the folder changed.
///
/// A run without anyone at the keyboard cannot ask for permission, so the permission mode decides
/// what Claude may do: `acceptEdits` unless the service's `claudePermissionMode` default says
/// otherwise (`defaults write com.local.voiced.input claudePermissionMode auto`, say). Allow rules
/// in the user's and the folder's Claude settings apply in every mode, as in the terminal.
@MainActor
enum AgentTerminal {
    private struct Session {
        let windowID: Int
        let folder: String
    }

    private static var session: Session?
    /// Sentences waiting for the run before them to finish, oldest first.
    private static var queue: [String] = []
    private static var draining: Task<Void, Never>?

    private static let permissionModes = ["default", "acceptEdits", "auto", "plan", "dontAsk", "bypassPermissions"]
    static var permissionMode: String {
        let mode = UserDefaults.standard.string(forKey: "claudePermissionMode") ?? ""
        return permissionModes.contains(mode) ? mode : "acceptEdits"
    }

    /// Sends `text` to Claude Code working in `folder`. Returns an error message when it could
    /// not be sent.
    static func send(_ text: String, in folder: String) -> String? {
        if let session, session.folder == folder, windowExists(session.windowID) {
            queue.append(text)
            drain(in: session.windowID)
            return nil
        }

        // A new window starts a new conversation; anything queued for the old one is dropped.
        queue = []
        draining?.cancel()
        draining = nil
        let shellCommand = "cd \(shellQuoted(folder)) && \(claudeCommand(text, continuing: false))"
        let result = run("""
            tell application "Terminal"
                activate
                do script \(appleScriptQuoted(shellCommand))
                return id of front window
            end tell
            """)
        if let error = result.error { return error }
        guard let windowID = result.value?.int32Value, windowID != 0 else { return "Terminal did not open a window" }
        session = Session(windowID: Int(windowID), folder: folder)
        log("Started Claude Code in \(folder) (Terminal window \(windowID), \(permissionMode))")
        return nil
    }

    private static func claudeCommand(_ text: String, continuing: Bool) -> String {
        "claude -p\(continuing ? " --continue" : "") --permission-mode \(permissionMode) \(shellQuoted(text))"
    }

    /// Runs the queued sentences in the window one after another, each once the run before it has
    /// finished, continuing the window's conversation.
    private static func drain(in windowID: Int) {
        guard draining == nil else { return }
        draining = Task {
            defer { draining = nil }
            while !queue.isEmpty {
                while isBusy(windowID) {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled || !windowExists(windowID) { queue = []; return }
                }
                let text = queue.removeFirst()
                if let error = run("""
                    tell application "Terminal"
                        do script \(appleScriptQuoted(claudeCommand(text, continuing: true))) in selected tab of window id \(windowID)
                        set index of window id \(windowID) to 1
                        activate
                    end tell
                    """).error {
                    log("Could not send to Claude Code: \(error)")
                    queue = []
                    return
                }
                // Terminal reports the tab busy only once the command has started.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func windowExists(_ windowID: Int) -> Bool {
        run("tell application \"Terminal\" to return exists window id \(windowID)").value?.booleanValue ?? false
    }

    /// Whether the window's tab runs something besides its shell: a run of Claude Code.
    private static func isBusy(_ windowID: Int) -> Bool {
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
