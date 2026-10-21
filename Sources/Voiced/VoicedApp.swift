import AppKit
import SwiftUI

@main
struct VoicedApp: App {
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
