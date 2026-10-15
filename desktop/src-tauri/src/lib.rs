mod commands;
mod settings;
mod store;

use std::sync::Mutex;

use keyring_core::api::CredentialStoreApi;
use tauri::Manager;

pub struct AppState {
    db: Mutex<rusqlite::Connection>,
    secret: keyring_core::Entry,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            let db = store::open(&dir.join("notebank.db"))?;

            #[cfg(target_os = "macos")]
            let keychain = apple_native_keyring_store::keychain::Store::new()?;
            #[cfg(target_os = "windows")]
            let keychain = windows_native_keyring_store::Store::new()?;
            let secret = keychain.build(&app.config().identifier, "shared-secret", None)?;

            app.manage(AppState { db: Mutex::new(db), secret });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::list_topics
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
