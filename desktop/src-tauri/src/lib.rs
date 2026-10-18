mod cache;
mod commands;
mod feed;
mod files;
mod ops;
mod quick;
mod search;
mod settings;
mod shortcut;
mod store;
mod sync;
mod topics;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::AtomicBool;

use keyring_core::api::CredentialStoreApi;
use tauri::{Emitter, Manager};

pub struct AppState {
    db: Mutex<rusqlite::Connection>,
    secret: keyring_core::Entry,
    dir: PathBuf,
    http: reqwest::Client,
    wake: tokio::sync::Notify,
    settings_saved: tokio::sync::Notify,
    status: Mutex<&'static str>,
    skipped_uploads: Mutex<HashSet<String>>,
    picking_files: AtomicBool,
    #[cfg(target_os = "macos")]
    previous_app: Mutex<Option<i32>>,
}

impl AppState {
    fn new(db: rusqlite::Connection, secret: keyring_core::Entry, dir: PathBuf) -> Self {
        AppState {
            db: Mutex::new(db),
            secret,
            dir,
            http: sync::client(),
            wake: tokio::sync::Notify::new(),
            settings_saved: tokio::sync::Notify::new(),
            status: Mutex::new("synced"),
            skipped_uploads: Mutex::new(HashSet::new()),
            picking_files: AtomicBool::new(false),
            #[cfg(target_os = "macos")]
            previous_app: Mutex::new(None),
        }
    }
}

fn stage_dropped<R: tauri::Runtime>(app: &tauri::AppHandle<R>, label: String, dir: PathBuf, paths: Vec<PathBuf>) {
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _ = app.emit_to(label.as_str(), "attachments-staged", files::stage_paths(&dir, &paths));
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _, event| {
                    if event.state() == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                        quick::summon(app);
                    }
                })
                .build(),
        )
        .on_window_event(|window, event| {
            // try_state: a focus event can arrive before setup has managed the state.
            let Some(state) = window.try_state::<AppState>() else { return };
            match event {
                tauri::WindowEvent::Focused(true) => state.wake.notify_one(),
                tauri::WindowEvent::Focused(false) if window.label() == quick::LABEL => quick::focus_lost(window.app_handle()),
                tauri::WindowEvent::CloseRequested { api, .. } if window.label() == "main" => {
                    #[cfg(target_os = "macos")]
                    {
                        api.prevent_close();
                        let _ = window.hide();
                    }
                    #[cfg(not(target_os = "macos"))]
                    {
                        let _ = api;
                        window.app_handle().exit(0);
                    }
                }
                tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) => {
                    stage_dropped(window.app_handle(), window.label().to_string(), state.dir.clone(), paths.clone())
                }
                _ => {}
            }
        })
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            let db = store::open(&dir.join("notebank.db"))?;
            files::sweep_staged(&db, &dir)?;
            let hotkey = shortcut::get(&db)?;

            #[cfg(target_os = "macos")]
            let keychain = apple_native_keyring_store::keychain::Store::new()?;
            #[cfg(target_os = "windows")]
            let keychain = windows_native_keyring_store::Store::new()?;
            let secret = keychain.build(&app.config().identifier, "shared-secret", None)?;

            app.manage(AppState::new(db, secret, dir));
            if hotkey.on {
                use tauri_plugin_global_shortcut::GlobalShortcutExt;
                if let Err(e) = app.global_shortcut().register(shortcut::parse(&hotkey.shortcut)?) {
                    eprintln!("Couldn't register the quick-capture shortcut {}: {e}", hotkey.shortcut);
                }
            }
            tauri::async_runtime::spawn(sync::run(app.handle().clone()));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::list_topics,
            commands::capture,
            commands::move_item,
            commands::edit_item,
            commands::trash_item,
            commands::restore_item,
            commands::nav_counts,
            commands::create_topic,
            commands::rename_topic,
            commands::archive_topic,
            commands::unarchive_topic,
            commands::delete_topic,
            commands::pick_files,
            commands::stage_attachment_bytes,
            commands::unstage_attachment,
            commands::thumbnail,
            commands::open_attachment,
            commands::reveal_attachment,
            commands::list_items,
            commands::search_items,
            commands::sync_status,
            commands::set_quick_capture_shortcut,
            commands::set_quick_capture_on,
            commands::dismiss_quick_capture
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app, _event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = _event {
                if let Some(main) = _app.get_webview_window("main") {
                    let _ = main.show();
                    let _ = main.set_focus();
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;
    use tauri::{Listener, WebviewUrl, WebviewWindowBuilder};

    #[test]
    fn a_drop_reaches_only_its_own_window() {
        let dir = tempfile::tempdir().unwrap();
        let app = tauri::test::mock_app();
        let main = WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().unwrap();
        let quick = WebviewWindowBuilder::new(&app, "quick-capture", WebviewUrl::default()).build().unwrap();
        let (tx, rx) = mpsc::channel();
        let to_main = tx.clone();
        main.listen("attachments-staged", move |_| to_main.send("main").unwrap());
        quick.listen("attachments-staged", move |_| tx.send("quick-capture").unwrap());

        stage_dropped(app.handle(), "quick-capture".into(), dir.path().to_path_buf(), vec![]);

        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), "quick-capture");
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "the main window heard it too");
    }
}
