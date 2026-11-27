//! The service's log: a timestamped line on stdout, which launchd sends to
//! ~/Library/Logs/VoicedInput.log on macOS. Windows has no launchd to redirect it, so there each
//! line also goes to %LOCALAPPDATA%\voiced\voiced.log.

use std::io::Write;

pub fn log(message: &str) {
    let line = format!("[{}] {message}\n", chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"));
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(line.as_bytes());
    let _ = out.flush();
    #[cfg(windows)]
    if let Some(folder) = dirs::data_local_dir().map(|d| d.join("voiced")) {
        let _ = std::fs::create_dir_all(&folder);
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(folder.join("voiced.log")) {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => { $crate::log::log(&format!($($arg)*)) };
}
