//! Terminal.app, driven through AppleScript, so Run mode needs no Accessibility permission.

use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use crate::log;
use crate::transcript::next_run_marker;

struct Session {
    window: i64,
    folder: String,
}

#[derive(Default)]
pub struct Terminal {
    session: Option<Session>,
    /// Follow commands waiting for the one before them to finish, oldest first, with their logs.
    queue: VecDeque<(String, PathBuf)>,
    /// The log of the run the window follows, or followed last.
    current_log: Option<PathBuf>,
    /// While the window is watched: when it was last looked at.
    watching: Option<Instant>,
}

impl Terminal {
    /// Follows the run whose events go to `log` in the window, opening one in `folder` when there
    /// is none for it. A window that cannot be opened is only logged: the run goes on.
    pub fn follow(&mut self, log_path: &Path, sentence: &str, folder: &str) {
        let command = follow_command(log_path, sentence);
        if let Some(session) = &self.session {
            if session.folder == folder && window_exists(session.window) {
                self.queue.push_back((command, log_path.to_path_buf()));
                // The run before may be counting down to closing the window: it stops.
                if let Some(current) = &self.current_log {
                    let _ = fs::write(next_run_marker(current), "");
                }
                self.watch();
                return;
            }
        }

        // A new window; anything queued for an old one in another folder is dropped.
        self.queue.clear();
        self.watching = None;
        let shell_command = format!("cd {} && {command}", shell_quoted(folder));
        let Ok(value) = run(&format!(
            "tell application \"Terminal\"\n    activate\n    do script {}\n    return id of front window\nend tell",
            apple_script_quoted(&shell_command)
        )) else {
            return;
        };
        let Some(window) = value.parse::<i64>().ok().filter(|&id| id != 0) else {
            log!("Terminal did not open a window");
            return;
        };
        self.session = Some(Session { window, folder: folder.to_string() });
        self.current_log = Some(log_path.to_path_buf());
        log!("Following the run in Terminal window {window}");
        self.watch();
    }

    fn watch(&mut self) {
        if self.watching.is_none() {
            self.watching = Some(Instant::now());
        }
    }

    /// Called often by the core thread. Every half second while the window is watched: runs each
    /// queued follow command once the one before it has finished, and closes the window once the
    /// last run's follow command has counted down and ended with nothing else come in meanwhile.
    pub fn tick(&mut self) {
        let Some(last) = self.watching else { return };
        // Terminal reports the tab busy only once a command has started.
        if last.elapsed() < Duration::from_millis(500) {
            return;
        }
        self.watching = Some(Instant::now());
        let Some(window) = self.session.as_ref().map(|s| s.window).filter(|&w| window_exists(w)) else {
            self.session = None;
            self.queue.clear();
            self.watching = None;
            return;
        };
        if is_busy(window) {
            return;
        }
        if let Some((command, log_path)) = self.queue.pop_front() {
            if let Some(current) = &self.current_log {
                let _ = fs::remove_file(next_run_marker(current));
            }
            self.current_log = Some(log_path);
            if let Err(error) = run(&format!(
                "tell application \"Terminal\"\n    do script {} in selected tab of window id {window}\n    set index of window id {window} to 1\n    activate\nend tell",
                apple_script_quoted(&command)
            )) {
                log!("Could not follow the run in Terminal: {error}");
                self.queue.clear();
            }
            return;
        }
        // A tab can look idle before its command has started; the follow command removes its
        // run's log as it finishes, before counting down.
        if self.current_log.as_ref().is_some_and(|log| log.exists()) {
            return;
        }
        // Everything is over and the follow command has counted down: close the window.
        let _ = run(&format!("tell application \"Terminal\" to if exists window id {window} then close window id {window}"));
        log!("Closed Terminal window {window}");
        self.session = None;
        self.watching = None;
    }

    /// The service is stopping and no one will be left to close the window: once the runner has
    /// ended the run, its follow command ends without counting down, and the window is closed.
    pub fn close_for_shutdown(&mut self) {
        self.watching = None;
        self.queue.clear();
        let Some(session) = self.session.take() else { return };
        if let Some(current) = &self.current_log {
            // Skips the follow command's countdown; it removes the log as it ends.
            let marker = next_run_marker(current);
            let _ = fs::write(&marker, "");
            let deadline = Instant::now() + Duration::from_secs(2);
            while current.exists() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(50));
            }
            thread::sleep(Duration::from_millis(200));
            let _ = fs::remove_file(marker);
        }
        // A window still running something would ask before closing; it is left open then.
        if !window_exists(session.window) || is_busy(session.window) {
            return;
        }
        let _ = run(&format!("tell application \"Terminal\" to close window id {}", session.window));
        log!("Closed Terminal window {}: the service is stopping", session.window);
    }
}

/// This binary, printing the run's events as they are written.
fn follow_command(log_path: &Path, sentence: &str) -> String {
    format!(
        "{} --claude-follow {} {}",
        shell_quoted(&super::executable().to_string_lossy()),
        shell_quoted(&log_path.to_string_lossy()),
        shell_quoted(sentence)
    )
}

/// Whether the window is still open. A closed window can linger in Terminal's scripting for a
/// while, invisible and without tabs: that counts as closed.
fn window_exists(window: i64) -> bool {
    run(&format!(
        "tell application \"Terminal\"\n    if not (exists window id {window}) then return false\n    return (visible of window id {window}) and ((count of tabs of window id {window}) > 0)\nend tell"
    ))
    .is_ok_and(|value| value == "true")
}

/// Whether the window's tab runs something besides its shell: a run of Claude Code.
fn is_busy(window: i64) -> bool {
    run(&format!(
        "tell application \"Terminal\"\n    if not (exists window id {window}) then return false\n    return busy of selected tab of window id {window}\nend tell"
    ))
    .is_ok_and(|value| value == "true")
}

fn run(source: &str) -> Result<String, String> {
    let output = Command::new("/usr/bin/osascript").arg("-e").arg(source).output().map_err(|e| e.to_string())?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
    }
    let message = format!("Terminal: {}", String::from_utf8_lossy(&output.stderr).trim());
    log!("{message}");
    Err(message)
}

fn shell_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn apple_script_quoted(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}
