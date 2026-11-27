//! A console window of its own for each follow process: it opens with the process (which asks for
//! it, see transcript.rs) and closes as the process ends. A later run in the same folder is handed to the process still counting down
//! through its marker file, so it is followed in the same window.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

use crate::log;
use crate::transcript::next_run_marker;

struct Session {
    child: Child,
    folder: String,
    /// The log of the run the window follows, or will follow next.
    log: PathBuf,
}

/// A run handed to the window through a marker, until the window takes it.
struct Handoff {
    marker: PathBuf,
    log: PathBuf,
    sentence: String,
    folder: String,
}

#[derive(Default)]
pub struct Terminal {
    session: Option<Session>,
    handoff: Option<Handoff>,
}

impl Terminal {
    pub fn follow(&mut self, log_path: &Path, sentence: &str, folder: &str) {
        if let Some(session) = &mut self.session {
            if session.folder == folder && matches!(session.child.try_wait(), Ok(None)) {
                let marker = next_run_marker(&session.log);
                let contents = format!("{}\n{sentence}", log_path.display());
                if fs::write(&marker, contents).is_ok() {
                    session.log = log_path.to_path_buf();
                    self.handoff = Some(Handoff { marker, log: log_path.to_path_buf(), sentence: sentence.into(), folder: folder.into() });
                    return;
                }
            }
        }
        self.open(log_path, sentence, folder);
    }

    fn open(&mut self, log_path: &Path, sentence: &str, folder: &str) {
        self.handoff = None;
        let child = Command::new(super::executable())
            .arg("--claude-follow")
            .arg(log_path)
            .arg(sentence)
            .current_dir(folder)
            .spawn();
        match child {
            Ok(child) => {
                log!("Following the run in a console window (process {})", child.id());
                self.session = Some(Session { child, folder: folder.into(), log: log_path.to_path_buf() });
            }
            Err(error) => log!("Could not open a console window: {error}"),
        }
    }

    /// A window that ended its countdown just as a run was handed to it never took the run: the
    /// run gets a window of its own.
    pub fn tick(&mut self) {
        let ended = match &mut self.session {
            Some(session) => !matches!(session.child.try_wait(), Ok(None)),
            None => return,
        };
        if let Some(handoff) = &self.handoff {
            if !handoff.marker.exists() {
                self.handoff = None;
            } else if ended {
                let handoff = self.handoff.take().unwrap();
                let _ = fs::remove_file(&handoff.marker);
                self.open(&handoff.log, &handoff.sentence, &handoff.folder);
                return;
            }
        }
        if ended && self.handoff.is_none() {
            self.session = None;
        }
    }

    /// The service is stopping: the window's follow process ends without counting down.
    pub fn close_for_shutdown(&mut self) {
        self.handoff = None;
        let Some(mut session) = self.session.take() else { return };
        let marker = next_run_marker(&session.log);
        let _ = fs::write(&marker, "");
        let deadline = Instant::now() + Duration::from_secs(2);
        while matches!(session.child.try_wait(), Ok(None)) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
        }
        let _ = session.child.kill();
        let _ = fs::remove_file(marker);
    }
}
