import AppKit
import Foundation

/// The `voiced` shell command: a script under `/usr/local/bin` that opens this app bundle, the
/// same one `install.sh` writes. Installed from the Voiced menu.
enum CommandLineTool {
    static let installPath = "/usr/local/bin/voiced"

    enum InstallError: Error {
        /// The binary runs outside an app bundle, as under `swift run`, so there is nothing to open.
        case notAnAppBundle
        /// The password prompt was dismissed.
        case cancelled
        case failed(String)
    }

    private static var launcher: String {
        """
        #!/bin/sh
        # Opens Voiced. Installed from the Voiced menu; remove with uninstall.sh.
        exec open "\(Bundle.main.bundleURL.path)"

        """
    }

    /// Writes the launcher, asking for an administrator password when the directory is not
    /// writable by the current user.
    static func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw InstallError.notAnAppBundle }

        let target = URL(fileURLWithPath: installPath)
        let directory = target.deletingLastPathComponent()
        let manager = FileManager.default
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
        let command = [
            "mkdir -p \(shellQuoted(directory.path))",
            "cp \(shellQuoted(staged.path)) \(shellQuoted(target.path))",
            "chmod 755 \(shellQuoted(target.path))",
        ].joined(separator: " && ")
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
