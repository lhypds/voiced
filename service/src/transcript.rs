//! The terminal window of a Run-mode sentence: follows the run's events, which the runner writes
//! to a file as `claude -p --output-format stream-json --verbose --include-partial-messages` gives
//! them, and prints them as ~/code/tm's run windows do: a header with the folder, model and
//! permission mode, the sentence as the title, Claude's text as it is written, each tool call
//! with its first line beside the name and its result under it, a note while a tool waits for the
//! iPhone's answer, then how long the run took and how it ended. The file is removed once the run
//! is over.
//!
//!   voiced --claude-follow <file> '<sentence>'
//!
//! Once a run is over the window counts down to closing. The marker file `<file>.next` stops the
//! countdown: empty, the window is left to its shell (macOS, where Terminal is then told to follow
//! the next run); holding another run's file and sentence, on two lines, this process follows
//! that run next in the same window (Windows, where the window is this process's own console).

use std::collections::HashMap;
use std::fs;
use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;

use serde_json::{Map, Value};

const RESULT_LINES: usize = 10;
const SUMMARY_LINES: usize = 20;
/// How long the window stays after the last run before it closes.
pub const CLOSE_SECONDS: u32 = 3;

pub fn next_run_marker(log: &Path) -> PathBuf {
    let mut name = log.as_os_str().to_owned();
    name.push(".next");
    PathBuf::from(name)
}

pub fn follow(path: &str, sentence: &str) -> ! {
    #[cfg(windows)]
    enable_console();
    let mut printer = Printer::default();
    printer.line(&format!("{} {}", bold(&green("voiced")), dim("Claude Code")));
    let mut current = (PathBuf::from(path), sentence.to_string());
    loop {
        let (path, sentence) = &current;
        if !follow_one(&mut printer, path, sentence) {
            // The file went away: the service was stopped or restarted.
            std::process::exit(0);
        }
        let _ = fs::remove_file(path);
        match count_down(&next_run_marker(path)) {
            Some(next) => {
                printer.gap();
                current = next;
            }
            None => std::process::exit(0),
        }
    }
}

/// Prints one run. True once it is over, false when its file went away first.
fn follow_one(printer: &mut Printer, path: &Path, sentence: &str) -> bool {
    let mut reader = LineFollower { path: path.to_path_buf(), file: None, buffer: Vec::new() };
    let mut tools: HashMap<String, (String, String)> = HashMap::new();
    let mut last_tool: Option<String> = None;
    let mut streamed_text = false;
    let mut started = false;

    while let Some(raw) = reader.next() {
        let Ok(Value::Object(message)) = serde_json::from_str::<Value>(&raw) else {
            // Not an event: claude printed something else, such as an error. Show it as it is.
            printer.line(&raw);
            continue;
        };
        // Subagents' own messages: the main agent's tool call stands for them, as in tm.
        if message.get("parent_tool_use_id").is_some_and(Value::is_string) {
            continue;
        }
        let kind = str_of(&message, "type");
        match kind {
            "system" if str_of(&message, "subtype") == "init" => {
                printer.field("folder", str_of(&message, "cwd"));
                if let Some(model) = message.get("model").and_then(Value::as_str) {
                    printer.field("model", model);
                }
                if let Some(mode) = message.get("permissionMode").and_then(Value::as_str) {
                    printer.field("permission mode", mode);
                }
                printer.field("started", &chrono::Local::now().format("%Y/%m/%d %H:%M:%S").to_string());
                printer.gap();
                printer.line(&bold(&format!("Claude: {sentence}")));
                started = true;
            }
            "stream_event" => {
                let Some(event) = message.get("event").and_then(Value::as_object) else { continue };
                match str_of(event, "type") {
                    "message_start" => streamed_text = false,
                    "content_block_start" => {
                        if event.get("content_block").and_then(Value::as_object).map(|b| str_of(b, "type")) == Some("text") {
                            printer.gap();
                            streamed_text = true;
                        }
                    }
                    "content_block_delta" => {
                        if let Some(delta) = event.get("delta").and_then(Value::as_object) {
                            if str_of(delta, "type") == "text_delta" {
                                printer.write(str_of(delta, "text"));
                            }
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                for block in content(&message) {
                    match str_of(block, "type") {
                        "text" if !streamed_text => {
                            printer.gap();
                            printer.write(str_of(block, "text"));
                        }
                        "tool_use" => {
                            let name = non_empty(str_of(block, "name"), "tool");
                            let summary = lines(&summarize(&name, block.get("input")));
                            let head = summary.first().cloned().unwrap_or_default();
                            if let Some(id) = block.get("id").and_then(Value::as_str) {
                                tools.insert(id.into(), (name.clone(), head.clone()));
                                last_tool = Some(id.into());
                            }
                            printer.gap();
                            printer.line(&format!("{} {}  {head}", cyan("▸"), bold(&name)));
                            printer.block(&summary[summary.len().min(1)..], SUMMARY_LINES);
                        }
                        _ => {}
                    }
                }
            }
            "user" => {
                for block in content(&message).into_iter().filter(|b| str_of(b, "type") == "tool_result") {
                    let id = str_of(block, "tool_use_id");
                    let failed = block.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                    // Parallel calls finish in any order: name the tool unless it is the one just shown.
                    let label = if last_tool.as_deref() == Some(id) {
                        String::new()
                    } else {
                        tools.get(id).map(|(name, head)| format!("  {}", dim(&format!("{name}  {head}")))).unwrap_or_default()
                    };
                    printer.line(&format!("{}{label}", if failed { red("  ✗") } else { green("  ✓") }));
                    printer.block(&lines(&result_text(block.get("content"))), RESULT_LINES);
                    last_tool = None;
                }
            }
            "control_request" => {
                let Some(request) = message.get("request").and_then(Value::as_object) else { continue };
                if str_of(request, "subtype") != "can_use_tool" {
                    continue;
                }
                let name = non_empty(str_of(request, "tool_name"), "tool");
                // AskUserQuestion is answered by the service itself.
                if name == "AskUserQuestion" {
                    continue;
                }
                let head = lines(&summarize(&name, request.get("input"))).into_iter().next().unwrap_or_default();
                printer.gap();
                printer.line(&yellow(&format!("⏸ Waiting for the iPhone to allow {}  {head}", bold(&name))));
            }
            "voiced_permission" => {
                let allowed = message.get("allowed").and_then(Value::as_bool).unwrap_or(false);
                printer.line(&if allowed { green("  Allowed on the iPhone") } else { red("  Denied on the iPhone") });
            }
            "voiced_end" => {
                // The run ended without a result: claude failed, or the iPhone stopped it.
                printer.gap();
                match str_of(&message, "state") {
                    "stopped" => printer.line(&yellow("Run stopped from the iPhone.")),
                    "restarted" => printer.line(&yellow("Run stopped: voiced was restarted.")),
                    "done" => printer.line(&green("Run done.")),
                    _ if started => printer.line(&red("Run failed.")),
                    _ => printer.line(&red("Claude Code did not start.")),
                }
                return true;
            }
            "result" => {
                printer.gap();
                if message.get("is_error").and_then(Value::as_bool) == Some(true) || str_of(&message, "subtype") != "success" {
                    let detail = message
                        .get("result")
                        .and_then(Value::as_str)
                        .or_else(|| message.get("subtype").and_then(Value::as_str))
                        .unwrap_or("error");
                    printer.line(&red(&format!("✗ {detail}")));
                    printer.gap();
                    printer.line(&red("Run failed."));
                } else {
                    let mut parts = vec![duration(message.get("duration_ms").and_then(Value::as_f64).unwrap_or(0.0))];
                    if let Some(turns) = message.get("num_turns").and_then(Value::as_i64) {
                        parts.push(format!("{turns} turn{}", if turns == 1 { "" } else { "s" }));
                    }
                    printer.line(&green(&format!("✓ {}", parts.join(" · "))));
                    printer.gap();
                    printer.line(&green("Run done."));
                }
                return true;
            }
            _ => {}
        }
    }
    printer.gap();
    printer.line(&if started { yellow("Run stopped.") } else { red("Claude Code did not start.") });
    false
}

/// Counts down on one line to the window closing: the window closes as this process ends. Stops
/// at once, clearing the line, when `marker` appears; returns the run it names, if any.
fn count_down(marker: &Path) -> Option<(PathBuf, String)> {
    let clear = if color() { "\r\x1b[2K" } else { "\r" };
    let mut out = std::io::stdout();
    let _ = out.write_all(b"\n");
    for remaining in (1..=CLOSE_SECONDS).rev() {
        let _ = write!(out, "{clear}{}", dim(&format!("Closing in {remaining} s…")));
        let _ = out.flush();
        for _ in 0..10 {
            if marker.exists() {
                let contents = fs::read_to_string(marker).unwrap_or_default();
                let _ = fs::remove_file(marker);
                let _ = write!(out, "{clear}");
                let _ = out.flush();
                let mut parts = contents.splitn(2, '\n');
                let next = parts.next().unwrap_or("").trim();
                if next.is_empty() {
                    return None;
                }
                return Some((PathBuf::from(next), parts.next().unwrap_or("").to_string()));
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
    let _ = write!(out, "{clear}{}", dim("Closing…"));
    let _ = out.flush();
    None
}

/// Reads a file's lines as they are written, waiting at its end for more. Ends when the file is gone.
struct LineFollower {
    path: PathBuf,
    file: Option<fs::File>,
    buffer: Vec<u8>,
}

impl LineFollower {
    fn next(&mut self) -> Option<String> {
        loop {
            if let Some(end) = self.buffer.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=end).collect();
                return Some(String::from_utf8_lossy(&line[..end]).into_owned());
            }
            if self.file.is_none() {
                self.file = fs::File::open(&self.path).ok();
            }
            if let Some(file) = self.file.as_mut() {
                let before = self.buffer.len();
                let _ = file.read_to_end(&mut self.buffer);
                if self.buffer.len() > before {
                    continue;
                }
            }
            if !self.path.exists() {
                return None;
            }
            thread::sleep(Duration::from_millis(150));
        }
    }
}

// MARK: Shared with the runner

/// What a tool call is about, as tm's summarizeTool has it: the command of Bash, the file of an
/// edit, the pattern of a search… else the input as JSON.
pub fn summarize(name: &str, input: Option<&Value>) -> String {
    let empty = Map::new();
    let input = input.and_then(Value::as_object).unwrap_or(&empty);
    let text = |key: &str| match input.get(key) {
        None => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    };
    match name {
        "Bash" => text("command"),
        "Read" | "Write" | "Edit" | "MultiEdit" => text("file_path"),
        "NotebookEdit" => text("notebook_path"),
        "Glob" | "Grep" => [text("pattern"), text("path")].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("  in  "),
        "WebFetch" => text("url"),
        "WebSearch" => text("query"),
        "Agent" | "Task" => if input.contains_key("description") { text("description") } else { text("prompt") },
        "Skill" => if input.contains_key("skill") { text("skill") } else { text("command") },
        "ExitPlanMode" => text("plan"),
        "TodoWrite" => String::new(),
        // serde_json's maps keep their keys sorted.
        _ => serde_json::to_string(input).unwrap_or_default(),
    }
}

/// A tool result's text: a string, or the text parts of a list of content blocks.
pub fn result_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| b.as_object())
            .filter(|b| str_of(b, "type") == "text")
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

pub fn str_of<'a>(object: &'a Map<String, Value>, key: &str) -> &'a str {
    object.get(key).and_then(Value::as_str).unwrap_or("")
}

pub fn content(message: &Map<String, Value>) -> Vec<&Map<String, Value>> {
    message
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_array)
        .map(|blocks| blocks.iter().filter_map(Value::as_object).collect())
        .unwrap_or_default()
}

pub fn non_empty(value: &str, fallback: &str) -> String {
    if value.is_empty() { fallback.into() } else { value.into() }
}

fn lines(text: &str) -> Vec<String> {
    let trimmed = text.trim_end();
    if trimmed.is_empty() { Vec::new() } else { trimmed.split('\n').map(String::from).collect() }
}

fn duration(milliseconds: f64) -> String {
    let seconds = (milliseconds / 1000.0).round().max(0.0) as u64;
    if seconds < 60 { format!("{seconds}s") } else { format!("{}m {}s", seconds / 60, seconds % 60) }
}

// MARK: Output

fn color() -> bool {
    static COLOR: OnceLock<bool> = OnceLock::new();
    *COLOR.get_or_init(|| std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none())
}

fn paint(code: &str, text: &str) -> String {
    if color() { format!("\x1b[{code}m{text}\x1b[0m") } else { text.to_string() }
}
fn bold(text: &str) -> String { paint("1", text) }
fn dim(text: &str) -> String { paint("2", text) }
fn red(text: &str) -> String { paint("31", text) }
fn green(text: &str) -> String { paint("32", text) }
fn yellow(text: &str) -> String { paint("33", text) }
fn cyan(text: &str) -> String { paint("36", text) }

/// A console window of its own, since voiced.exe has none, with UTF-8 and ANSI colours. The window
/// closes as this process ends.
#[cfg(windows)]
fn enable_console() {
    use windows_sys::Win32::System::Console::{
        AllocConsole, GetConsoleMode, GetStdHandle, SetConsoleMode, SetConsoleOutputCP, SetConsoleTitleW,
        ENABLE_VIRTUAL_TERMINAL_PROCESSING, STD_OUTPUT_HANDLE,
    };
    unsafe {
        AllocConsole();
        SetConsoleOutputCP(65001);
        let title: Vec<u16> = "voiced · Claude Code".encode_utf16().chain(Some(0)).collect();
        SetConsoleTitleW(title.as_ptr());
        let handle = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut mode = 0;
        if GetConsoleMode(handle, &mut mode) != 0 {
            SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
}

/// Writes as it goes, keeping track of where the cursor is so blocks get one empty line between them.
struct Printer {
    at_line_start: bool,
    last_line_empty: bool,
    line_length: usize,
}

impl Default for Printer {
    fn default() -> Self {
        Printer { at_line_start: true, last_line_empty: true, line_length: 0 }
    }
}

impl Printer {
    fn write(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(text.as_bytes());
        let _ = out.flush();
        for character in text.chars() {
            if character == '\n' {
                self.last_line_empty = self.line_length == 0;
                self.line_length = 0;
            } else {
                self.line_length += 1;
            }
        }
        self.at_line_start = text.ends_with('\n');
    }

    fn newline(&mut self) {
        if !self.at_line_start {
            self.write("\n");
        }
    }

    fn line(&mut self, text: &str) {
        self.newline();
        self.write(&format!("{text}\n"));
    }

    fn gap(&mut self) {
        self.newline();
        if !self.last_line_empty {
            self.write("\n");
        }
    }

    fn field(&mut self, label: &str, value: &str) {
        self.line(&format!("{} {value}", dim(&format!("{label}:"))));
    }

    /// Lines under a heading: `max` at most, indented and dim.
    fn block(&mut self, all: &[String], max: usize) {
        for text in all.iter().take(max) {
            self.line(&dim(&format!("    {text}")));
        }
        if all.len() > max {
            self.line(&dim(&format!("    … {} more lines", all.len() - max)));
        }
    }
}
