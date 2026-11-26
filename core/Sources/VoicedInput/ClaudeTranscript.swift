import Foundation

/// The Terminal window of a Run-mode sentence: follows the run's events, which ClaudeRunner writes
/// to a file as `claude -p --output-format stream-json --verbose --include-partial-messages` gives
/// them, and prints them as ~/code/tm's run windows do (ai/follow.js there): a header with the
/// folder, model and permission mode, the sentence as the title, Claude's text as it is written,
/// each tool call with its first line beside the name and its result under it, a note while a
/// tool waits for the iPhone's answer, then how long the run took and how it ended. The file is
/// removed once the run is over.
///
///   voiced --claude-follow <file> '<sentence>'
enum ClaudeTranscript {
    private static let resultLines = 10
    private static let summaryLines = 20

    static func follow(_ path: String, sentence: String) -> Never {
        var reader = LineFollower(path: path)
        var printer = Printer()
        printer.line("\(bold(green("voiced"))) \(dim("Claude Code"))")
        var tools: [String: (name: String, head: String)] = [:]
        var lastTool: String?
        var streamedText = false
        var started = false

        func finish() -> Never {
            try? FileManager.default.removeItem(atPath: path)
            countDown(cancelledBy: nextRunMarker(for: path))
            exit(0)
        }

        while let raw = reader.next() {
            guard let data = raw.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Not an event: claude printed something else, such as an error. Show it as it is.
                printer.line(raw)
                continue
            }
            // Subagents' own messages: the main agent's tool call stands for them, as in tm.
            if message["parent_tool_use_id"] is String { continue }
            switch message["type"] as? String {
            case "system" where message["subtype"] as? String == "init":
                printer.field("folder", message["cwd"] as? String ?? "")
                if let model = message["model"] as? String { printer.field("model", model) }
                if let mode = message["permissionMode"] as? String { printer.field("permission mode", mode) }
                printer.field("started", Date().formatted(date: .numeric, time: .standard))
                printer.gap()
                printer.line(bold("Claude: \(sentence)"))
                started = true

            case "stream_event":
                guard let event = message["event"] as? [String: Any] else { break }
                switch event["type"] as? String {
                case "message_start":
                    streamedText = false
                case "content_block_start":
                    if (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                        printer.gap()
                        streamedText = true
                    }
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        printer.write(text)
                    }
                default:
                    break
                }

            case "assistant":
                let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    switch block["type"] as? String {
                    case "text" where !streamedText:
                        printer.gap()
                        printer.write(block["text"] as? String ?? "")
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        let summary = lines(summarize(name, block["input"] as? [String: Any] ?? [:]))
                        let head = summary.first ?? ""
                        if let id = block["id"] as? String { tools[id] = (name, head); lastTool = id }
                        printer.gap()
                        printer.line("\(cyan("▸")) \(bold(name))  \(head)")
                        printer.block(Array(summary.dropFirst()), max: summaryLines)
                    default:
                        break
                    }
                }

            case "user":
                let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_result" {
                    let id = block["tool_use_id"] as? String ?? ""
                    let failed = block["is_error"] as? Bool ?? false
                    // Parallel calls finish in any order: name the tool unless it is the one just shown.
                    let label = id == lastTool ? "" : tools[id].map { "  \(dim("\($0.name)  \($0.head)"))" } ?? ""
                    printer.line((failed ? red("  ✗") : green("  ✓")) + label)
                    printer.block(lines(resultText(block["content"])), max: resultLines)
                    lastTool = nil
                }

            case "control_request":
                let request = message["request"] as? [String: Any] ?? [:]
                guard request["subtype"] as? String == "can_use_tool" else { break }
                let name = request["tool_name"] as? String ?? "tool"
                // AskUserQuestion is answered by the service itself.
                guard name != "AskUserQuestion" else { break }
                let head = lines(summarize(name, request["input"] as? [String: Any] ?? [:])).first ?? ""
                printer.gap()
                printer.line(yellow("⏸ Waiting for the iPhone to allow \(bold(name))  \(head)"))

            case "voiced_permission":
                let allowed = message["allowed"] as? Bool ?? false
                printer.line(allowed ? green("  Allowed on the iPhone") : red("  Denied on the iPhone"))

            case "voiced_end":
                // The run ended without a result: claude failed, or the iPhone stopped it.
                printer.gap()
                switch message["state"] as? String {
                case "stopped": printer.line(yellow("Run stopped from the iPhone."))
                case "restarted": printer.line(yellow("Run stopped: voiced was restarted."))
                case "done": printer.line(green("Run done."))
                default: printer.line(started ? red("Run failed.") : red("Claude Code did not start."))
                }
                finish()

            case "result":
                printer.gap()
                if message["is_error"] as? Bool == true || message["subtype"] as? String != "success" {
                    let detail = message["result"] as? String ?? message["subtype"] as? String ?? "error"
                    printer.line(red("✗ \(detail)"))
                    printer.gap()
                    printer.line(red("Run failed."))
                } else {
                    var parts = [duration(message["duration_ms"] as? Double ?? 0)]
                    if let turns = message["num_turns"] as? Int { parts.append("\(turns) turn\(turns == 1 ? "" : "s")") }
                    printer.line(green("✓ \(parts.joined(separator: " · "))"))
                    printer.gap()
                    printer.line(green("Run done."))
                }
                finish()

            default:
                break
            }
        }
        // The file went away: the service was stopped or restarted.
        printer.gap()
        printer.line(started ? yellow("Run stopped.") : red("Claude Code did not start."))
        exit(0)
    }

    /// How long the window stays after the last run before AgentTerminal closes it.
    static let closeSeconds = 3

    /// The file AgentTerminal creates when another run will follow in the window of the run
    /// logging to `logPath`, so its countdown to closing stops.
    static func nextRunMarker(for logPath: String) -> String { logPath + ".next" }

    /// Counts down on one line to the window closing, once the run is over: the window closes as
    /// this process ends. Stops at once, clearing the line, when `marker` appears because another
    /// run is about to be followed in the window.
    private static func countDown(cancelledBy marker: String) {
        let out = FileHandle.standardOutput
        let clear = color ? "\r\u{1B}[2K" : "\r"
        out.write(Data("\n".utf8))
        for remaining in stride(from: closeSeconds, to: 0, by: -1) {
            out.write(Data((clear + dim("Closing in \(remaining) s…")).utf8))
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: marker) {
                    try? FileManager.default.removeItem(atPath: marker)
                    out.write(Data(clear.utf8))
                    return
                }
                usleep(100_000)
            }
        }
        out.write(Data((clear + dim("Closing…")).utf8))
    }

    /// Reads a file's lines as they are written, waiting at its end for more, as tm's follow.js
    /// does. Ends when the file is gone.
    private struct LineFollower {
        let path: String
        private var handle: FileHandle?
        private var buffer = Data()

        init(path: String) {
            self.path = path
        }

        mutating func next() -> String? {
            while true {
                if let end = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...end)
                    return line
                }
                if handle == nil { handle = FileHandle(forReadingAtPath: path) }
                if let handle, let data = try? handle.readToEnd(), !data.isEmpty {
                    buffer.append(data)
                    continue
                }
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                usleep(150_000)
            }
        }
    }

    /// What a tool call is about, as tm's summarizeTool has it: the command of Bash, the file of an
    /// edit, the pattern of a search… else the input as JSON.
    static func summarize(_ name: String, _ input: [String: Any]) -> String {
        func text(_ key: String) -> String { input[key].map { $0 as? String ?? "\($0)" } ?? "" }
        switch name {
        case "Bash": return text("command")
        case "Read", "Write", "Edit", "MultiEdit": return text("file_path")
        case "NotebookEdit": return text("notebook_path")
        case "Glob", "Grep": return [text("pattern"), text("path")].filter { !$0.isEmpty }.joined(separator: "  in  ")
        case "WebFetch": return text("url")
        case "WebSearch": return text("query")
        case "Agent", "Task": return input["description"] != nil ? text("description") : text("prompt")
        case "Skill": return input["skill"] != nil ? text("skill") : text("command")
        case "ExitPlanMode": return text("plan")
        case "TodoWrite": return ""
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A tool result's text: a string, or the text parts of a list of content blocks.
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return parts.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimmed.isEmpty ? [] : trimmed.components(separatedBy: "\n")
    }

    private static func duration(_ milliseconds: Double) -> String {
        let seconds = max(0, Int((milliseconds / 1000).rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: Output

    private static let color = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    private static func paint(_ code: String, _ text: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    private static func bold(_ text: String) -> String { paint("1", text) }
    private static func dim(_ text: String) -> String { paint("2", text) }
    private static func red(_ text: String) -> String { paint("31", text) }
    private static func green(_ text: String) -> String { paint("32", text) }
    private static func yellow(_ text: String) -> String { paint("33", text) }
    private static func cyan(_ text: String) -> String { paint("36", text) }

    /// Writes as it goes, keeping track of where the cursor is so blocks get one empty line between them.
    private struct Printer {
        private var atLineStart = true
        private var lastLineEmpty = true
        private var lineLength = 0

        mutating func write(_ text: String) {
            guard !text.isEmpty else { return }
            FileHandle.standardOutput.write(Data(text.utf8))
            for character in text {
                if character == "\n" { lastLineEmpty = lineLength == 0; lineLength = 0 } else { lineLength += 1 }
            }
            atLineStart = text.hasSuffix("\n")
        }

        mutating func newline() { if !atLineStart { write("\n") } }
        mutating func line(_ text: String = "") { newline(); write(text + "\n") }
        mutating func gap() { newline(); if !lastLineEmpty { write("\n") } }
        mutating func field(_ label: String, _ value: String) { line("\(ClaudeTranscript.dim("\(label):")) \(value)") }

        /// Lines under a heading: `max` at most, indented and dim.
        mutating func block(_ all: [String], max: Int) {
            for text in all.prefix(max) { line(ClaudeTranscript.dim("    " + text)) }
            if all.count > max { line(ClaudeTranscript.dim("    … \(all.count - max) more lines")) }
        }
    }
}
