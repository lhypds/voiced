import Foundation

/// Runs Claude Code for Run-mode sentences and tells the phone how each run goes, as ~/code/tm's
/// ai/session.js does for its web UI.
///
/// Each sentence is one run of `claude -p`, started by this service with its events on stdout
/// (`--output-format stream-json`) and its prompt and answers on stdin (`--input-format
/// stream-json`). A tool it may not use without asking comes up as a `can_use_tool` control
/// request (`--permission-prompt-tool stdio`), which the phone allows or denies. Runs go one at a
/// time, in order; a later sentence for the same folder continues the conversation
/// (`--continue`), one for another folder starts a new one.
///
/// What the phone is told is a transcript per run, built from the events as tm builds its own:
/// Claude's text as it streams, each tool call with its result, and how the run ended. Every
/// event also goes, as it came, to a file per run, which the run's Terminal window follows
/// (`voiced --claude-follow`, see ClaudeTranscript), so the Mac shows the run too.
@MainActor
final class ClaudeRunner {
    /// Called with every event, for every connected phone.
    var onEvent: (ClaudeRunEvent) -> Void = { _ in }

    private final class Run {
        var info: ClaudeRun
        var process: Process?
        var input: FileHandle?
        var log: FileHandle?
        let logURL: URL
        /// Text items streaming for the current message, oldest first: the whole text replaces
        /// each once its block is complete.
        var openText: [Int] = []
        /// Each tool call's item, by its tool_use_id.
        var tools: [String: Int] = [:]
        var stopRequested = false
        var stderr = ""
        /// The earlier requests of the phone's record and what Claude concluded, given to Claude
        /// with this one.
        let history: [ClaudeExchange]

        init(info: ClaudeRun, logURL: URL, history: [ClaudeExchange]) {
            self.info = info
            self.logURL = logURL
            self.history = history
        }

        var items: [ClaudeRunItem] {
            get { info.items ?? [] }
            set { info.items = newValue }
        }
    }

    /// Oldest first.
    private var runs: [Run] = []
    /// The folder of the conversation the last run belonged to.
    private var conversationFolder: String?
    /// How many finished runs are kept for the phone.
    private static let keptRuns = 20
    private static let resultLimit = 2000
    private static let logFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/voiced/runs")

    init() {
        // Logs left over from an earlier start belong to runs no one follows any more.
        try? FileManager.default.removeItem(at: Self.logFolder)
    }

    /// Every run kept, with its transcript, for a phone that has just connected.
    var snapshot: ClaudeRunEvent { ClaudeRunEvent(type: .snapshot, runs: runs.map(\.info)) }

    /// Queues a run of `text` in `folder`, for the phone's transcript line `line`, with the
    /// conversation so far on the phone, `history`, for Claude to refer to.
    func start(_ text: String, in folder: String, line: String?, history: [ClaudeExchange] = []) {
        let id = Self.newID()
        let run = Run(info: ClaudeRun(id: id, line: line, text: text, folder: folder, state: .queued),
                      logURL: Self.logFolder.appending(path: "\(id).jsonl"), history: history)
        runs.append(run)
        emitState(run)
        startNext()
    }

    func handle(_ command: ClaudeRunCommand) {
        guard let run = runs.first(where: { $0.info.id == command.run }) else { return }
        switch command.command {
        case .stop:
            stop(run)
        case .allow, .deny:
            guard let pending = run.info.pending, pending.id == command.pending else { return }
            let allow = command.command == .allow
            answer(run, request: pending.id, response: allow
                ? ["behavior": "allow", "updatedInput": pendingInputs[pending.id] ?? [:]]
                : ["behavior": "deny", "message": "The user denied this on the iPhone."])
            pendingInputs[pending.id] = nil
            run.info.pending = nil
            writeLog(run, ["type": "voiced_permission", "tool": pending.tool, "allowed": allow])
            log("\(allow ? "Allowed" : "Denied") \(pending.tool) for run \(run.info.id) from the iPhone")
            emitState(run)
        }
    }

    /// The input of each tool waiting for an answer, sent back unchanged when it is allowed.
    private var pendingInputs: [String: [String: Any]] = [:]

    // MARK: Starting

    private func startNext() {
        guard !runs.contains(where: { $0.info.state == .running }),
              let run = runs.first(where: { $0.info.state == .queued }) else { return }
        let continuing = conversationFolder == run.info.folder
        conversationFolder = run.info.folder
        run.info.state = .running
        run.info.startedAt = Date().timeIntervalSince1970
        emitState(run)
        Task {
            guard let shell = await LoginShell.shared.environment() else {
                fail(run, "Claude Code was not found: `claude` is not on the PATH of your login shell.")
                return
            }
            launch(run, continuing: continuing, claude: shell.claude, environment: shell.environment)
        }
    }

    private func launch(_ run: Run, continuing: Bool, claude: String, environment: [String: String]) {
        guard run.info.state == .running, !run.stopRequested else { return }
        try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: run.logURL.path, contents: nil)
        run.log = try? FileHandle(forWritingTo: run.logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p"] + (continuing ? ["--continue"] : []) + [
            "--permission-mode", AgentTerminal.permissionMode,
            "--permission-prompt-tool", "stdio",
            "--output-format", "stream-json", "--input-format", "stream-json",
            "--verbose", "--include-partial-messages",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: run.info.folder)
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        read(stdout) { [weak self, weak run] line in
            guard let self, let run else { return }
            self.received(line, in: run)
        }
        read(stderr) { [weak run] line in
            guard let run else { return }
            run.stderr = String((run.stderr + line + "\n").suffix(2000))
        }
        process.terminationHandler = { [weak self, weak run] process in
            let status = process.terminationStatus
            // After the output still being read: the main queue runs it after their lines.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    guard let self, let run else { return }
                    self.exited(run, status: status)
                }
            }
        }
        do {
            try process.run()
        } catch {
            fail(run, "Claude Code did not start: \(error.localizedDescription)")
            return
        }
        run.process = process
        run.input = stdin.fileHandleForWriting
        send(run, ["type": "user", "message": ["role": "user", "content": Self.prompt(run.info.text, history: run.history)],
                   "parent_tool_use_id": NSNull(), "session_id": "default"])
        AgentTerminal.follow(run.logURL.path, sentence: run.info.text, in: run.info.folder)
        log("\(continuing ? "Continued" : "Started") Claude Code in \(run.info.folder) (run \(run.info.id), \(AgentTerminal.permissionMode), \(run.history.count) earlier exchanges)")
    }

    /// How many earlier exchanges Claude is given, the latest, and how much of each answer.
    private static let historyLimit = 20
    private static let answerLimit = 2000

    /// What Claude is sent for `text`: the sentence itself, after the earlier requests from the
    /// same record on the phone and what came of them, so a follow-up such as "now do the same for
    /// the other one" makes sense even in a conversation that did not continue (after a restart, or
    /// in another folder). Only conclusions: how Claude got to them is left out.
    static func prompt(_ text: String, history: [ClaudeExchange]) -> String {
        let exchanges = history.suffix(historyLimit)
        guard !exchanges.isEmpty else { return text }
        let earlier = exchanges.enumerated().map { index, exchange in
            let answer = exchange.answer.count > answerLimit ? String(exchange.answer.prefix(answerLimit)) + "…" : exchange.answer
            return "[\(index + 1)] User: \(exchange.prompt)\nYou concluded: \(answer)"
        }
        return """
        <earlier_conversation>
        For reference: the user's earlier requests in this conversation (sent by voice from their \
        iPhone) and what you concluded each time, oldest first. Only the conclusions are given, not \
        the work behind them. If you already remember these, there is nothing new here.

        \(earlier.joined(separator: "\n\n"))
        </earlier_conversation>

        \(text)
        """
    }

    /// Hands each line the pipe produces to `handler` on the main queue, in order.
    private nonisolated func read(_ pipe: Pipe, _ handler: @escaping @MainActor (String) -> Void) {
        // The handler is called for one read at a time, so the buffer is never shared.
        final class Buffer: @unchecked Sendable { var data = Data() }
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !buffer.data.isEmpty {
                    let rest = String(decoding: buffer.data, as: UTF8.self)
                    DispatchQueue.main.async { MainActor.assumeIsolated { handler(rest) } }
                }
                return
            }
            buffer.data.append(data)
            while let end = buffer.data.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer.data[buffer.data.startIndex..<end], as: UTF8.self)
                buffer.data.removeSubrange(buffer.data.startIndex...end)
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(line) } }
            }
        }
    }

    // MARK: Events

    private func received(_ line: String, in run: Run) {
        guard !line.isEmpty else { return }
        run.log?.write(Data((line + "\n").utf8))
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        // Subagents' own messages: the main agent's tool call stands for them, as in tm.
        if message["parent_tool_use_id"] is String { return }
        switch message["type"] as? String {
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "content_block_start":
                if (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                    run.openText.append(add(ClaudeRunItem(kind: .text, text: ""), to: run))
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String, let i = run.openText.last, i < run.items.count {
                    run.items[i].text = (run.items[i].text ?? "") + text
                    onEvent(ClaudeRunEvent(type: .delta, id: run.info.id, i: i, text: text))
                }
            default:
                break
            }

        case "assistant":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = block["text"] as? String ?? ""
                    if !run.openText.isEmpty {
                        let i = run.openText.removeFirst()
                        replace(i, in: run) { $0.text = text }
                    } else if !text.isEmpty {
                        add(ClaudeRunItem(kind: .text, text: text), to: run)
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let summary = ClaudeTranscript.summarize(name, block["input"] as? [String: Any] ?? [:])
                    let i = add(ClaudeRunItem(kind: .tool, name: name, summary: summary, done: false), to: run)
                    if let id = block["id"] as? String { run.tools[id] = i }
                default:
                    break
                }
            }

        case "user":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let i = run.tools[id] else { continue }
                let result = ClaudeTranscript.resultText(block["content"])
                replace(i, in: run) {
                    $0.done = true
                    $0.isError = block["is_error"] as? Bool ?? false
                    $0.result = result.count > Self.resultLimit ? String(result.prefix(Self.resultLimit)) + "…" : result
                }
            }

        case "control_request":
            controlRequest(message, in: run)

        case "result":
            let failed = message["is_error"] as? Bool == true || message["subtype"] as? String != "success"
            add(ClaudeRunItem(kind: .result, text: failed ? (message["result"] as? String ?? message["subtype"] as? String) : nil,
                              isError: failed, durationMs: message["duration_ms"] as? Double,
                              turns: message["num_turns"] as? Int), to: run)
            // The run is over: closing its input lets claude exit.
            end(run, failed ? .failed : .done)

        default:
            break
        }
    }

    private func controlRequest(_ message: [String: Any], in run: Run) {
        guard let id = message["request_id"] as? String, let request = message["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool" else {
            send(run, ["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Not supported by voiced"]])
            return
        }
        let tool = request["tool_name"] as? String ?? "tool"
        let input = request["input"] as? [String: Any] ?? [:]
        // No one can pick answers from a phone notification yet: Claude decides itself.
        if tool == "AskUserQuestion" {
            answer(run, request: id, response: ["behavior": "deny", "message": "The user is away from the keyboard and cannot answer questions. Make a reasonable choice, carry on, and say in your answer what you chose."])
            return
        }
        pendingInputs[id] = input
        run.info.pending = ClaudeRun.Pending(id: id, tool: tool, summary: ClaudeTranscript.summarize(tool, input))
        log("Run \(run.info.id) asks to use \(tool); waiting for the iPhone")
        emitState(run)
    }

    private func answer(_ run: Run, request: String, response: [String: Any]) {
        send(run, ["type": "control_response", "response": ["subtype": "success", "request_id": request, "response": response]])
    }

    private func send(_ run: Run, _ object: [String: Any]) {
        guard let input = run.input, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    // MARK: Ending

    /// The service is stopping, for a restart say: ends every run's claude now, so none is left
    /// running with no one reading it, and tells each run's Terminal window, which then ends too.
    func stopAll() {
        for run in runs where run.info.state.isGoing {
            run.stopRequested = true
            if let process = run.process, process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            writeLog(run, ["type": "voiced_end", "state": "restarted"])
            try? run.log?.close()
            run.log = nil
            log("Stopped run \(run.info.id): the service is stopping")
        }
    }

    private func stop(_ run: Run) {
        guard run.info.state.isGoing else { return }
        run.stopRequested = true
        if let process = run.process, process.isRunning {
            process.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        }
        log("Stopped run \(run.info.id) from the iPhone")
        end(run, .stopped)
    }

    private func fail(_ run: Run, _ message: String) {
        log(message)
        add(ClaudeRunItem(kind: .error, text: message), to: run)
        end(run, .failed)
    }

    /// claude exited. Without a result first it failed, or was stopped.
    private func exited(_ run: Run, status: Int32) {
        run.process = nil
        guard run.info.state.isGoing else { return }
        let detail = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        fail(run, detail.isEmpty ? "Claude Code exited (status \(status)) before it finished." : detail)
    }

    private func end(_ run: Run, _ state: ClaudeRun.State) {
        guard run.info.state.isGoing else { return }
        run.info.state = state
        run.info.endedAt = Date().timeIntervalSince1970
        if let pending = run.info.pending { pendingInputs[pending.id] = nil }
        run.info.pending = nil
        try? run.input?.close()
        run.input = nil
        // The Terminal window stops following at a result; this ends it in every other case.
        writeLog(run, ["type": "voiced_end", "state": state.rawValue])
        try? run.log?.close()
        run.log = nil
        emitState(run)
        prune()
        startNext()
    }

    private func prune() {
        let ended = runs.filter { !$0.info.state.isGoing }
        guard ended.count > Self.keptRuns else { return }
        for run in ended.prefix(ended.count - Self.keptRuns) {
            runs.removeAll { $0 === run }
            onEvent(ClaudeRunEvent(type: .remove, id: run.info.id))
        }
    }

    // MARK: Helpers

    @discardableResult
    private func add(_ item: ClaudeRunItem, to run: Run) -> Int {
        run.items.append(item)
        let i = run.items.count - 1
        onEvent(ClaudeRunEvent(type: .item, id: run.info.id, i: i, item: item))
        return i
    }

    private func replace(_ i: Int, in run: Run, _ change: (inout ClaudeRunItem) -> Void) {
        guard i < run.items.count else { return }
        change(&run.items[i])
        onEvent(ClaudeRunEvent(type: .item, id: run.info.id, i: i, item: run.items[i]))
    }

    private func emitState(_ run: Run) {
        var state = run.info
        state.items = nil
        onEvent(ClaudeRunEvent(type: .run, run: state))
    }

    private func writeLog(_ run: Run, _ object: [String: Any]) {
        guard let log = run.log, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        log.write(data)
    }

    private static func newID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// The user's login shell's PATH, and where `claude` is on it. launchd starts the service with a
/// bare PATH that rarely has claude, which the Terminal window found through the user's shell.
actor LoginShell {
    static let shared = LoginShell()
    private var cached: (claude: String, environment: [String: String])?

    func environment() async -> (claude: String, environment: [String: String])? {
        if let cached { return cached }
        let marker = "__voiced_path__"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive too: PATH is often extended in .zshrc. Its output may come first, so the
        // answer follows a marker.
        process.arguments = ["-ilc", "print -r -- \"\(marker)$(command -v claude)\(marker)$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let claude = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard claude.hasPrefix("/") else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        cached = (claude, environment)
        return cached
    }
}
