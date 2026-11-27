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
    menu: Menu,
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
            } else if event.id == items.accessibility.id() && !snapshot.accessibility_allowed {
                crate::typer::open_accessibility_settings();
            }
        }
    })
}

fn build() -> Result<(TrayIcon, Items), String> {
    // Status rows cannot be chosen. On macOS they are shown as labels in the normal text colour
    // (paint_rows); the Accessibility row can be chosen while the permission is missing.
    let row = |text: &str| MenuItem::new(text, false, None);
    let menu = Menu::new();
    let items = Items {
        menu: menu.clone(),
        state: row("voiced · Starting…"),
        name: row(""),
        connections: row(""),
        since: row(""),
        typed: row(""),
        accessibility: row(""),
        quit: MenuItem::new("Quit voiced", true, None),
    };
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
    #[cfg(target_os = "macos")]
    mac_status_item(&icon);
    Ok((icon, items))
}

/// The look and place the Swift service's icon had: the system's "waveform" symbol at 16 pt rather
/// than the default 13 (19×19 instead of 15×16, a little larger in the bar), in a square item.
///
/// It also keeps the item where it can be seen. Without a remembered position macOS puts a new
/// item at the far left of the status area, which on a full menu bar is behind the notch, and
/// with Hidden Bar or a similar app behind its divider. The position is the distance from the
/// right edge of the screen, among the system items, and is remembered under the autosave name;
/// once the user ⌘-drags the item elsewhere, macOS stores that under the same name and it is kept.
#[cfg(target_os = "macos")]
fn mac_status_item(tray: &TrayIcon) {
    use objc2_app_kit::{NSFontWeightRegular, NSImage, NSImageSymbolConfiguration, NSSquareStatusItemLength};
    use objc2_foundation::{MainThreadMarker, NSString, NSUserDefaults};

    const AUTOSAVE_NAME: &str = "VoicedInput";
    const DEFAULT_POSITION: f64 = 200.0;

    let (Some(item), Some(mtm)) = (tray.ns_status_item(), MainThreadMarker::new()) else { return };
    unsafe {
        let defaults = NSUserDefaults::standardUserDefaults();
        let key = NSString::from_str(&format!("NSStatusItem Preferred Position {AUTOSAVE_NAME}"));
        if defaults.objectForKey(&key).is_none() {
            defaults.setDouble_forKey(DEFAULT_POSITION, &key);
        }
        item.setAutosaveName(Some(&NSString::from_str(AUTOSAVE_NAME)));
        item.setLength(NSSquareStatusItemLength);
        let Some(button) = item.button(mtm) else { return };
        let Some(image) = NSImage::imageWithSystemSymbolName_accessibilityDescription(
            &NSString::from_str("waveform"),
            Some(&NSString::from_str("voiced")),
        ) else {
            return;
        };
        let configuration = NSImageSymbolConfiguration::configurationWithPointSize_weight(16.0, NSFontWeightRegular);
        let image = image.imageWithSymbolConfiguration(&configuration).unwrap_or(image);
        image.setTemplate(true);
        button.setImage(Some(&image));
    }
}

fn refresh(items: &Items, status: &Status) {
    let state = match &status.listener {
        ListenerState::Starting => "Starting…".to_string(),
        ListenerState::Listening(port) => format!("Running · port {port}"),
        ListenerState::Failed(detail) => format!("Failed: {detail}"),
    };
    let last = status.last_sentence_at.map(|t| format!(" (last {})", t.format("%H:%M"))).unwrap_or_default();
    let typed = match &status.delivery_error {
        Some(error) => error.clone(),
        None => format!("Sentences delivered: {}{last}", status.sentences_typed),
    };
    let accessibility = if status.accessibility_allowed { "Accessibility: allowed" } else { "Accessibility: not allowed — Allow…" };
    items.accessibility.set_enabled(!status.accessibility_allowed);
    // Each row with its place in the menu (the separator is 1).
    let rows = [
        (&items.state, 0, format!("voiced · {state}")),
        (&items.name, 2, format!("Advertised as {}", status.name)),
        (&items.connections, 3, format!("iPhones connected: {}", status.connections)),
        (&items.since, 4, format!("Running since {}", status.started_at.format("%H:%M"))),
        (&items.typed, 5, typed),
        (&items.accessibility, 6, accessibility.to_string()),
    ];
    #[cfg(target_os = "macos")]
    {
        let dot = match &status.listener {
            ListenerState::Starting => Dot::Yellow,
            ListenerState::Listening(_) => Dot::Green,
            ListenerState::Failed(_) => Dot::Red,
        };
        paint_rows(&items.menu, &rows, status.accessibility_allowed, dot);
    }
    #[cfg(not(target_os = "macos"))]
    for (item, _, text) in &rows {
        item.set_text(text);
    }
}

/// The colour of the dot before the state.
#[cfg(target_os = "macos")]
#[derive(Clone, Copy)]
enum Dot {
    Yellow,
    Green,
    Red,
}

/// Shows each row as a plain label in the item's place, in the menu's font and the normal text
/// colour: an item with a view of its own is neither highlighted nor chosen, while one that merely
/// cannot be chosen is drawn grey whatever colour its title asks for. The Accessibility row stays
/// an ordinary item while the permission is missing, to be chosen to open Settings.
#[cfg(target_os = "macos")]
fn paint_rows(menu: &Menu, rows: &[(&MenuItem, usize, String)], accessibility_allowed: bool, dot: Dot) {
    use objc2::rc::Retained;
    use objc2::MainThreadOnly;
    use objc2_app_kit::{NSBox, NSBoxType, NSColor, NSFont, NSMenu, NSTextField, NSTitlePosition, NSView};
    use objc2_foundation::{MainThreadMarker, NSPoint, NSRect, NSSize, NSString};
    use tray_icon::menu::ContextMenu;

    /// Space left and right of a label, as the menu leaves around its items' titles.
    const INSET: f64 = 14.0;
    const HEIGHT: f64 = 22.0;
    /// The state's dot, as in the Swift service's card: 7 pt across, 5 pt before the text.
    const DOT: f64 = 7.0;
    const DOT_GAP: f64 = 5.0;

    let Some(mtm) = MainThreadMarker::new() else { return };
    unsafe {
        let ns_menu = &*(menu.ns_menu() as *const NSMenu);
        for (item, index, text) in rows {
            let Some(ns_item) = ns_menu.itemAtIndex(*index as isize) else { continue };
            if *index == 6 && !accessibility_allowed {
                ns_item.setView(None);
                item.set_text(text);
                continue;
            }
            // The row's view holds its label first, then, for the state, the dot.
            let subview = |i: usize| ns_item.view().and_then(|view| {
                let subviews = view.subviews();
                (i < subviews.count()).then(|| subviews.objectAtIndex(i))
            });
            let existing = subview(0).and_then(|label| label.downcast::<NSTextField>().ok());
            let (view, label): (Retained<NSView>, Retained<NSTextField>) = match (ns_item.view(), existing) {
                (Some(view), Some(label)) => (view, label),
                _ => {
                    let label = NSTextField::labelWithString(&NSString::from_str(""), mtm);
                    label.setFont(Some(&NSFont::menuFontOfSize(0.0)));
                    label.setTextColor(Some(&NSColor::labelColor()));
                    let view = NSView::initWithFrame(NSView::alloc(mtm), NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1.0, HEIGHT)));
                    view.addSubview(&label);
                    if *index == 0 {
                        let circle = NSBox::initWithFrame(NSBox::alloc(mtm), NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(DOT, DOT)));
                        circle.setBoxType(NSBoxType::Custom);
                        circle.setTitlePosition(NSTitlePosition::NoTitle);
                        circle.setBorderWidth(0.0);
                        circle.setCornerRadius(DOT / 2.0);
                        view.addSubview(&circle);
                    }
                    ns_item.setView(Some(&view));
                    (view, label)
                }
            };
            let text = NSString::from_str(text);
            if label.stringValue() != text {
                label.setStringValue(&text);
            }
            label.sizeToFit();
            let size = label.frame().size;
            let mut left = INSET;
            if let Some(circle) = subview(1).and_then(|circle| circle.downcast::<NSBox>().ok()) {
                let color = match dot {
                    Dot::Yellow => NSColor::systemYellowColor(),
                    Dot::Green => NSColor::systemGreenColor(),
                    Dot::Red => NSColor::systemRedColor(),
                };
                circle.setFillColor(&color);
                // Centred on the line, as the label is.
                circle.setFrameOrigin(NSPoint::new(INSET, ((HEIGHT - DOT) / 2.0).round()));
                left += DOT + DOT_GAP;
            }
            label.setFrameOrigin(NSPoint::new(left, ((HEIGHT - size.height) / 2.0).round()));
            view.setFrameSize(NSSize::new(left + size.width + INSET, HEIGHT));
        }
    }
}

/// A waveform of seven rounded bars in black, drawn here so the binary needs no image file. On
/// macOS it is replaced by the system's waveform symbol (mac_status_item).
fn icon() -> Icon {
    const SIZE: usize = 36;
    let heights = [0.28, 0.55, 0.85, 1.0, 0.7, 0.45, 0.25];
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
            rgba[pixel..pixel + 3].fill(0);
            rgba[pixel + 3] = (coverage * 255.0) as u8;
        }
    }
    Icon::from_rgba(rgba, SIZE as u32, SIZE as u32).expect("valid icon")
}
