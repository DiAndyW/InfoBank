use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::AppHandle;

use crate::shortcut::Hotkey;

pub fn accelerator(hotkey: &Hotkey) -> Option<&str> {
    hotkey.on.then_some(hotkey.shortcut.as_str())
}

fn menu(app: &AppHandle, hotkey: &Hotkey) -> tauri::Result<Menu<tauri::Wry>> {
    let with = |accelerator: Option<&str>| {
        let quick = MenuItem::with_id(app, "quick-capture", "Quick capture", true, accelerator)?;
        let open = MenuItem::with_id(app, "open", "Open NoteBank", true, None::<&str>)?;
        let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
        Menu::with_items(app, &[&quick, &open, &PredefinedMenuItem::separator(app)?, &quit])
    };
    // macOS menus can't show some keys a hotkey may use (Caps Lock, media keys); the hotkey still works.
    with(accelerator(hotkey)).or_else(|_| with(None))
}

pub fn build(app: &AppHandle, hotkey: &Hotkey) -> Result<(), String> {
    let e = |e: tauri::Error| e.to_string();
    let menu = menu(app, hotkey).map_err(e)?;
    #[cfg(target_os = "macos")]
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-template.png")).map_err(e)?;
    #[cfg(not(target_os = "macos"))]
    let icon = app.default_window_icon().cloned().ok_or("no app icon")?;
    TrayIconBuilder::with_id("main")
        .icon(icon)
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("NoteBank")
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quick-capture" => crate::quick::summon(app),
            "open" => crate::show_main(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            let left_click = matches!(
                event,
                TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. }
            );
            if left_click && !cfg!(target_os = "macos") {
                crate::show_main(tray.app_handle());
            }
        })
        .build(app)
        .map_err(e)?;
    Ok(())
}

// A fresh menu, because macOS menu items can't have their shortcut cleared.
pub fn update(app: &AppHandle, hotkey: &Hotkey) {
    if let (Some(tray), Ok(menu)) = (app.tray_by_id("main"), menu(app, hotkey)) {
        let _ = tray.set_menu(Some(menu));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_menu_shows_every_valid_hotkey_and_none_while_off() {
        for s in ["CommandOrControl+Shift+Space", "Control+Alt+KeyK", "Control+F5", "Super+Digit1", "Control+Shift+Comma"] {
            let shortcut = crate::shortcut::parse(s).unwrap().into_string();
            let on = Hotkey { shortcut: shortcut.clone(), on: true };
            let text = accelerator(&on).unwrap();
            assert!(text.parse::<muda::accelerator::Accelerator>().is_ok(), "the menu can't show {text}");
            assert_eq!(accelerator(&Hotkey { shortcut, on: false }), None);
        }
    }
}
