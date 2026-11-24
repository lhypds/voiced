import Foundation

// Voiced Input: waits for the iPhone app's connections and types every sentence it sends at the
// cursor of the focused app, such as a terminal prompt. Runs on its own, without the Voiced
// window; core/install.sh makes launchd start it at login and keep it running.
//
// Usage: VoicedInput [--return | --no-return]
//
// Without a flag, whether Return follows each sentence is read from "phoneInputReturn" in
// ~/.voiced/settings.json for every sentence, so the switch in the app's Settings applies at once.

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

let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".voiced/settings.json")

func pressesReturn() -> Bool {
    if let pressReturnOverride { return pressReturnOverride }
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return settings["phoneInputReturn"] as? Bool ?? false
}

// Top-level code runs on the main thread; the typer and the listener live on the main actor.
// The listener is kept here for the life of the process.
let listener = MainActor.assumeIsolated {
    if !KeyboardTyper.requestAccess() {
        log("Waiting for the Accessibility permission: allow VoicedInput in System Settings → Privacy & Security → Accessibility. Sentences received until then are dropped.")
    }

    let listener = PhoneInputListener()
    listener.onText = { text in
        guard KeyboardTyper.isTrusted else {
            log("Dropped a sentence: no Accessibility permission")
            return
        }
        let pressReturn = pressesReturn()
        KeyboardTyper.type(PhoneInputMessages.typedText(for: text, pressesReturn: pressReturn), pressReturn: pressReturn)
    }
    // launchd starts the service again after it exits, so a failed listener is not retried here.
    listener.onFailure = { detail in
        log("Listener failed: \(detail)")
        exit(1)
    }
    do {
        try listener.start()
    } catch {
        log("Cannot listen: \(error.localizedDescription)")
        exit(1)
    }
    return listener
}

dispatchMain()
