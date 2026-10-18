use std::sync::atomic::Ordering;

use tauri::{AppHandle, Emitter, Manager, Runtime};

use crate::AppState;

pub const LABEL: &str = "quick-capture";

pub fn summon<R: Runtime>(app: &AppHandle<R>) {
    let Some(window) = app.get_webview_window(LABEL) else { return };
    if !window.is_visible().unwrap_or(false) {
        #[cfg(target_os = "macos")]
        remember_frontmost(&app.state::<AppState>());
        let _ = window.center();
        let _ = window.show();
        let _ = app.emit_to(LABEL, "quick-capture-shown", ());
    }
    let _ = window.set_focus();
}

pub fn dismiss<R: Runtime>(app: &AppHandle<R>) {
    // Hiding before the other app is active would bring the main window forward for a moment; focus_lost hides instead.
    #[cfg(target_os = "macos")]
    if reactivate_previous(&app.state::<AppState>()) {
        return;
    }
    hide(app);
}

pub fn focus_lost<R: Runtime>(app: &AppHandle<R>) {
    let state = app.state::<AppState>();
    if state.picking_files.load(Ordering::SeqCst) {
        return;
    }
    #[cfg(target_os = "macos")]
    state.previous_app.lock().unwrap().take();
    hide(app);
}

fn hide<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.hide();
    }
    let _ = app.emit_to(LABEL, "quick-capture-hidden", ());
}

#[cfg(target_os = "macos")]
fn remember_frontmost(state: &AppState) {
    let own = std::process::id() as i32;
    let front = objc2_app_kit::NSWorkspace::sharedWorkspace().frontmostApplication().map(|a| a.processIdentifier());
    *state.previous_app.lock().unwrap() = front.filter(|&pid| pid != own);
}

#[cfg(target_os = "macos")]
fn reactivate_previous(state: &AppState) -> bool {
    let Some(pid) = state.previous_app.lock().unwrap().take() else { return false };
    objc2_app_kit::NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
        .is_some_and(|app| app.activateWithOptions(objc2_app_kit::NSApplicationActivationOptions::empty()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use keyring_core::api::CredentialStoreApi;
    use std::sync::mpsc;
    use std::time::Duration;
    use tauri::Listener;

    #[test]
    fn losing_focus_hides_and_resets_the_box_unless_a_file_dialog_is_open() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = tauri::test::mock_app();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        tauri::WebviewWindowBuilder::new(&app, LABEL, tauri::WebviewUrl::default()).build().unwrap();
        let (tx, rx) = mpsc::channel();
        app.listen_any("quick-capture-hidden", move |_| tx.send(()).unwrap());

        app.state::<AppState>().picking_files.store(true, Ordering::SeqCst);
        focus_lost(app.handle());
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "picking a file discarded the draft");

        app.state::<AppState>().picking_files.store(false, Ordering::SeqCst);
        focus_lost(app.handle());
        rx.recv_timeout(Duration::from_secs(2)).expect("click-away didn't reset the box");
    }
}
