//! The service's icon in the menu bar (macOS) or the notification area (Windows): a waveform,
//! black-and-white like the system's own. Clicking it opens a menu with the service's status. The
//! Swift service shows a card instead; a menu is what both systems offer alike.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::{Status, ListenerState};

struct Items {
    state: MenuItem,
    name: MenuItem,
    connections: MenuItem,
    since: MenuItem,
    typed: MenuItem,
    accessibility: MenuItem,
    quit: MenuItem,
}

/// Runs the icon on the main thread for the life of the process. `quit` is called when Quit is
/// chosen (Windows; on macOS launchd would only start the service again, `voiced stop` stops it).
pub fn run(status: Arc<Mutex<Status>>, quit: impl Fn() + 'static) -> ! {
    #[allow(unused_mut)]
    let mut event_loop = EventLoopBuilder::new().build();
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        // A menu bar item only: no Dock icon, no main menu.
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
    }

    let mut tray: Option<(TrayIcon, Items)> = None;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::WaitUntil(Instant::now() + Duration::from_secs(1));
        match event {
            // On macOS the icon can only be made once the event loop runs.
            Event::NewEvents(StartCause::Init) => match build() {
                Ok(built) => tray = Some(built),
                Err(error) => crate::log!("No tray icon: {error}"),
            },
            Event::NewEvents(_) => {}
            _ => return,
        }
        let Some((_, items)) = &tray else { return };
        // The permission can be granted while the service runs; keep the row current.
        let snapshot = {
            let mut status = status.lock().unwrap();
            status.accessibility_allowed = crate::typer::is_trusted();
            status.clone()
        };
        refresh(items, &snapshot);
        while let Ok(event) = MenuEvent::receiver().try_recv() {
            if event.id == items.quit.id() {
                quit();
            } else if event.id == items.accessibility.id() {
                crate::typer::open_accessibility_settings();
            }
        }
    })
}

fn build() -> Result<(TrayIcon, Items), String> {
    let disabled = |text: &str| MenuItem::new(text, false, None);
    let items = Items {
        state: disabled("voiced · Starting…"),
        name: disabled(""),
        connections: disabled(""),
        since: disabled(""),
        typed: disabled(""),
        accessibility: MenuItem::new("", false, None),
        quit: MenuItem::new("Quit voiced", true, None),
    };
    let menu = Menu::new();
    let separator = PredefinedMenuItem::separator();
    menu.append_items(&[&items.state, &separator, &items.name, &items.connections, &items.since, &items.typed])
        .map_err(|e| e.to_string())?;
    if cfg!(target_os = "macos") {
        menu.append(&items.accessibility).map_err(|e| e.to_string())?;
    }
    if cfg!(windows) {
        menu.append_items(&[&PredefinedMenuItem::separator(), &items.quit]).map_err(|e| e.to_string())?;
    }
    let icon = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("voiced")
        .with_icon(icon())
        .with_icon_as_template(true)
        .build()
        .map_err(|e| e.to_string())?;
    Ok((icon, items))
}

fn refresh(items: &Items, status: &Status) {
    let state = match &status.listener {
        ListenerState::Starting => "Starting…".to_string(),
        ListenerState::Listening(port) => format!("Running · port {port}"),
        ListenerState::Failed(detail) => format!("Failed: {detail}"),
    };
    items.state.set_text(format!("voiced · {state}"));
    items.name.set_text(format!("Advertised as {}", status.name));
    items.connections.set_text(format!("iPhones connected: {}", status.connections));
    items.since.set_text(format!("Running since {}", status.started_at.format("%H:%M")));
    let last = status.last_sentence_at.map(|t| format!(" (last {})", t.format("%H:%M"))).unwrap_or_default();
    items.typed.set_text(match &status.delivery_error {
        Some(error) => error.clone(),
        None => format!("Sentences delivered: {}{last}", status.sentences_typed),
    });
    if status.accessibility_allowed {
        items.accessibility.set_text("Accessibility: allowed");
        items.accessibility.set_enabled(false);
    } else {
        items.accessibility.set_text("Accessibility: not allowed — Allow…");
        items.accessibility.set_enabled(true);
    }
}

/// A waveform of seven rounded bars, drawn here so the binary needs no image file. Black on macOS,
/// where it is a template image the menu bar tints; white on Windows, whose taskbar is dark.
fn icon() -> Icon {
    const SIZE: usize = 36;
    let heights = [0.28, 0.55, 0.85, 1.0, 0.7, 0.45, 0.25];
    let colour: u8 = if cfg!(windows) { 255 } else { 0 };
    let bar = 3.0f32;
    let gap = 2.0f32;
    let total = heights.len() as f32 * bar + (heights.len() - 1) as f32 * gap;
    let left = (SIZE as f32 - total) / 2.0;
    let mut rgba = vec![0u8; SIZE * SIZE * 4];
    for y in 0..SIZE {
        for x in 0..SIZE {
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            let mut coverage = 0.0f32;
            for (index, height) in heights.iter().enumerate() {
                let cx = left + index as f32 * (bar + gap) + bar / 2.0;
                let half = height * (SIZE as f32 - 6.0) / 2.0;
                let cy = SIZE as f32 / 2.0;
                // Distance to a vertical capsule of radius bar / 2.
                let dy = ((py - cy).abs() - (half - bar / 2.0)).max(0.0);
                let distance = ((px - cx).powi(2) + dy * dy).sqrt() - bar / 2.0;
                coverage = coverage.max((0.5 - distance).clamp(0.0, 1.0));
            }
            let pixel = (y * SIZE + x) * 4;
            rgba[pixel..pixel + 3].fill(colour);
            rgba[pixel + 3] = (coverage * 255.0) as u8;
        }
    }
    Icon::from_rgba(rgba, SIZE as u32, SIZE as u32).expect("valid icon")
}
