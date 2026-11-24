import AppKit
import Foundation

// voiced: waits for the iPhone app's connections and delivers every sentence it sends the way
// the phone says (its "Send to Mac" mode): typed at the cursor of the focused app, such as a
// terminal prompt; typed there and followed by Return; or carried out by Claude Code in a
// Terminal window (AgentTerminal). Runs on its own, without the Voiced window; `voiced` makes
// launchd start it at login and keep it running. While it runs, an icon in the menu bar shows
// its status and can stop it.
//
// Usage: VoicedInput

let usage = "Usage: VoicedInput"
// Run mode's Terminal window pipes Claude Code's events through this binary to print them.
if CommandLine.arguments.dropFirst().first == "--claude-transcript" {
    ClaudeTranscript.run(sentence: CommandLine.arguments.dropFirst(2).first ?? "")
}
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
}

// Top-level code runs on the main thread; the typer, the listener and the menu live on the main
// actor. They are kept here for the life of the process.
let app = NSApplication.shared
let (listener, statusMenu) = MainActor.assumeIsolated {
    // A menu bar item only: no Dock icon, no main menu.
    app.setActivationPolicy(.accessory)
    let status = ServiceStatus()

    if !KeyboardTyper.requestAccess() {
        log("Waiting for the Accessibility permission: allow voiced in System Settings → Privacy & Security → Accessibility. Sentences received until then are dropped.")
    }

    let listener = PhoneInputListener()
    listener.onMessage = { message in
        switch message.mode {
        case .type, .typeAndReturn:
            guard KeyboardTyper.isTrusted else {
                log("Dropped a sentence: no Accessibility permission")
                status.deliveryError = "Dropped a sentence: no Accessibility permission"
                return
            }
            let pressReturn = message.mode == .typeAndReturn
            KeyboardTyper.type(PhoneInputMessages.typedText(for: message.text, pressesReturn: pressReturn), pressReturn: pressReturn)
            status.deliveryError = nil
        case .claude:
            // A prompt is always sent, so it gets no trailing space and always Return. The folder
            // is set on the phone and comes with the sentence.
            let folder = message.resolvedFolder
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                log("Dropped a sentence: \(folder) is not a folder")
                status.deliveryError = "Dropped a sentence: \(folder) is not a folder"
                return
            }
            status.deliveryError = AgentTerminal.send(message.text, in: folder)
            if status.deliveryError != nil { return }
        }
        status.sentencesTyped += 1
        status.lastSentenceAt = Date()
    }
    listener.onReady = { status.listener = .listening(port: $0) }
    listener.onConnectionsChanged = { status.connections = $0 }
    // launchd starts the service again after it exits, so a failed listener is not retried here.
    listener.onFailure = { detail in
        log("Listener failed: \(detail)")
        status.listener = .failed(detail)
        exit(1)
    }
    do {
        try listener.start()
    } catch {
        log("Cannot listen: \(error.localizedDescription)")
        exit(1)
    }
    return (listener, StatusMenu(status: status))
}

app.run()
