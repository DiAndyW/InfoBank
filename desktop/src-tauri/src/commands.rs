use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcut, GlobalShortcutExt, Shortcut};
use tauri_plugin_opener::OpenerExt;

use crate::shortcut::Hotkey;
use crate::{AppState, cache, feed, files, search, settings, topics};

fn now_us() -> i64 {
    chrono::Utc::now().timestamp_micros()
}

#[tauri::command]
pub async fn get_settings(state: State<'_, AppState>) -> Result<settings::Settings, String> {
    settings::get(&state.db.lock().unwrap(), &state.secret)
}

fn changed(app: &AppHandle, state: &AppState) {
    state.wake.notify_one();
    let _ = app.emit("items-changed", ());
}

#[tauri::command]
pub async fn save_settings(app: AppHandle, state: State<'_, AppState>, server_url: String, secret: Option<String>) -> Result<(), String> {
    settings::save(&state.db.lock().unwrap(), &state.secret, &server_url, secret.as_deref())?;
    state.settings_saved.notify_one();
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn nav_counts(state: State<'_, AppState>) -> Result<feed::Counts, String> {
    feed::nav_counts(&state.db.lock().unwrap(), now_us()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn edit_item(
    app: AppHandle,
    state: State<'_, AppState>,
    item_id: String,
    text: String,
    add_ids: Vec<String>,
    remove_ids: Vec<String>,
    base_rev: i64,
) -> Result<feed::Edited, String> {
    let edited = feed::edit_item(&state.db.lock().unwrap(), &state.dir, &item_id, &text, &add_ids, &remove_ids, base_rev, now_us())?;
    changed(&app, &state);
    Ok(edited)
}

#[tauri::command]
pub async fn discard_item(app: AppHandle, state: State<'_, AppState>, item_id: String) -> Result<(), String> {
    feed::discard_item(&state.db.lock().unwrap(), &state.dir, &item_id)?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn resolve_conflict(
    app: AppHandle,
    state: State<'_, AppState>,
    item_id: String,
    keep: feed::Keep,
) -> Result<feed::Edited, String> {
    let edited = feed::resolve_conflict(&state.db.lock().unwrap(), &state.dir, &item_id, keep, now_us())?;
    changed(&app, &state);
    Ok(edited)
}

#[tauri::command]
pub async fn trash_item(app: AppHandle, state: State<'_, AppState>, item_id: String) -> Result<(), String> {
    feed::set_trashed(&state.db.lock().unwrap(), &item_id, true, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn restore_item(app: AppHandle, state: State<'_, AppState>, item_id: String) -> Result<(), String> {
    feed::set_trashed(&state.db.lock().unwrap(), &item_id, false, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn list_topics(state: State<'_, AppState>) -> Result<Vec<topics::Topic>, String> {
    topics::list(&state.db.lock().unwrap()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_items(
    state: State<'_, AppState>,
    view: feed::View,
    before: Option<feed::Before>,
) -> Result<Vec<feed::FeedItem>, String> {
    feed::list_items(&state.db.lock().unwrap(), &view, before.as_ref(), now_us()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn search_items(
    state: State<'_, AppState>,
    query: search::Query,
    before: Option<feed::Before>,
) -> Result<Vec<search::SearchItem>, String> {
    search::search(&state.db.lock().unwrap(), &query, before.as_ref())
}

#[tauri::command]
pub async fn sync_status(state: State<'_, AppState>) -> Result<&'static str, String> {
    Ok(*state.status.lock().unwrap())
}

#[tauri::command]
pub async fn pick_files(app: AppHandle, state: State<'_, AppState>) -> Result<files::StagedFiles, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.picking_files.store(true, std::sync::atomic::Ordering::SeqCst);
    app.dialog().file().pick_files(move |picked| {
        let _ = tx.send(picked.unwrap_or_default());
    });
    let picked = rx.await;
    state.picking_files.store(false, std::sync::atomic::Ordering::SeqCst);
    let paths = picked.map_err(|e| e.to_string())?.into_iter().map(|p| p.into_path()).collect::<Result<Vec<_>, _>>();
    Ok(files::stage_paths(&state.dir, &paths.map_err(|e| e.to_string())?))
}

#[tauri::command]
pub async fn stage_attachment_bytes(state: State<'_, AppState>, request: tauri::ipc::Request<'_>) -> Result<files::Staged, String> {
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else {
        return Err("Expected the file's bytes".into());
    };
    let name = request
        .headers()
        .get("x-filename")
        .and_then(|v| v.to_str().ok())
        .map(|v| percent_encoding::percent_decode_str(v).decode_utf8_lossy().into_owned())
        .unwrap_or_default();
    files::stage_bytes(&state.dir, &name, bytes)
}

#[tauri::command]
pub async fn unstage_attachment(state: State<'_, AppState>, id: String) -> Result<(), String> {
    files::unstage(&state.db.lock().unwrap(), &state.dir, &id)
}

#[tauri::command]
pub async fn capture(
    app: AppHandle,
    state: State<'_, AppState>,
    text: String,
    attachment_ids: Vec<String>,
    topic_id: Option<String>,
) -> Result<(), String> {
    feed::capture(&state.db.lock().unwrap(), &state.dir, &text, &attachment_ids, topic_id.as_deref(), now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn move_item(app: AppHandle, state: State<'_, AppState>, item_id: String, topic_id: Option<String>) -> Result<(), String> {
    feed::move_item(&state.db.lock().unwrap(), &item_id, topic_id.as_deref(), now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn create_topic(app: AppHandle, state: State<'_, AppState>, name: String) -> Result<topics::Topic, String> {
    let topic = topics::create(&state.db.lock().unwrap(), &name, now_us())?;
    changed(&app, &state);
    Ok(topic)
}

#[tauri::command]
pub async fn rename_topic(app: AppHandle, state: State<'_, AppState>, id: String, name: String) -> Result<(), String> {
    topics::rename(&state.db.lock().unwrap(), &id, &name, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn archive_topic(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    topics::set_archived(&state.db.lock().unwrap(), &id, true, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn unarchive_topic(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    topics::set_archived(&state.db.lock().unwrap(), &id, false, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn delete_topic(app: AppHandle, state: State<'_, AppState>, id: String, keep: topics::Keep) -> Result<(), String> {
    topics::delete(&state.db.lock().unwrap(), &id, &keep, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn thumbnail(state: State<'_, AppState>, id: String) -> Result<String, String> {
    Ok(cache::thumbnail(&state, &id, now_us()).await?.to_string_lossy().into_owned())
}

#[tauri::command]
pub async fn open_attachment(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let path = cache::file(&state, &id, now_us()).await?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if files::runnable(&name) {
        return Err(format!("NoteBank won't open {name} because it can run code"));
    }
    app.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn reveal_attachment(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let path = cache::file(&state, &id, now_us()).await?;
    app.opener().reveal_item_in_dir(path).map_err(|e| e.to_string())
}

fn register(shortcuts: &GlobalShortcut<tauri::Wry>, shortcut: &Shortcut) -> Result<(), String> {
    if shortcuts.is_registered(*shortcut) {
        return Ok(());
    }
    shortcuts.register(*shortcut).map_err(|e| format!("Couldn't use this shortcut: {e}"))
}

#[tauri::command]
pub async fn set_quick_capture_shortcut(app: AppHandle, state: State<'_, AppState>, shortcut: String) -> Result<Hotkey, String> {
    let shortcuts = app.global_shortcut();
    let conn = state.db.lock().unwrap();
    let old = crate::shortcut::get(&conn)?;
    let new = crate::shortcut::set_shortcut(&conn, &shortcut, |s| register(shortcuts, s))?;
    if old.on && old.shortcut != new.shortcut {
        let _ = shortcuts.unregister(crate::shortcut::parse(&old.shortcut)?);
    }
    crate::tray::update(&app, &new);
    Ok(new)
}

#[tauri::command]
pub async fn set_quick_capture_on(app: AppHandle, state: State<'_, AppState>, on: bool) -> Result<Hotkey, String> {
    let shortcuts = app.global_shortcut();
    let hotkey = crate::shortcut::set_on(&state.db.lock().unwrap(), on, |s| register(shortcuts, s))?;
    if !on {
        let _ = shortcuts.unregister(crate::shortcut::parse(&hotkey.shortcut)?);
    }
    crate::tray::update(&app, &hotkey);
    Ok(hotkey)
}

#[tauri::command]
pub fn autostart_on(app: AppHandle) -> Result<bool, String> {
    app.autolaunch().is_enabled().map_err(|e| format!("Couldn't read Open at login: {e}"))
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, on: bool) -> Result<bool, String> {
    let launcher = app.autolaunch();
    let changed = if on { launcher.enable() } else { launcher.disable() };
    changed.map_err(|e| format!("Couldn't change Open at login: {e}"))?;
    launcher.is_enabled().map_err(|e| format!("Couldn't read Open at login: {e}"))
}

// Not async: it runs on the main thread, where AppKit expects app activation.
#[tauri::command]
pub fn dismiss_quick_capture(app: AppHandle) {
    crate::quick::dismiss(&app);
}

#[tauri::command]
pub fn startup_error(app: AppHandle) -> Option<crate::StartupError> {
    app.try_state::<crate::StartupError>().map(|s| s.inner().clone())
}

#[tauri::command]
pub fn show_data_folder(app: AppHandle) -> Result<(), String> {
    let failure = app.try_state::<crate::StartupError>().ok_or("No data folder")?;
    let dir = failure.data_dir.as_deref().ok_or("No data folder")?;
    app.opener().reveal_item_in_dir(dir).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn quit(app: AppHandle) {
    app.exit(0);
}
