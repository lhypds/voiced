//! Shows the Claude Code runs of Run-mode sentences in a terminal window this service opens. The
//! runner runs Claude Code itself; the window only follows each run's events
//! (`voiced --claude-follow`, see transcript.rs), as ~/code/tm's run windows do.
//!
//! The first run opens a window in its folder; a later one is followed in the same window once the
//! one before is over. Once the last is over the window counts down three seconds and closes by
//! itself; the next run opens a new one. A run in another folder opens a new window too.
//!
//! macOS drives Terminal through AppleScript (mac.rs); Windows gives each window its own console,
//! which is the follow process's (windows.rs).

#[cfg(target_os = "macos")]
mod mac;
#[cfg(target_os = "macos")]
pub use mac::Terminal;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::Terminal;

#[cfg(not(any(target_os = "macos", windows)))]
mod none {
    use std::path::Path;
    #[derive(Default)]
    pub struct Terminal;
    impl Terminal {
        pub fn follow(&mut self, _log: &Path, _sentence: &str, _folder: &str) {}
        pub fn tick(&mut self) {}
        pub fn close_for_shutdown(&mut self) {}
    }
}
#[cfg(not(any(target_os = "macos", windows)))]
pub use none::Terminal;

const PERMISSION_MODES: [&str; 6] = ["default", "acceptEdits", "auto", "plan", "dontAsk", "bypassPermissions"];

/// What Claude may do without asking: `acceptEdits` unless set otherwise, by the environment
/// variable VOICED_PERMISSION_MODE or, on macOS, by
/// `defaults write com.local.voiced.input claudePermissionMode <mode>`. Read for every run.
pub fn permission_mode() -> String {
    let mode = std::env::var("VOICED_PERMISSION_MODE").unwrap_or_default();
    #[cfg(target_os = "macos")]
    let mode = if mode.is_empty() {
        std::process::Command::new("/usr/bin/defaults")
            .args(["read", "com.local.voiced.input", "claudePermissionMode"])
            .output()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .unwrap_or(mode)
    } else {
        mode
    };
    if PERMISSION_MODES.contains(&mode.as_str()) { mode } else { "acceptEdits".into() }
}

/// This binary, as the follow command runs it.
pub fn executable() -> std::path::PathBuf {
    std::env::current_exe()
        .and_then(|path| path.canonicalize())
        .unwrap_or_else(|_| std::path::PathBuf::from(std::env::args().next().unwrap_or_else(|| "voiced".into())))
}
