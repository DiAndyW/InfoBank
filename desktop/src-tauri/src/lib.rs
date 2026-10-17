mod cache;
mod commands;
mod feed;
mod files;
mod ops;
mod settings;
mod store;
mod sync;
mod topics;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

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
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .on_window_event(|window, event| {
            // try_state: a focus event can arrive before setup has managed the state.
            let Some(state) = window.try_state::<AppState>() else { return };
            match event {
                tauri::WindowEvent::Focused(true) => state.wake.notify_one(),
                tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) => {
                    let (window, dir, paths) = (window.clone(), state.dir.clone(), paths.clone());
                    tauri::async_runtime::spawn_blocking(move || {
                        let _ = window.emit("attachments-staged", files::stage_paths(&dir, &paths));
                    });
                }
                _ => {}
            }
        })
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            let db = store::open(&dir.join("notebank.db"))?;
            files::sweep_staged(&db, &dir)?;

            #[cfg(target_os = "macos")]
            let keychain = apple_native_keyring_store::keychain::Store::new()?;
            #[cfg(target_os = "windows")]
            let keychain = windows_native_keyring_store::Store::new()?;
            let secret = keychain.build(&app.config().identifier, "shared-secret", None)?;

            app.manage(AppState::new(db, secret, dir));
            tauri::async_runtime::spawn(sync::run(app.handle().clone()));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::list_topics,
            commands::capture,
            commands::move_item,
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
            commands::sync_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
