mod commands;
mod feed;
#[cfg_attr(not(test), allow(dead_code))]
mod files;
mod settings;
mod store;
mod sync;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

use keyring_core::api::CredentialStoreApi;
use tauri::Manager;

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
        .on_window_event(|window, event| {
            // try_state: a focus event can arrive before setup has managed the state.
            if let (tauri::WindowEvent::Focused(true), Some(state)) = (event, window.try_state::<AppState>()) {
                state.wake.notify_one();
            }
        })
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            let db = store::open(&dir.join("notebank.db"))?;

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
            commands::list_items,
            commands::sync_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
