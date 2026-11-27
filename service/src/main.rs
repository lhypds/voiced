// On Windows the service runs without a console window, its icon in the notification area being
// all there is to see; a run's window asks for a console of its own (transcript.rs).
#![cfg_attr(windows, windows_subsystem = "windows")]

//! voiced: waits for the iPhone app's connections and delivers every sentence it sends the way the
//! phone says (its "Send to Mac" mode): typed at the cursor of the focused app, such as a terminal
//! prompt; typed there and followed by Return; or carried out by Claude Code, shown in a terminal
//! window. Runs on its own, without the Voiced window. While it runs, an icon in the menu bar or
//! notification area shows its status.
//!
//! Runs on macOS and Windows; it replaced an earlier Swift service.
//!
//! Usage: voiced
//!        voiced --claude-follow <file> <sentence>   (the terminal window of a run)
//!
//! Threads: the main thread runs the icon's event loop; the core thread owns the runner and the
//! connections and handles everything else, one event at a time, as the Swift service does on its
//! main actor; small threads read sockets and claude's output and send what they read to it.

mod listener;
mod log;
mod protocol;
mod runner;
mod shell;
mod terminal;
mod transcript;
mod tray;
mod typer;

use std::collections::HashMap;
use std::path::Path;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use chrono::{DateTime, Local};

use protocol::{Incoming, Mode};
use runner::Runner;
use shell::ShellEnv;

const USAGE: &str = "Usage: voiced";

/// What the core thread is told.
pub enum Event {
    Connected { id: u64, peer: String, send: Sender<Vec<u8>> },
    Received { lines: Vec<Incoming> },
    Disconnected { id: u64 },
    ShellReady { run: String, continuing: bool, environment: Option<ShellEnv> },
    ClaudeLine { run: String, line: String },
    ClaudeStderr { run: String, line: String },
    ClaudeExited { run: String, status: String },
    Shutdown,
}

#[derive(Clone, Debug)]
pub enum ListenerState {
    Starting,
    Listening(u16),
    Failed(String),
}

/// What the icon's menu shows about the running service.
#[derive(Clone, Debug)]
pub struct Status {
    pub listener: ListenerState,
    pub name: String,
    pub connections: usize,
    pub accessibility_allowed: bool,
    pub sentences_typed: usize,
    pub last_sentence_at: Option<DateTime<Local>>,
    /// Why the latest sentence could not be delivered; cleared by the next one that is.
    pub delivery_error: Option<String>,
    pub started_at: DateTime<Local>,
}

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    // A run's terminal window follows its events with this binary to print them.
    if arguments.get(1).map(String::as_str) == Some("--claude-follow") && arguments.len() >= 3 {
        transcript::follow(&arguments[2], arguments.get(3).map(String::as_str).unwrap_or(""));
    }
    for argument in &arguments[1..] {
        match argument.as_str() {
            "-h" | "--help" => {
                println!("{USAGE}");
                return;
            }
            _ => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        }
    }

    if !typer::request_access() {
        log!("Waiting for the Accessibility permission: allow voiced in System Settings → Privacy & Security → Accessibility. Sentences received until then are dropped.");
    }
    let status = Arc::new(Mutex::new(Status {
        listener: ListenerState::Starting,
        name: listener::computer_name(),
        connections: 0,
        accessibility_allowed: typer::is_trusted(),
        sentences_typed: 0,
        last_sentence_at: None,
        delivery_error: None,
        started_at: Local::now(),
    }));

    let (events, inbox) = mpsc::channel();
    let runner = Runner::new(events.clone());
    let advertisement = match listener::start(events.clone()) {
        Ok((port, advertisement)) => {
            status.lock().unwrap().listener = ListenerState::Listening(port);
            advertisement
        }
        // launchd starts the service again after it exits, so a failed listener is not retried here.
        Err(error) => {
            log!("Cannot listen: {error}");
            std::process::exit(1);
        }
    };

    {
        let status = status.clone();
        thread::spawn(move || core(inbox, runner, status, advertisement));
    }

    // launchd stops the service with SIGTERM (voiced stop, voiced restart); Ctrl-C or closing the
    // console does on Windows. Runs' claude would be left running with no one reading it, and
    // their window open: both end first.
    let shutdown = events.clone();
    let _ = ctrlc::set_handler(move || {
        let _ = shutdown.send(Event::Shutdown);
    });
    tray::run(status, move || {
        let _ = events.send(Event::Shutdown);
    });
}

fn core(inbox: Receiver<Event>, mut runner: Runner, status: Arc<Mutex<Status>>, advertisement: listener::Advertisement) {
    let mut connections: HashMap<u64, (String, Sender<Vec<u8>>)> = HashMap::new();
    loop {
        let event = match inbox.recv_timeout(Duration::from_millis(100)) {
            Ok(event) => Some(event),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        };
        match event {
            None => {}
            Some(Event::Connected { id, peer, send }) => {
                let _ = send.send(runner.snapshot().encode());
                connections.insert(id, (peer.clone(), send));
                log!("Connected: {peer} ({} open)", connections.len());
                status.lock().unwrap().connections = connections.len();
            }
            Some(Event::Disconnected { id }) => {
                if let Some((peer, _)) = connections.remove(&id) {
                    log!("Disconnected: {peer} ({} open)", connections.len());
                    status.lock().unwrap().connections = connections.len();
                }
            }
            Some(Event::Received { lines }) => {
                for line in lines {
                    match line {
                        Incoming::Sentence(message) => deliver(message, &mut runner, &status),
                        Incoming::Command(command) => runner.handle(command),
                    }
                }
            }
            Some(Event::ShellReady { run, continuing, environment }) => runner.shell_ready(&run, continuing, environment),
            Some(Event::ClaudeLine { run, line }) => runner.received(&run, line),
            Some(Event::ClaudeStderr { run, line }) => runner.received_stderr(&run, line),
            Some(Event::ClaudeExited { run, status }) => runner.exited(&run, status),
            Some(Event::Shutdown) => {
                runner.stop_all();
                runner.terminal.close_for_shutdown();
                advertisement.stop();
                std::process::exit(0);
            }
        }
        runner.terminal.tick();
        for event in runner.outbox.drain(..) {
            let data = event.encode();
            for (_, send) in connections.values() {
                let _ = send.send(data.clone());
            }
        }
    }
}

fn deliver(message: protocol::Message, runner: &mut Runner, status: &Arc<Mutex<Status>>) {
    let error = match message.mode {
        Mode::Type | Mode::TypeAndReturn => {
            if typer::is_trusted() {
                let press_return = message.mode == Mode::TypeAndReturn;
                typer::type_text(&protocol::typed_text(&message.text, press_return), press_return);
                None
            } else {
                Some("Dropped a sentence: no Accessibility permission".to_string())
            }
        }
        Mode::Claude => {
            // A prompt is always sent, so it gets no trailing space and always Return. The folder
            // is set on the phone and comes with the sentence.
            let folder = message.resolved_folder();
            if Path::new(&folder).is_dir() {
                let folder = folder.to_string_lossy().into_owned();
                runner.start(message.text, folder, message.line, message.history.unwrap_or_default());
                None
            } else {
                Some(format!("Dropped a sentence: {} is not a folder", folder.display()))
            }
        }
    };
    let mut status = status.lock().unwrap();
    match error {
        Some(error) => {
            log!("{error}");
            status.delivery_error = Some(error);
        }
        None => {
            status.delivery_error = None;
            status.sentences_typed += 1;
            status.last_sentence_at = Some(Local::now());
        }
    }
}
