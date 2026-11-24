import AppKit
import Foundation

// Voiced Input: waits for the iPhone app's connections and types every sentence it sends at the
// cursor of the focused app, such as a terminal prompt. Runs on its own, without the Voiced
// window; `voiced start` makes launchd start it at login and keep it running. While it runs, an icon
// in the menu bar shows its status and can stop it.
//
// Usage: VoicedInput [--return | --no-return]
//
// Sentences go to the target chosen in the menu bar card or with `voiced target`: the cursor, or
// Claude Code or Codex in a Terminal window (AgentTerminal). For the cursor, without a flag,
// whether Return follows each sentence is the "Press Return after each sentence" switch in the
// card, stored in the service's own defaults.

let usage = "Usage: VoicedInput [--return | --no-return]"
var pressReturnOverride: Bool?
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--return": pressReturnOverride = true
    case "--no-return": pressReturnOverride = false
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
}

func pressesReturn() -> Bool {
    pressReturnOverride ?? ServiceSettings.pressesReturn
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
    listener.onText = { text in
        let target = ServiceSettings.target
        if target == .cursor {
            guard KeyboardTyper.isTrusted else {
                log("Dropped a sentence: no Accessibility permission")
                status.deliveryError = "Dropped a sentence: no Accessibility permission"
                return
            }
            let pressReturn = pressesReturn()
            KeyboardTyper.type(PhoneInputMessages.typedText(for: text, pressesReturn: pressReturn), pressReturn: pressReturn)
            status.deliveryError = nil
        } else {
            // An agent's prompt is always sent, so it gets no trailing space and always Return.
            status.deliveryError = AgentTerminal.send(text, to: target, in: ServiceSettings.workFolder)
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
