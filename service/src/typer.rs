//! Types text into whichever app has the keyboard focus, as if pasted there by the user.
//!
//! The text goes through the clipboard and a paste shortcut (Command-V on macOS, Ctrl+V on
//! Windows) rather than as synthesized key strokes: an active Chinese or Japanese input method
//! would catch key strokes and compose them again, while a paste arrives as it is in any app,
//! terminals included. The clipboard's previous text is put back once the paste has been read,
//! unless something else has replaced it meanwhile.
//!
//! Unlike the Swift service, only the clipboard's text is saved and put back: an image or file
//! copied before a sentence arrives is lost.
//!
//! Posting key events to other apps needs the Accessibility permission on macOS.

use std::sync::Mutex;
use std::thread;
use std::time::Duration;

/// How long the focused app gets to read the clipboard before it is restored.
const RESTORE_DELAY: Duration = Duration::from_millis(500);
/// How long a terminal gets to take in a paste before Return follows it.
const RETURN_DELAY: Duration = Duration::from_millis(150);

struct State {
    /// The clipboard's text as it was before the first of a run of pastes (None inside: it held no
    /// text). A sentence arriving while the previous one's restore is pending must not save that
    /// sentence as the clipboard to restore.
    original: Option<Option<String>>,
    /// The latest paste: its number and its text.
    pasted: u64,
    pasted_text: String,
}

static STATE: Mutex<State> = Mutex::new(State { original: None, pasted: 0, pasted_text: String::new() });

pub fn type_text(text: &str, press_return: bool) {
    if text.is_empty() {
        return;
    }
    let Ok(mut clipboard) = arboard::Clipboard::new() else {
        crate::log!("Cannot open the clipboard");
        return;
    };
    let mine = {
        let mut state = STATE.lock().unwrap();
        let current = clipboard.get_text().ok();
        if state.original.is_none() || current.as_deref() != Some(state.pasted_text.as_str()) {
            state.original = Some(current);
        }
        if clipboard.set_text(text).is_err() {
            crate::log!("Cannot write to the clipboard");
            return;
        }
        state.pasted += 1;
        state.pasted_text = text.to_string();
        state.pasted
    };
    platform::paste();
    thread::spawn(move || {
        if press_return {
            thread::sleep(RETURN_DELAY);
            platform::press_return();
        }
        thread::sleep(RESTORE_DELAY);
        let mut state = STATE.lock().unwrap();
        // A later paste restores the clipboard itself; a copy made meanwhile is kept.
        if state.pasted != mine {
            return;
        }
        let Some(original) = state.original.take() else { return };
        let Ok(mut clipboard) = arboard::Clipboard::new() else { return };
        if clipboard.get_text().ok().as_deref() != Some(state.pasted_text.as_str()) {
            return;
        }
        let _ = match original {
            Some(text) => clipboard.set_text(text),
            None => clipboard.clear(),
        };
    });
}

pub use platform::{is_trusted, open_accessibility_settings, request_access};

#[cfg(target_os = "macos")]
mod platform {
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::string::{CFString, CFStringRef};
    use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, CGKeyCode};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> bool;
        fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
        static kAXTrustedCheckOptionPrompt: CFStringRef;
    }

    const KEY_V: CGKeyCode = 0x09;
    const KEY_RETURN: CGKeyCode = 0x24;

    pub fn is_trusted() -> bool {
        unsafe { AXIsProcessTrusted() }
    }

    /// Shows the system's prompt to grant the Accessibility permission, when it is missing.
    pub fn request_access() -> bool {
        unsafe {
            let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
            let options = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), CFBoolean::true_value().as_CFType())]);
            AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef())
        }
    }

    pub fn open_accessibility_settings() {
        request_access();
        let _ = std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .spawn();
    }

    pub fn paste() {
        post(KEY_V, CGEventFlags::CGEventFlagCommand);
    }

    pub fn press_return() {
        post(KEY_RETURN, CGEventFlags::CGEventFlagNull);
    }

    fn post(key: CGKeyCode, flags: CGEventFlags) {
        let Ok(source) = CGEventSource::new(CGEventSourceStateID::CombinedSessionState) else { return };
        for down in [true, false] {
            if let Ok(event) = CGEvent::new_keyboard_event(source.clone(), key, down) {
                event.set_flags(flags);
                event.post(CGEventTapLocation::HID);
            }
        }
    }
}

#[cfg(windows)]
mod platform {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL, VK_RETURN,
    };

    const VK_V: VIRTUAL_KEY = 0x56;

    /// Windows asks for no permission to send key strokes. (They do not reach an app running as
    /// administrator unless voiced does too.)
    pub fn is_trusted() -> bool {
        true
    }

    pub fn request_access() -> bool {
        true
    }

    pub fn open_accessibility_settings() {}

    pub fn paste() {
        send(&[(VK_CONTROL, false), (VK_V, false), (VK_V, true), (VK_CONTROL, true)]);
    }

    pub fn press_return() {
        send(&[(VK_RETURN, false), (VK_RETURN, true)]);
    }

    fn send(keys: &[(VIRTUAL_KEY, bool)]) {
        let inputs: Vec<INPUT> = keys
            .iter()
            .map(|&(key, up)| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT { wVk: key, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 },
                },
            })
            .collect();
        unsafe {
            SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32);
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod platform {
    pub fn is_trusted() -> bool {
        false
    }
    pub fn request_access() -> bool {
        false
    }
    pub fn open_accessibility_settings() {}
    pub fn paste() {}
    pub fn press_return() {}
}
