import VoicedCore
import AppKit
import Foundation

/// The `voiced` shell command under `/usr/local/bin`, installed from the Voiced menu. For an app
/// built from a checkout it is a link to the checkout's `voiced` script, the same link `install.sh`
/// makes, which also controls the voiced service. A downloaded app has no checkout, so it gets
/// a small launcher that only starts, stops or restarts this app bundle.
enum CommandLineTool {
    static let installPath = "/usr/local/bin/voiced"

    enum InstallError: Error {
        /// The binary runs outside an app bundle, as under `swift run`, so there is nothing to open.
        case notAnAppBundle
        /// The password prompt was dismissed.
        case cancelled
        case failed(String)
    }

    /// The checkout's `voiced` script when this bundle is the checkout's macos/.build/Voiced.app.
    private static var checkoutScript: URL? {
        let root = Bundle.main.bundleURL
            .deletingLastPathComponent() // .build
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository root
        let script = root.appendingPathComponent("voiced")
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }

    /// The launcher for a downloaded app. uninstall.sh recognises it by its second line.
    private static var launcher: String {
        """
        #!/bin/sh
        # Starts, stops or restarts Voiced. Installed from the Voiced menu; remove with uninstall.sh.
        #
        # Usage: voiced [start|stop|restart]   (no argument means start)

        APP="\(Bundle.main.bundleURL.path)"
        EXECUTABLE="$APP/Contents/MacOS/Voiced"

        running() {
            pgrep -f -- "$EXECUTABLE" >/dev/null
        }

        start() {
            if running; then
                # open brings the running app to the front.
                open "$APP"
                echo "Voiced is already running."
            else
                open "$APP" && echo "Started Voiced."
            fi
        }

        stop() {
            if ! running; then
                echo "Voiced is not running."
                return 0
            fi
            pkill -f -- "$EXECUTABLE"
            # Wait for the process to exit, so a following start opens a new one instead of
            # activating the old one.
            i=0
            while running && [ "$i" -lt 50 ]; do
                sleep 0.1
                i=$((i + 1))
            done
            if running; then
                echo "Voiced did not stop." >&2
                return 1
            fi
            echo "Stopped Voiced."
        }

        case "${1:-start}" in
            start) start ;;
            stop) stop ;;
            restart) stop && start ;;
            *)
                echo "Usage: voiced [start|stop|restart]" >&2
                exit 2
                ;;
        esac

        """
    }

    /// Links to the checkout's script, or writes the launcher, asking for an administrator password
    /// when the directory is not writable by the current user.
    static func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw InstallError.notAnAppBundle }

        let target = URL(fileURLWithPath: installPath)
        let directory = target.deletingLastPathComponent()
        let manager = FileManager.default

        if let script = checkoutScript {
            if manager.isWritableFile(atPath: directory.path) {
                do {
                    // Replaces an earlier launcher or link; fails, like the link, when not ours.
                    try? manager.removeItem(at: target)
                    try manager.createSymbolicLink(at: target, withDestinationURL: script)
                    return
                } catch {
                    // Owned by someone else: fall through to the privileged link.
                }
            }
            try runPrivileged([
                "mkdir -p \(shellQuoted(directory.path))",
                "ln -sfn \(shellQuoted(script.path)) \(shellQuoted(target.path))",
            ])
            return
        }

        if manager.isWritableFile(atPath: directory.path) {
            do {
                try launcher.write(to: target, atomically: true, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                return
            } catch {
                // Owned by someone else: fall through to the privileged copy.
            }
        }

        let staged = manager.temporaryDirectory.appendingPathComponent("voiced-launcher-\(ProcessInfo.processInfo.processIdentifier)")
        try launcher.write(to: staged, atomically: true, encoding: .utf8)
        defer { try? manager.removeItem(at: staged) }

        // The script text stays in the staged file, so only paths need quoting for the shell.
        try runPrivileged([
            "mkdir -p \(shellQuoted(directory.path))",
            "cp \(shellQuoted(staged.path)) \(shellQuoted(target.path))",
            "chmod 755 \(shellQuoted(target.path))",
        ])
    }

    /// Runs the commands in order as an administrator, after the system password prompt.
    private static func runPrivileged(_ commands: [String]) throws {
        let command = commands.joined(separator: " && ")
        let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw InstallError.failed(source) }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { throw InstallError.cancelled }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            throw InstallError.failed(message)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
