import VoicedCore
import AppKit
import SwiftUI

@main
struct VoicedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var transcriber = TranscriptionController()

    init() {
        // Must run before the controller loads settings and history from `~/.voiced`.
        VoicedDirectory.migrateLegacyData()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: transcriber)
                .frame(minWidth: 360, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 720)
        .commands {
            // In the application menu, under "About Voiced".
            CommandGroup(after: .appInfo) {
                Button(transcriber.strings.installCommand) {
                    installCommandLineTool()
                }
            }
        }
    }

    /// Installs the `voiced` shell command and reports the outcome in an alert. A dismissed
    /// password prompt is silent.
    private func installCommandLineTool() {
        let strings = transcriber.strings
        let alert = NSAlert()
        do {
            try CommandLineTool.install()
            alert.messageText = strings.commandInstalled(at: CommandLineTool.installPath)
        } catch CommandLineTool.InstallError.cancelled {
            return
        } catch CommandLineTool.InstallError.notAnAppBundle {
            alert.alertStyle = .warning
            alert.messageText = strings.commandNeedsAppBundle
        } catch {
            alert.alertStyle = .warning
            let detail = if case CommandLineTool.InstallError.failed(let message) = error { message } else { error.localizedDescription }
            alert.messageText = strings.commandInstallFailed(detail)
        }
        alert.runModal()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Comes to the front on launch. Started by `open` from a terminal, as `voiced` and the
    /// scripts do, the app would otherwise open behind the terminal that keeps the focus.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI creates the main window only after launch has finished.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = Self.closeExtraWindows() else { return }
            window.makeKeyAndOrderFront(nil)
            // macOS 14 may decline the activation; this still raises the window.
            window.orderFrontRegardless()
        }
    }

    /// Keeps a single main window: the key window, or else the first visible one, survives and
    /// every other visible main-capable window is closed. Returns the surviving window, or the
    /// first main-capable window when none is on screen yet.
    @discardableResult
    static func closeExtraWindows() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.canBecomeMain }
        let visible = candidates.filter(\.isVisible)
        guard let kept = visible.first(where: \.isKeyWindow) ?? visible.first ?? candidates.first else { return nil }
        for window in visible where window !== kept {
            window.close()
        }
        return kept
    }
}
