//! Runs Claude Code for Run-mode sentences and tells the phone how each run goes, as ~/code/tm's
//! ai/session.js does for its web UI.
//!
//! Each sentence is one run of `claude -p`, started by this service with its events on stdout
//! (`--output-format stream-json`) and its prompt and answers on stdin (`--input-format
//! stream-json`). A tool it may not use without asking comes up as a `can_use_tool` control
//! request (`--permission-prompt-tool stdio`), which the phone allows or denies. Runs go one at a
//! time, in order; a later sentence of the same record on the phone, for the same folder,
//! continues the conversation (`--resume`), one of another record or for another folder starts a
//! new one.
//!
//! What the phone is told is a transcript per run, built from the events as tm builds its own:
//! Claude's text as it streams, each tool call with its result, and how the run ended. Every
//! event also goes, as it came, to a file per run, which the run's terminal window follows.
//!
//! Everything here runs on the core thread; the threads reading claude's output send what they
//! read there as events.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use shared_child::SharedChild;

use crate::protocol::{ClaudeExchange, ClaudeRun, CommandAction, ItemKind, Pending, RunCommand, RunEvent, RunItem, RunState};
use crate::shell::ShellEnv;
use crate::terminal::{self, Terminal};
use crate::transcript::{content, non_empty, result_text, str_of, summarize};
use crate::{log, Event};

/// How many finished runs are kept for the phone.
const KEPT_RUNS: usize = 20;
const RESULT_LIMIT: usize = 2000;
/// How many earlier exchanges Claude is given, the latest, and how much of each answer.
const HISTORY_LIMIT: usize = 20;
const ANSWER_LIMIT: usize = 2000;

struct Run {
    info: ClaudeRun,
    child: Option<Arc<SharedChild>>,
    input: Option<ChildStdin>,
    log: Option<File>,
    log_path: PathBuf,
    /// Text items streaming for the current message, oldest first: the whole text replaces each
    /// once its block is complete.
    open_text: Vec<usize>,
    /// Each tool call's item, by its tool_use_id.
    tools: HashMap<String, usize>,
    stop_requested: bool,
    stderr: String,
    /// The earlier requests of the phone's record and what Claude concluded.
    history: Vec<ClaudeExchange>,
    /// The phone's record the sentence is in; none from older phones.
    record: Option<String>,
    /// The session this run continues; none when it starts a conversation.
    resume: Option<String>,
}

/// The conversation the last run belonged to.
struct Conversation {
    folder: String,
    record: Option<String>,
    /// Claude Code's id for it, known once a run of it has started; none when none got that far.
    session: Option<String>,
}

impl Conversation {
    /// The session a sentence of `record` for `folder` continues: this one's, when it is the
    /// same record in the same folder. Any other sentence starts a new conversation.
    fn session_for(&self, folder: &str, record: Option<&str>) -> Option<String> {
        if self.folder == folder && self.record.as_deref() == record { self.session.clone() } else { None }
    }
}

impl Run {
    fn items(&mut self) -> &mut Vec<RunItem> {
        self.info.items.get_or_insert_with(Vec::new)
    }
}

pub struct Runner {
    events: Sender<Event>,
    /// Events for the phones, collected for the core thread to send.
    pub outbox: Vec<RunEvent>,
    pub terminal: Terminal,
    /// Oldest first.
    runs: Vec<Run>,
    conversation: Option<Conversation>,
    /// The input of each tool waiting for an answer, sent back unchanged when it is allowed.
    pending_inputs: HashMap<String, Value>,
}

pub fn log_folder() -> PathBuf {
    dirs::cache_dir().unwrap_or_else(std::env::temp_dir).join("voiced").join("runs")
}

impl Runner {
    pub fn new(events: Sender<Event>) -> Runner {
        // Logs left over from an earlier start belong to runs no one follows any more.
        let _ = fs::remove_dir_all(log_folder());
        Runner {
            events,
            outbox: Vec::new(),
            terminal: Terminal::default(),
            runs: Vec::new(),
            conversation: None,
            pending_inputs: HashMap::new(),
        }
    }

    /// Every run kept, with its transcript, for a phone that has just connected.
    pub fn snapshot(&self) -> RunEvent {
        RunEvent::snapshot(self.runs.iter().map(|r| r.info.clone()).collect())
    }

    /// Queues a run of `text` in `folder`, for the phone's transcript line `line` of its record
    /// `record`, with the conversation so far on the phone, `history`, for Claude to refer to.
    pub fn start(&mut self, text: String, folder: String, line: Option<String>, record: Option<String>, history: Vec<ClaudeExchange>) {
        let id = new_id();
        let log_path = log_folder().join(format!("{id}.jsonl"));
        let info = ClaudeRun {
            id,
            line,
            text,
            folder,
            state: RunState::Queued,
            started_at: None,
            ended_at: None,
            pending: None,
            items: Some(Vec::new()),
        };
        self.runs.push(Run {
            info,
            child: None,
            input: None,
            log: None,
            log_path,
            open_text: Vec::new(),
            tools: HashMap::new(),
            stop_requested: false,
            stderr: String::new(),
            history,
            record,
            resume: None,
        });
        let index = self.runs.len() - 1;
        self.emit_state(index);
        self.start_next();
    }

    pub fn handle(&mut self, command: RunCommand) {
        let Some(index) = self.index(&command.run) else { return };
        match command.command {
            CommandAction::Stop => self.stop(index),
            CommandAction::Allow | CommandAction::Deny => {
                let Some(pending) = self.runs[index].info.pending.clone() else { return };
                if command.pending.as_deref() != Some(pending.id.as_str()) {
                    return;
                }
                let allow = command.command == CommandAction::Allow;
                let input = self.pending_inputs.remove(&pending.id).unwrap_or_else(|| json!({}));
                let response = if allow {
                    json!({"behavior": "allow", "updatedInput": input})
                } else {
                    json!({"behavior": "deny", "message": "The user denied this on the iPhone."})
                };
                let run = &mut self.runs[index];
                answer(run, &pending.id, response);
                run.info.pending = None;
                write_log(run, json!({"type": "voiced_permission", "tool": pending.tool, "allowed": allow}));
                log!("{} {} for run {} from the iPhone", if allow { "Allowed" } else { "Denied" }, pending.tool, run.info.id);
                self.emit_state(index);
            }
        }
    }

    fn index(&self, id: &str) -> Option<usize> {
        self.runs.iter().position(|r| r.info.id == id)
    }

    // MARK: Starting

    fn start_next(&mut self) {
        if self.runs.iter().any(|r| r.info.state == RunState::Running) {
            return;
        }
        let Some(index) = self.runs.iter().position(|r| r.info.state == RunState::Queued) else { return };
        let folder = self.runs[index].info.folder.clone();
        let record = self.runs[index].record.clone();
        let resume = self.conversation.as_ref().and_then(|c| c.session_for(&folder, record.as_deref()));
        self.conversation = Some(Conversation { folder, record, session: resume.clone() });
        let run = &mut self.runs[index];
        run.resume = resume;
        run.info.state = RunState::Running;
        run.info.started_at = Some(now());
        let id = run.info.id.clone();
        self.emit_state(index);
        // The login shell can take a second: it is asked off the core thread.
        let events = self.events.clone();
        thread::spawn(move || {
            let environment = crate::shell::environment();
            let _ = events.send(Event::ShellReady { run: id, environment });
        });
    }

    pub fn shell_ready(&mut self, id: &str, environment: Option<ShellEnv>) {
        let Some(index) = self.index(id) else { return };
        match environment {
            None => self.fail(index, "Claude Code was not found: `claude` is not on the PATH of your login shell.".into()),
            Some(shell) => self.launch(index, shell),
        }
    }

    fn launch(&mut self, index: usize, shell: ShellEnv) {
        let permission_mode = terminal::permission_mode();
        let run = &mut self.runs[index];
        if run.info.state != RunState::Running || run.stop_requested {
            return;
        }
        let _ = fs::create_dir_all(log_folder());
        run.log = File::create(&run.log_path).ok();

        // By its id, not `--continue`: the latest conversation in the folder may be someone else's.
        let resume = run.resume.clone();
        let mut arguments: Vec<&str> = vec!["-p"];
        if let Some(session) = &resume {
            arguments.extend(["--resume", session]);
        }
        arguments.extend([
            "--permission-mode", &permission_mode,
            "--permission-prompt-tool", "stdio",
            "--output-format", "stream-json", "--input-format", "stream-json",
            "--verbose", "--include-partial-messages",
        ]);
        let mut command = claude_command(&shell.claude);
        command
            .args(&arguments)
            .current_dir(&run.info.folder)
            .env_clear()
            .envs(&shell.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let child = match SharedChild::spawn(&mut command) {
            Ok(child) => Arc::new(child),
            Err(error) => {
                self.fail(index, format!("Claude Code did not start: {error}"));
                return;
            }
        };
        let stdout = child.take_stdout();
        let stderr = child.take_stderr();
        run.input = child.take_stdin();
        run.child = Some(child.clone());

        let id = run.info.id.clone();
        let events = self.events.clone();
        let out_reader = stdout.map(|stdout| {
            let (events, id) = (events.clone(), id.clone());
            thread::spawn(move || read_lines(stdout, |line| events.send(Event::ClaudeLine { run: id.clone(), line }).is_ok()))
        });
        let err_reader = stderr.map(|stderr| {
            let (events, id) = (events.clone(), id.clone());
            thread::spawn(move || read_lines(stderr, |line| events.send(Event::ClaudeStderr { run: id.clone(), line }).is_ok()))
        });
        // Exited only once its output has all been read, so the run's last lines come first.
        thread::spawn(move || {
            out_reader.map(|t| t.join());
            err_reader.map(|t| t.join());
            let status = match child.wait() {
                Ok(status) => status.code().map(|c| c.to_string()).unwrap_or_else(|| status.to_string()),
                Err(error) => error.to_string(),
            };
            let _ = events.send(Event::ClaudeExited { run: id, status });
        });

        let prompt = prompt(&run.info.text, &run.history);
        send(run, json!({"type": "user", "message": {"role": "user", "content": prompt}, "parent_tool_use_id": null, "session_id": "default"}));
        let (log_path, text, folder) = (run.log_path.clone(), run.info.text.clone(), run.info.folder.clone());
        log!(
            "{} Claude Code in {folder} (run {}, {permission_mode}, {} earlier exchanges)",
            if resume.is_some() { "Continued" } else { "Started" },
            run.info.id,
            run.history.len()
        );
        self.terminal.follow(&log_path, &text, &folder);
    }

    // MARK: Events

    pub fn received(&mut self, id: &str, line: String) {
        let Some(index) = self.index(id) else { return };
        if line.is_empty() {
            return;
        }
        if let Some(log) = self.runs[index].log.as_mut() {
            let _ = log.write_all(format!("{line}\n").as_bytes());
        }
        let Ok(Value::Object(message)) = serde_json::from_str::<Value>(&line) else { return };
        // Subagents' own messages: the main agent's tool call stands for them, as in tm.
        if message.get("parent_tool_use_id").is_some_and(Value::is_string) {
            return;
        }
        match str_of(&message, "type") {
            // Runs go one at a time, so the conversation is this run's: later sentences resume it.
            "system" if str_of(&message, "subtype") == "init" => {
                if let (Some(conversation), Some(session)) = (self.conversation.as_mut(), message.get("session_id").and_then(Value::as_str)) {
                    conversation.session = Some(session.into());
                }
            }
            "stream_event" => {
                let Some(event) = message.get("event").and_then(Value::as_object) else { return };
                match str_of(event, "type") {
                    "content_block_start" => {
                        if event.get("content_block").and_then(Value::as_object).map(|b| str_of(b, "type")) == Some("text") {
                            let mut item = RunItem::new(ItemKind::Text);
                            item.text = Some(String::new());
                            let i = self.add(index, item);
                            self.runs[index].open_text.push(i);
                        }
                    }
                    "content_block_delta" => {
                        let Some(delta) = event.get("delta").and_then(Value::as_object) else { return };
                        let Some(text) = delta.get("text").and_then(Value::as_str) else { return };
                        if str_of(delta, "type") != "text_delta" {
                            return;
                        }
                        let run = &mut self.runs[index];
                        let Some(&i) = run.open_text.last() else { return };
                        let Some(item) = run.items().get_mut(i) else { return };
                        item.text.get_or_insert_with(String::new).push_str(text);
                        let event = RunEvent::delta(&run.info.id, i, text);
                        self.outbox.push(event);
                    }
                    _ => {}
                }
            }
            "assistant" => {
                for block in content(&message) {
                    match str_of(block, "type") {
                        "text" => {
                            let text = str_of(block, "text").to_string();
                            if !self.runs[index].open_text.is_empty() {
                                let i = self.runs[index].open_text.remove(0);
                                self.replace(index, i, |item| item.text = Some(text));
                            } else if !text.is_empty() {
                                let mut item = RunItem::new(ItemKind::Text);
                                item.text = Some(text);
                                self.add(index, item);
                            }
                        }
                        "tool_use" => {
                            let name = non_empty(str_of(block, "name"), "tool");
                            let mut item = RunItem::new(ItemKind::Tool);
                            item.summary = Some(summarize(&name, block.get("input")));
                            item.name = Some(name);
                            item.done = Some(false);
                            let i = self.add(index, item);
                            if let Some(id) = block.get("id").and_then(Value::as_str) {
                                self.runs[index].tools.insert(id.into(), i);
                            }
                        }
                        _ => {}
                    }
                }
            }
            "user" => {
                for block in content(&message).into_iter().filter(|b| str_of(b, "type") == "tool_result") {
                    let Some(&i) = self.runs[index].tools.get(str_of(block, "tool_use_id")) else { continue };
                    let result = result_text(block.get("content"));
                    let is_error = block.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                    self.replace(index, i, |item| {
                        item.done = Some(true);
                        item.is_error = Some(is_error);
                        item.result = Some(truncated(&result, RESULT_LIMIT));
                    });
                }
            }
            "control_request" => self.control_request(index, &message),
            "result" => {
                let failed = message.get("is_error").and_then(Value::as_bool) == Some(true) || str_of(&message, "subtype") != "success";
                let mut item = RunItem::new(ItemKind::Result);
                if failed {
                    item.text = message
                        .get("result")
                        .and_then(Value::as_str)
                        .or_else(|| message.get("subtype").and_then(Value::as_str))
                        .map(String::from);
                }
                item.is_error = Some(failed);
                item.duration_ms = message.get("duration_ms").and_then(Value::as_f64);
                item.turns = message.get("num_turns").and_then(Value::as_i64);
                self.add(index, item);
                // The run is over: closing its input lets claude exit.
                self.end(index, if failed { RunState::Failed } else { RunState::Done });
            }
            _ => {}
        }
    }

    pub fn received_stderr(&mut self, id: &str, line: String) {
        let Some(index) = self.index(id) else { return };
        let run = &mut self.runs[index];
        run.stderr = tail(&format!("{}{line}\n", run.stderr), 2000);
    }

    fn control_request(&mut self, index: usize, message: &serde_json::Map<String, Value>) {
        let Some(id) = message.get("request_id").and_then(Value::as_str) else { return };
        let Some(request) = message.get("request").and_then(Value::as_object) else { return };
        let run = &mut self.runs[index];
        if str_of(request, "subtype") != "can_use_tool" {
            send(run, json!({"type": "control_response", "response": {"subtype": "error", "request_id": id, "error": "Not supported by voiced"}}));
            return;
        }
        let tool = non_empty(str_of(request, "tool_name"), "tool");
        let input = request.get("input").filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({}));
        // No one can pick answers from a phone notification yet: Claude decides itself.
        if tool == "AskUserQuestion" {
            answer(run, id, json!({"behavior": "deny", "message": "The user is away from the keyboard and cannot answer questions. Make a reasonable choice, carry on, and say in your answer what you chose."}));
            return;
        }
        run.info.pending = Some(Pending { id: id.into(), tool: tool.clone(), summary: summarize(&tool, Some(&input)) });
        log!("Run {} asks to use {tool}; waiting for the iPhone", run.info.id);
        self.pending_inputs.insert(id.into(), input);
        self.emit_state(index);
    }

    // MARK: Ending

    /// The service is stopping, for a restart say: ends every run's claude now, so none is left
    /// running with no one reading it, and tells each run's window, which then ends too.
    pub fn stop_all(&mut self) {
        for run in self.runs.iter_mut().filter(|r| r.info.state.is_going()) {
            run.stop_requested = true;
            if let Some(child) = &run.child {
                if matches!(child.try_wait(), Ok(None)) {
                    terminate(child);
                    let deadline = Instant::now() + Duration::from_secs(1);
                    while matches!(child.try_wait(), Ok(None)) && Instant::now() < deadline {
                        thread::sleep(Duration::from_millis(20));
                    }
                    kill(child);
                }
            }
            write_log(run, json!({"type": "voiced_end", "state": "restarted"}));
            run.log = None;
            log!("Stopped run {}: the service is stopping", run.info.id);
        }
    }

    fn stop(&mut self, index: usize) {
        let run = &mut self.runs[index];
        if !run.info.state.is_going() {
            return;
        }
        run.stop_requested = true;
        if let Some(child) = run.child.clone() {
            if matches!(child.try_wait(), Ok(None)) {
                interrupt(&child);
                thread::spawn(move || {
                    thread::sleep(Duration::from_secs(3));
                    if matches!(child.try_wait(), Ok(None)) {
                        terminate(&child);
                    }
                });
            }
        }
        log!("Stopped run {} from the iPhone", run.info.id);
        self.end(index, RunState::Stopped);
    }

    fn fail(&mut self, index: usize, message: String) {
        log!("{message}");
        let mut item = RunItem::new(ItemKind::Error);
        item.text = Some(message);
        self.add(index, item);
        self.end(index, RunState::Failed);
    }

    /// claude exited. Without a result first it failed, or was stopped.
    pub fn exited(&mut self, id: &str, status: String) {
        let Some(index) = self.index(id) else { return };
        let run = &mut self.runs[index];
        run.child = None;
        if !run.info.state.is_going() {
            return;
        }
        let detail = run.stderr.trim().to_string();
        self.fail(index, if detail.is_empty() { format!("Claude Code exited (status {status}) before it finished.") } else { detail });
    }

    fn end(&mut self, index: usize, state: RunState) {
        let run = &mut self.runs[index];
        if !run.info.state.is_going() {
            return;
        }
        run.info.state = state;
        run.info.ended_at = Some(now());
        if let Some(pending) = run.info.pending.take() {
            self.pending_inputs.remove(&pending.id);
        }
        run.input = None;
        // The window stops following at a result; this ends it in every other case.
        write_log(run, json!({"type": "voiced_end", "state": state.name()}));
        run.log = None;
        self.emit_state(index);
        self.prune();
        self.start_next();
    }

    fn prune(&mut self) {
        let ended = self.runs.iter().filter(|r| !r.info.state.is_going()).count();
        let mut excess = ended.saturating_sub(KEPT_RUNS);
        while excess > 0 {
            let Some(index) = self.runs.iter().position(|r| !r.info.state.is_going()) else { break };
            let run = self.runs.remove(index);
            self.outbox.push(RunEvent::remove(&run.info.id));
            excess -= 1;
        }
    }

    // MARK: Helpers

    fn add(&mut self, index: usize, item: RunItem) -> usize {
        let run = &mut self.runs[index];
        let items = run.items();
        items.push(item.clone());
        let i = items.len() - 1;
        let event = RunEvent::item(&run.info.id, i, item);
        self.outbox.push(event);
        i
    }

    fn replace(&mut self, index: usize, i: usize, change: impl FnOnce(&mut RunItem)) {
        let run = &mut self.runs[index];
        let Some(item) = run.items().get_mut(i) else { return };
        change(item);
        let item = item.clone();
        let event = RunEvent::item(&run.info.id, i, item);
        self.outbox.push(event);
    }

    fn emit_state(&mut self, index: usize) {
        let mut state = self.runs[index].info.clone();
        state.items = None;
        self.outbox.push(RunEvent::state(state));
    }
}

/// What Claude is sent for `text`: the sentence itself, after the earlier requests from the same
/// record on the phone and what came of them, so a follow-up such as "now do the same for the
/// other one" makes sense even in a conversation that did not continue (after a restart, or in
/// another folder). Only conclusions: how Claude got to them is left out.
pub fn prompt(text: &str, history: &[ClaudeExchange]) -> String {
    let exchanges = &history[history.len().saturating_sub(HISTORY_LIMIT)..];
    if exchanges.is_empty() {
        return text.to_string();
    }
    let earlier: Vec<String> = exchanges
        .iter()
        .enumerate()
        .map(|(index, exchange)| {
            let answer = if exchange.answer.chars().count() > ANSWER_LIMIT { truncated(&exchange.answer, ANSWER_LIMIT) } else { exchange.answer.clone() };
            format!("[{}] User: {}\nYou concluded: {answer}", index + 1, exchange.prompt)
        })
        .collect();
    format!(
        "<earlier_conversation>\n\
         For reference: the user's earlier requests in this conversation (sent by voice from their \
         iPhone) and what you concluded each time, oldest first. Only the conclusions are given, not \
         the work behind them. If you already remember these, there is nothing new here.\n\
         \n\
         {}\n\
         </earlier_conversation>\n\
         \n\
         {text}",
        earlier.join("\n\n")
    )
}

/// claude itself, or on Windows an npm install's claude.cmd, which only cmd can run.
fn claude_command(claude: &std::path::Path) -> Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let is_script = claude.extension().is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
        let mut command = if is_script {
            let mut command = Command::new("cmd");
            command.arg("/C").arg(claude);
            command
        } else {
            Command::new(claude)
        };
        command.creation_flags(CREATE_NO_WINDOW);
        command
    }
    #[cfg(not(windows))]
    Command::new(claude)
}

/// Hands each line `reader` produces to `handler`, in order, until it ends or `handler` says stop.
fn read_lines(reader: impl Read, mut handler: impl FnMut(String) -> bool) {
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {
                if line.last() == Some(&b'\n') {
                    line.pop();
                }
                if !handler(String::from_utf8_lossy(&line).into_owned()) {
                    return;
                }
            }
        }
    }
}

fn answer(run: &mut Run, request: &str, response: Value) {
    send(run, json!({"type": "control_response", "response": {"subtype": "success", "request_id": request, "response": response}}));
}

fn send(run: &mut Run, object: Value) {
    let Some(input) = run.input.as_mut() else { return };
    let mut data = serde_json::to_vec(&object).unwrap_or_default();
    data.push(b'\n');
    let _ = input.write_all(&data);
    let _ = input.flush();
}

fn write_log(run: &mut Run, object: Value) {
    let Some(log) = run.log.as_mut() else { return };
    let mut data = serde_json::to_vec(&object).unwrap_or_default();
    data.push(b'\n');
    let _ = log.write_all(&data);
}

/// Ctrl-C for claude: it ends its turn as in the terminal.
fn interrupt(child: &SharedChild) {
    #[cfg(unix)]
    {
        use shared_child::unix::SharedChildExt;
        let _ = child.send_signal(libc::SIGINT);
    }
    #[cfg(windows)]
    kill(child);
}

fn terminate(child: &SharedChild) {
    #[cfg(unix)]
    {
        use shared_child::unix::SharedChildExt;
        let _ = child.send_signal(libc::SIGTERM);
    }
    #[cfg(windows)]
    kill(child);
}

/// On Windows the whole tree: claude.cmd runs node under cmd, which killing cmd would leave behind.
fn kill(child: &SharedChild) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = Command::new("taskkill")
            .args(["/T", "/F", "/PID", &child.id().to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(0x0800_0000)
            .status();
    }
    let _ = child.kill();
}

fn truncated(text: &str, limit: usize) -> String {
    if text.chars().count() > limit { text.chars().take(limit).collect::<String>() + "…" } else { text.to_string() }
}

fn tail(text: &str, limit: usize) -> String {
    let count = text.chars().count();
    text.chars().skip(count.saturating_sub(limit)).collect()
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn new_id() -> String {
    (0..6).map(|_| format!("{:02x}", fastrand::u8(..))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_wraps_history() {
        assert_eq!(prompt("go", &[]), "go");
        let history = vec![ClaudeExchange { prompt: "a".into(), answer: "b".into() }];
        let text = prompt("go", &history);
        assert!(text.starts_with("<earlier_conversation>\nFor reference: the user's earlier requests in this conversation (sent by voice from their iPhone)"));
        assert!(text.contains("\n\n[1] User: a\nYou concluded: b\n</earlier_conversation>\n\ngo"));
    }

    #[test]
    fn only_the_same_record_in_the_same_folder_continues() {
        let conversation = |record: Option<&str>, session: Option<&str>| Conversation {
            folder: "/a".into(),
            record: record.map(String::from),
            session: session.map(String::from),
        };
        let one = conversation(Some("r1"), Some("s1"));
        assert_eq!(one.session_for("/a", Some("r1")), Some("s1".into()));
        assert_eq!(one.session_for("/a", Some("r2")), None);
        assert_eq!(one.session_for("/b", Some("r1")), None);
        assert_eq!(one.session_for("/a", None), None);
        // Older phones send no record: the folder alone decides, as before.
        assert_eq!(conversation(None, Some("s1")).session_for("/a", None), Some("s1".into()));
        // No run of it got as far as a session: nothing to continue.
        assert_eq!(conversation(Some("r1"), None).session_for("/a", Some("r1")), None);
    }
}
