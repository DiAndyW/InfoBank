use tauri::State;

use crate::{AppState, feed, settings, store};

#[tauri::command]
pub async fn get_settings(state: State<'_, AppState>) -> Result<settings::Settings, String> {
    settings::get(&state.db.lock().unwrap(), &state.secret)
}

#[tauri::command]
pub async fn save_settings(state: State<'_, AppState>, server_url: String, secret: Option<String>) -> Result<(), String> {
    settings::save(&state.db.lock().unwrap(), &state.secret, &server_url, secret.as_deref())?;
    state.settings_saved.notify_one();
    state.wake.notify_one();
    Ok(())
}

#[tauri::command]
pub async fn list_topics(state: State<'_, AppState>) -> Result<Vec<store::Topic>, String> {
    store::list_topics(&state.db.lock().unwrap()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn capture(state: State<'_, AppState>, text: String) -> Result<(), String> {
    feed::capture(&state.db.lock().unwrap(), &text, chrono::Utc::now().timestamp_micros())?;
    state.wake.notify_one();
    Ok(())
}

#[tauri::command]
pub async fn list_items(
    state: State<'_, AppState>,
    view: feed::View,
    before: Option<feed::Before>,
) -> Result<Vec<feed::FeedItem>, String> {
    feed::list_items(&state.db.lock().unwrap(), &view, before.as_ref()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn sync_status(state: State<'_, AppState>) -> Result<&'static str, String> {
    Ok(*state.status.lock().unwrap())
}
