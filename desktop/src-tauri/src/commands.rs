use tauri::State;

use crate::{AppState, settings, store};

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Result<settings::Settings, String> {
    settings::get(&state.db.lock().unwrap(), &state.secret)
}

#[tauri::command]
pub fn save_settings(state: State<AppState>, server_url: String, secret: Option<String>) -> Result<(), String> {
    settings::save(&state.db.lock().unwrap(), &state.secret, &server_url, secret.as_deref())
}

#[tauri::command]
pub fn list_topics(state: State<AppState>) -> Result<Vec<store::Topic>, String> {
    store::list_topics(&state.db.lock().unwrap()).map_err(|e| e.to_string())
}
