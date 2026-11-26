import AppKit
import Foundation

/// Shows the Claude Code runs of sentences the iPhone marks to be carried out in a Terminal window
/// that this service opens. ClaudeRunner runs Claude Code itself; the window only follows each
/// run's events (`voiced --claude-follow`, see ClaudeTranscript), as ~/code/tm's run windows do.
///
/// The first run opens a window in its folder; each later one is followed in the same window once
/// the one before it is over. Once the last is over the window counts down three seconds and
/// closes by itself (see ClaudeTranscript); the next run opens a new one. A run in another folder opens a new window too.
///
/// The permission mode decides what Claude may do without asking: `acceptEdits` unless the
/// service's `claudePermissionMode` default says otherwise (`defaults write com.local.voiced.input
/// claudePermissionMode auto`, say). Allow rules in the user's and the folder's Claude settings
/// apply in every mode, as in the terminal; anything else is asked on the iPhone.
@MainActor
enum AgentTerminal {
    private struct Session {
        let windowID: Int
        let folder: String
    }

    private static var session: Session?
    /// Follow commands waiting for the one before them to finish, oldest first, with their runs' logs.
    private static var queue: [(command: String, log: String)] = []
    /// The log of the run the window follows, or followed last.
    private static var currentLog: String?
    /// Runs the queue in the window, then closes it once everything is over.
    private static var worker: Task<Void, Never>?

    private static let permissionModes = ["default", "acceptEdits", "auto", "plan", "dontAsk", "bypassPermissions"]
    static var permissionMode: String {
        let mode = UserDefaults.standard.string(forKey: "claudePermissionMode") ?? ""
        return permissionModes.contains(mode) ? mode : "acceptEdits"
    }

    /// Follows the run whose events go to `logPath` in the window, opening one in `folder` when
    /// there is none for it. A window that cannot be opened is only logged: the run goes on.
    static func follow(_ logPath: String, sentence: String, in folder: String) {
        let command = followCommand(logPath, sentence: sentence)
        if let session, session.folder == folder, windowExists(session.windowID) {
            queue.append((command, logPath))
            // The run before may be counting down to closing the window: it stops.
            if let currentLog { FileManager.default.createFile(atPath: ClaudeTranscript.nextRunMarker(for: currentLog), contents: nil) }
            startWorker()
            return
        }

        // A new window; anything queued for an old one in another folder is dropped.
        queue = []
        worker?.cancel()
        worker = nil
        let shellCommand = "cd \(shellQuoted(folder)) && \(command)"
        let result = run("""
            tell application "Terminal"
                activate
                do script \(appleScriptQuoted(shellCommand))
                return id of front window
            end tell
            """)
        if result.error != nil { return }
        guard let windowID = result.value?.int32Value, windowID != 0 else {
            log("Terminal did not open a window")
            return
        }
        session = Session(windowID: Int(windowID), folder: folder)
        currentLog = logPath
        log("Following the run in Terminal window \(windowID)")
        startWorker()
    }

    /// This binary, printing the run's events as they are written (see ClaudeTranscript).
    private static func followCommand(_ logPath: String, sentence: String) -> String {
        let voiced = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        return "\(shellQuoted(voiced)) --claude-follow \(shellQuoted(logPath)) \(shellQuoted(sentence))"
    }

    /// Watches the session's window: runs each queued sentence once the run before it has finished,
    /// continuing the conversation, and closes the window once the last run's follow command has
    /// counted down and ended with no other sentence come in meanwhile.
    private static func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while !Task.isCancelled {
                // Terminal reports the tab busy only once a command has started.
                try? await Task.sleep(for: .milliseconds(500))
                guard let current = session, windowExists(current.windowID) else {
                    session = nil
                    queue = []
                    return
                }
                if isBusy(current.windowID) { continue }
                if !queue.isEmpty {
                    let (command, logPath) = queue.removeFirst()
                    if let currentLog { try? FileManager.default.removeItem(atPath: ClaudeTranscript.nextRunMarker(for: currentLog)) }
                    currentLog = logPath
                    if let error = run("""
                        tell application "Terminal"
                            do script \(appleScriptQuoted(command)) in selected tab of window id \(current.windowID)
                            set index of window id \(current.windowID) to 1
                            activate
                        end tell
                        """).error {
                        log("Could not follow the run in Terminal: \(error)")
                        queue = []
                    }
                    continue
                }
                // A tab can look idle before its command has started; the follow command removes
                // its run's log as it finishes, before counting down.
                if let currentLog, FileManager.default.fileExists(atPath: currentLog) { continue }
                // Everything is over and the follow command has counted down: close the window.
                _ = run("tell application \"Terminal\" to if exists window id \(current.windowID) then close window id \(current.windowID)")
                log("Closed Terminal window \(current.windowID)")
                session = nil
                return
            }
        }
    }

    /// The service is stopping and no one will be left to close the window: once ClaudeRunner has
    /// ended the run, its follow command ends without counting down, and the window is closed.
    static func closeForShutdown() {
        worker?.cancel()
        worker = nil
        queue = []
        guard let current = session else { return }
        session = nil
        if let currentLog {
            // Skips the follow command's countdown; it removes the log as it ends.
            FileManager.default.createFile(atPath: ClaudeTranscript.nextRunMarker(for: currentLog), contents: nil)
            let deadline = Date().addingTimeInterval(2)
            while FileManager.default.fileExists(atPath: currentLog) && Date() < deadline { usleep(50_000) }
            usleep(200_000)
            try? FileManager.default.removeItem(atPath: ClaudeTranscript.nextRunMarker(for: currentLog))
        }
        // A window still running something would ask before closing; it is left open then.
        guard windowExists(current.windowID), !isBusy(current.windowID) else { return }
        _ = run("tell application \"Terminal\" to close window id \(current.windowID)")
        log("Closed Terminal window \(current.windowID): the service is stopping")
    }

    /// Whether the window is still open. A closed window can linger in Terminal's scripting for a
    /// while, invisible and without tabs: that counts as closed.
    private static func windowExists(_ windowID: Int) -> Bool {
        run("""
            tell application "Terminal"
                if not (exists window id \(windowID)) then return false
                return (visible of window id \(windowID)) and ((count of tabs of window id \(windowID)) > 0)
            end tell
            """).value?.booleanValue ?? false
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
