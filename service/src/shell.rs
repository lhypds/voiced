//! Where `claude` is, and the environment to run it in.
//!
//! macOS: launchd starts the service with a bare PATH that rarely has claude, so both come from
//! the user's login shell, as the Terminal window would have them. Windows: a program started at
//! login already has the user's PATH; claude is looked up on it and in the native installer's
//! folder, %USERPROFILE%\.local\bin.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Clone, Debug)]
pub struct ShellEnv {
    pub claude: PathBuf,
    pub environment: HashMap<String, String>,
}

static CACHED: Mutex<Option<ShellEnv>> = Mutex::new(None);

/// Found once, then kept; not found is asked again next time.
pub fn environment() -> Option<ShellEnv> {
    if let Some(cached) = CACHED.lock().unwrap().clone() {
        return Some(cached);
    }
    let found = find()?;
    *CACHED.lock().unwrap() = Some(found.clone());
    Some(found)
}

#[cfg(unix)]
fn find() -> Option<ShellEnv> {
    use std::process::{Command, Stdio};
    let marker = "__voiced_path__";
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    // Interactive too: PATH is often extended in .zshrc. Its output may come first, so the answer
    // follows a marker.
    let output = Command::new(shell)
        .args(["-ilc", &format!("printf '%s' \"{marker}$(command -v claude){marker}$PATH\"")])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<&str> = text.split(marker).collect();
    if parts.len() < 3 {
        return None;
    }
    let claude = parts[1].trim();
    if !claude.starts_with('/') {
        return None;
    }
    let mut environment: HashMap<String, String> = std::env::vars().collect();
    environment.insert("PATH".into(), parts[2].trim().into());
    Some(ShellEnv { claude: PathBuf::from(claude), environment })
}

#[cfg(windows)]
fn find() -> Option<ShellEnv> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut folders: Vec<PathBuf> = std::env::split_paths(&path).collect();
    folders.push(crate::protocol::home_dir().join(".local").join("bin"));
    let claude = folders.iter().find_map(|folder| {
        ["claude.exe", "claude.cmd", "claude.bat"].iter().map(|name| folder.join(name)).find(|file| file.is_file())
    })?;
    Some(ShellEnv { claude, environment: std::env::vars().collect() })
}
