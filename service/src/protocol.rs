//! The wire format the iPhone app speaks, as defined by `PhoneInput` and `ClaudeRunEvents` in
//! core/VoicedCore/Sources/VoicedCore/PhoneInput: the computer advertises `SERVICE_TYPE` over
//! Bonjour and every sentence arrives as one JSON object on a line of its own; events for the
//! Claude Code runs go back down the same connection the same way. Keep in step with VoicedCore.

use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SERVICE_TYPE: &str = "_voiced-input._tcp.local.";

/// What to do with a sentence, chosen on the phone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Typed at the cursor and left there.
    Type,
    /// Typed at the cursor and followed by Return.
    TypeAndReturn,
    /// Carried out by Claude Code.
    Claude,
}

#[derive(Clone, Debug)]
pub struct Message {
    pub text: String,
    /// Missing from phones older than the modes, and unknown for modes added later: both are
    /// typed at the cursor.
    pub mode: Mode,
    /// The folder Claude Code runs in, for `claude`; `~` stands for the home folder.
    pub folder: Option<String>,
    /// The phone's id for the transcript line the sentence is, so a run shows under it there.
    pub line: Option<String>,
    /// For `claude`: the phone's id for the record the sentence is in. A sentence of another
    /// record starts a new conversation. Missing from older phones.
    pub record: Option<String>,
    /// For `claude`: the earlier requests of the same record and what Claude concluded.
    pub history: Option<Vec<ClaudeExchange>>,
}

impl Message {
    /// A line that is a sentence: it has `text`. Everything else is lenient, as on the phone.
    fn decode(object: &serde_json::Map<String, Value>) -> Option<Message> {
        let text = object.get("text")?.as_str()?.to_string();
        let mode = match object.get("mode").and_then(Value::as_str) {
            Some("typeAndReturn") => Mode::TypeAndReturn,
            Some("claude") => Mode::Claude,
            _ => Mode::Type,
        };
        let string = |key: &str| object.get(key).and_then(Value::as_str).map(String::from);
        let history = object.get("history").and_then(|h| serde_json::from_value(h.clone()).ok());
        Some(Message { text, mode, folder: string("folder"), line: string("line"), record: string("record"), history })
    }

    /// `folder` as a path here: `~` expanded, the home folder when none was sent, and
    /// normalized so `~/` and `~` are the same folder and continue one conversation.
    pub fn resolved_folder(&self) -> PathBuf {
        let trimmed = self.folder.as_deref().unwrap_or("").trim();
        let home = home_dir();
        if trimmed.is_empty() || trimmed == "~" {
            return home;
        }
        let path = match trimmed.strip_prefix("~/").or_else(|| trimmed.strip_prefix("~\\")) {
            Some(rest) => home.join(rest),
            None => PathBuf::from(trimmed),
        };
        normalize(&path)
    }
}

pub fn home_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// `.` and `..` resolved and a trailing separator dropped, without touching the disk.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() && !out.has_root() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// An earlier request sent with Run and what Claude concluded.
#[derive(Clone, Debug, Deserialize)]
pub struct ClaudeExchange {
    pub prompt: String,
    pub answer: String,
}

/// What the phone asks of a run: stop it, or answer the tool it is waiting on.
#[derive(Clone, Debug, Deserialize)]
pub struct RunCommand {
    pub command: CommandAction,
    pub run: String,
    /// `allow`, `deny`: the pending request answered.
    pub pending: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CommandAction {
    Stop,
    Allow,
    Deny,
}

/// A line from the phone: a sentence, or a command for a Claude Code run.
#[derive(Clone, Debug)]
pub enum Incoming {
    Sentence(Message),
    Command(RunCommand),
}

/// Collects received bytes and hands back the lines completed by them. A line split across reads
/// waits in the buffer for its end; a line that is neither is dropped.
#[derive(Default)]
pub struct LineDecoder {
    buffer: Vec<u8>,
}

impl LineDecoder {
    pub fn feed(&mut self, data: &[u8]) -> Vec<Incoming> {
        self.buffer.extend_from_slice(data);
        let mut incoming = Vec::new();
        while let Some(end) = self.buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=end).collect();
            let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&line[..end]) else { continue };
            // A command has no text, so it never decodes as a sentence.
            if let Some(message) = Message::decode(&object) {
                incoming.push(Incoming::Sentence(message));
            } else if let Ok(command) = serde_json::from_value::<RunCommand>(Value::Object(object)) {
                incoming.push(Incoming::Command(command));
            }
        }
        incoming
    }
}

/// What is typed for a received sentence. Sentences typed one after another must not run
/// together: one ending in a Latin letter or ASCII punctuation is followed by a space, while
/// Chinese and Japanese, written without spaces, are typed as they are. Nothing is added when
/// Return follows, which ends the line anyway.
pub fn typed_text(text: &str, presses_return: bool) -> String {
    let trimmed = text.trim();
    match trimmed.chars().last() {
        Some(last) if !presses_return && last.is_ascii() => format!("{trimmed} "),
        _ => trimmed.to_string(),
    }
}

// MARK: Run events

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunState {
    /// Waiting for the run before it to finish.
    Queued,
    Running,
    Done,
    Failed,
    Stopped,
}

impl RunState {
    pub fn is_going(self) -> bool {
        matches!(self, RunState::Queued | RunState::Running)
    }

    pub fn name(self) -> &'static str {
        match self {
            RunState::Queued => "queued",
            RunState::Running => "running",
            RunState::Done => "done",
            RunState::Failed => "failed",
            RunState::Stopped => "stopped",
        }
    }
}

/// A tool Claude wants to use and may not without asking: the phone allows or denies it.
#[derive(Clone, Debug, Serialize)]
pub struct Pending {
    pub id: String,
    pub tool: String,
    pub summary: String,
}

/// One run of Claude Code for one sentence.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeRun {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<String>,
    pub text: String,
    pub folder: String,
    pub state: RunState,
    /// Seconds since 1970.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending: Option<Pending>,
    /// Left out of `run` events, which carry only the state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub items: Option<Vec<RunItem>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemKind {
    /// Claude's text, written as it streams.
    Text,
    /// A tool call, `done` once its result is in.
    Tool,
    /// How the run ended.
    Result,
    /// Something went wrong outside Claude, such as claude not starting.
    Error,
}

/// One entry of a run's transcript.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunItem {
    pub kind: ItemKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub done: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns: Option<i64>,
}

impl RunItem {
    pub fn new(kind: ItemKind) -> RunItem {
        RunItem {
            kind,
            text: None,
            name: None,
            summary: None,
            done: None,
            is_error: None,
            result: None,
            duration_ms: None,
            turns: None,
        }
    }
}

/// One event for the phones: `snapshot` of every run kept, `run` for a run's state, `item` for a
/// transcript item added or replaced at an index, `delta` for text appended to one, `remove` for
/// a run no longer kept.
#[derive(Clone, Debug, Serialize)]
pub struct RunEvent {
    #[serde(rename = "type")]
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runs: Option<Vec<ClaudeRun>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run: Option<ClaudeRun>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub i: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item: Option<RunItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

impl RunEvent {
    fn empty(kind: &'static str) -> RunEvent {
        RunEvent { kind, runs: None, run: None, id: None, i: None, item: None, text: None }
    }

    pub fn snapshot(runs: Vec<ClaudeRun>) -> RunEvent {
        RunEvent { runs: Some(runs), ..RunEvent::empty("snapshot") }
    }

    pub fn state(run: ClaudeRun) -> RunEvent {
        RunEvent { run: Some(run), ..RunEvent::empty("run") }
    }

    pub fn item(id: &str, i: usize, item: RunItem) -> RunEvent {
        RunEvent { id: Some(id.into()), i: Some(i), item: Some(item), ..RunEvent::empty("item") }
    }

    pub fn delta(id: &str, i: usize, text: &str) -> RunEvent {
        RunEvent { id: Some(id.into()), i: Some(i), text: Some(text.into()), ..RunEvent::empty("delta") }
    }

    pub fn remove(id: &str) -> RunEvent {
        RunEvent { id: Some(id.into()), ..RunEvent::empty("remove") }
    }

    /// The bytes sent for the event: its JSON, ended by a line feed.
    pub fn encode(&self) -> Vec<u8> {
        let mut data = serde_json::to_vec(self).unwrap_or_default();
        data.push(b'\n');
        data
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_sentences_and_commands_across_reads() {
        let mut decoder = LineDecoder::default();
        assert!(decoder.feed(br#"{"text":"hi","mo"#).is_empty());
        let lines = decoder.feed(b"de\":\"claude\",\"folder\":\"~/code\"}\n{\"command\":\"stop\",\"run\":\"ab\"}\nnot json\n");
        assert_eq!(lines.len(), 2);
        match &lines[0] {
            Incoming::Sentence(m) => {
                assert_eq!(m.mode, Mode::Claude);
                assert_eq!(m.resolved_folder(), home_dir().join("code"));
            }
            _ => panic!(),
        }
        assert!(matches!(&lines[1], Incoming::Command(c) if c.command == CommandAction::Stop && c.run == "ab"));
    }

    #[test]
    fn unknown_mode_is_typed() {
        let mut decoder = LineDecoder::default();
        let lines = decoder.feed(b"{\"text\":\"x\",\"mode\":\"later\",\"history\":5}\n");
        assert!(matches!(&lines[0], Incoming::Sentence(m) if m.mode == Mode::Type && m.history.is_none()));
    }

    #[test]
    fn folders_resolve() {
        let m = |f: &str| Message { text: String::new(), mode: Mode::Claude, folder: Some(f.into()), line: None, record: None, history: None };
        assert_eq!(m(" ~ ").resolved_folder(), home_dir());
        assert_eq!(m("~/").resolved_folder(), home_dir());
        assert_eq!(m("/a/./b/../c/").resolved_folder(), PathBuf::from("/a/c"));
    }

    #[test]
    fn typed_text_spacing() {
        assert_eq!(typed_text(" hello. ", false), "hello. ");
        assert_eq!(typed_text("hello", true), "hello");
        assert_eq!(typed_text("你好。", false), "你好。");
    }

    #[test]
    fn events_leave_out_missing_fields() {
        let json = String::from_utf8(RunEvent::delta("r", 2, "x").encode()).unwrap();
        assert_eq!(json, "{\"type\":\"delta\",\"id\":\"r\",\"i\":2,\"text\":\"x\"}\n");
    }
}
