use tauri::{AppHandle, Emitter, Manager, Runtime, State};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcut, GlobalShortcutExt, Shortcut};
use tauri_plugin_opener::OpenerExt;

use crate::shortcut::Hotkey;
use crate::{AppState, cache, drafts, feed, files, search, settings, topics};

fn now_us() -> i64 {
    chrono::Utc::now().timestamp_micros()
}

#[tauri::command]
pub async fn prepare_copy_items(state: State<'_, AppState>, item_ids: Vec<String>) -> Result<String, String> {
    let prepared = crate::clipboard::prepare_many(&state, &item_ids, now_us()).await?;
    let token = uuid::Uuid::new_v4().to_string();
    state.prepared_copies.lock().unwrap().insert(token.clone(), prepared);
    Ok(token)
}

#[tauri::command]
pub async fn discard_copy_items(state: State<'_, AppState>, token: String) -> Result<(), String> {
    if let Some(prepared) = state.prepared_copies.lock().unwrap().remove(&token) { prepared.discard(); }
    Ok(())
}

#[tauri::command]
pub async fn finish_copy_items(app: AppHandle, token: String) -> Result<(), String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    let handle = app.clone();
    app.run_on_main_thread(move || {
        let state = handle.state::<AppState>();
        let result = (|| {
            let prepared = state.prepared_copies.lock().unwrap().remove(&token).ok_or("Copy was cancelled")?;
            let result = (|| {
                prepared.validate(&state)?;
                #[cfg(target_os = "windows")]
                let owner = handle.get_webview_window("main").ok_or("Couldn't access the clipboard window")?
                    .hwnd().map_err(|_| "Couldn't access the clipboard window")?.0 as usize;
                #[cfg(target_os = "windows")]
                return crate::clipboard::write(&prepared.payload, owner);
                #[cfg(target_os = "macos")]
                return crate::clipboard::write(&prepared.payload, &objc2_app_kit::NSPasteboard::generalPasteboard());
                #[cfg(not(any(target_os = "windows", target_os = "macos")))]
                return crate::clipboard::write(&prepared.payload);
            })();
            if result.is_err() { prepared.discard(); }
            result
        })();
        let _ = send.send(result);
    }).map_err(|_| "Couldn't access the clipboard")?;
    receive.await.map_err(|_| "Couldn't access the clipboard")?
}

#[tauri::command]
pub async fn set_items_trashed(app: AppHandle, state: State<'_, AppState>, item_ids: Vec<String>, trashed: bool) -> Result<(), String> {
    feed::set_many_trashed(&state.db.lock().unwrap(), &item_ids, trashed, now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn copy_item(app: AppHandle, state: State<'_, AppState>, item_id: String) -> Result<(), String> {
    write_clipboard(app, crate::clipboard::prepare(&state, &item_id, now_us()).await?).await
}

#[tauri::command]
pub async fn copy_attachment(app: AppHandle, state: State<'_, AppState>, attachment_id: String) -> Result<(), String> {
    write_clipboard(app, crate::clipboard::prepare_attachment(&state, &attachment_id, now_us()).await?).await
}

async fn write_clipboard(app: AppHandle, payload: crate::clipboard::Payload) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    let owner = app
        .get_webview_window("main")
        .ok_or("Couldn't access the clipboard window")?
        .hwnd()
        .map_err(|_| "Couldn't access the clipboard window")?
        .0 as usize;
    let (send, receive) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        #[cfg(target_os = "windows")]
        let result = crate::clipboard::write(&payload, owner);
        #[cfg(target_os = "macos")]
        let result = crate::clipboard::write(&payload, &objc2_app_kit::NSPasteboard::generalPasteboard());
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        let result = crate::clipboard::write(&payload);
        let _ = send.send(result);
    })
    .map_err(|_| "Couldn't access the clipboard")?;
    receive.await.map_err(|_| "Couldn't access the clipboard")?
}

#[tauri::command]
pub async fn get_settings(state: State<'_, AppState>) -> Result<settings::Settings, String> {
    settings::get(&state.db.lock().unwrap(), &state.secret)
}

fn changed<R: Runtime>(app: &AppHandle<R>, state: &AppState) {
    state.wake.notify_one();
    let _ = app.emit("items-changed", ());
}

#[tauri::command]
pub async fn save_settings(
    app: AppHandle,
    state: State<'_, AppState>,
    server_url: String,
    secret: Option<String>,
    confirmed: Option<settings::Stranded>,
) -> Result<(), settings::SaveError> {
    settings::save_checked(&state.db, &state.secret, &state.http, &server_url, secret.as_deref(), confirmed.unwrap_or_default()).await?;
    state.settings_saved.notify_one();
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub fn double_click_interval_ms() -> u64 {
    #[cfg(target_os = "macos")]
    { (objc2_app_kit::NSEvent::doubleClickInterval() * 1000.0).ceil() as u64 }
    #[cfg(target_os = "windows")]
    {
        #[link(name = "user32")]
        unsafe extern "system" { fn GetDoubleClickTime() -> u32; }
        unsafe { GetDoubleClickTime() as u64 }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    { 500 }
}

#[tauri::command]
pub async fn trash_after_copy(state: State<'_, AppState>) -> Result<Option<bool>, String> {
    settings::trash_after_copy(&state.db.lock().unwrap())
}

#[tauri::command]
pub async fn set_trash_after_copy(app: AppHandle, state: State<'_, AppState>, on: bool) -> Result<(), String> {
    settings::set_trash_after_copy(&state.db.lock().unwrap(), on, now_us())?;
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
pub async fn list_drafts(state: State<'_, AppState>) -> Result<Vec<drafts::Draft>, String> {
    drafts::list(&state.db.lock().unwrap())
}

#[tauri::command]
pub async fn save_draft(state: State<'_, AppState>, place: String, text: String, home_topic_id: Option<String>) -> Result<(), String> {
    drafts::save(&state.db.lock().unwrap(), &place, &text, home_topic_id.as_deref())
}

#[tauri::command]
pub async fn capture<R: Runtime>(
    app: AppHandle<R>,
    window: tauri::WebviewWindow<R>,
    state: State<'_, AppState>,
    text: String,
    attachment_ids: Vec<String>,
    target: feed::Target,
    draft: Option<String>,
) -> Result<(), String> {
    if draft.is_some() && window.label() != "main" {
        return Err("Only the main window has drafts".into());
    }
    feed::capture(&state.db.lock().unwrap(), &state.dir, &text, &attachment_ids, &target, draft.as_deref(), now_us())?;
    changed(&app, &state);
    Ok(())
}

#[tauri::command]
pub async fn move_item(app: AppHandle, state: State<'_, AppState>, item_id: String, target: feed::Target) -> Result<(), String> {
    feed::move_item(&state.db.lock().unwrap(), &item_id, &target, now_us())?;
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
pub async fn picker_topic(app: AppHandle, state: State<'_, AppState>, name: String) -> Result<topics::Topic, String> {
    let topic = topics::picker_topic(&state.db.lock().unwrap(), &name, now_us())?;
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
pub async fn attachment_stored(state: State<'_, AppState>, id: String) -> Result<bool, String> {
    cache::stored(&state, &id, now_us())
}

#[tauri::command]
pub async fn attachment_original(state: State<'_, AppState>, id: String) -> Result<String, String> {
    Ok(cache::file(&state, &id, now_us()).await?.to_string_lossy().into_owned())
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

#[cfg(test)]
mod tests {
    use super::*;
    use keyring_core::api::CredentialStoreApi;
    use tauri::test::{INVOKE_KEY, get_ipc_response, mock_builder};
    use tauri::{WebviewUrl, WebviewWindowBuilder};

    #[test]
    fn binary_attachment_staging_preserves_bytes_and_filename_in_both_windows() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![stage_attachment_bytes])
            .build(tauri::generate_context!(test = true))
            .unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let bytes = vec![0, 137, 80, 78, 71, 13, 10, 255];
        let filename = "截图 café.png";
        for label in ["main", "quick-capture"] {
            let window = WebviewWindowBuilder::new(&app, label, WebviewUrl::default()).build().unwrap();
            let send = |body| {
                let mut headers = tauri::http::HeaderMap::new();
                headers.insert("x-filename", percent_encoding::utf8_percent_encode(filename, percent_encoding::NON_ALPHANUMERIC).to_string().parse().unwrap());
                get_ipc_response(&window, tauri::webview::InvokeRequest {
                    cmd: "stage_attachment_bytes".into(),
                    callback: tauri::ipc::CallbackFn(0),
                    error: tauri::ipc::CallbackFn(1),
                    url: window.url().unwrap(),
                    body,
                    headers,
                    invoke_key: INVOKE_KEY.to_string(),
                })
            };
            let staged = send(tauri::ipc::InvokeBody::Raw(bytes.clone())).unwrap().deserialize::<serde_json::Value>().unwrap();
            assert_eq!(staged["filename"], filename);
            assert_eq!(staged["size_bytes"], bytes.len());
            assert_eq!(staged["mime_type"], "image/png");
            let path = dir.path().join("files").join(staged["id"].as_str().unwrap()).join(filename);
            assert_eq!(std::fs::read(path).unwrap(), bytes);
            let count = std::fs::read_dir(dir.path().join("files")).unwrap().count();
            assert_eq!(send(serde_json::json!(bytes).into()).unwrap_err(), serde_json::json!("Expected the file's bytes"));
            assert_eq!(std::fs::read_dir(dir.path().join("files")).unwrap().count(), count);
        }
    }

    #[test]
    fn only_the_main_window_can_clear_a_draft() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        drafts::save(&conn, "home", "keep me", None).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![capture])
            .build(tauri::generate_context!(test = true))
            .unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let send = |label: &str, draft: Option<&str>| {
            let window = app.get_webview_window(label).unwrap_or_else(|| WebviewWindowBuilder::new(&app, label, WebviewUrl::default()).build().unwrap());
            get_ipc_response(
                &window,
                tauri::webview::InvokeRequest {
                    cmd: "capture".into(),
                    callback: tauri::ipc::CallbackFn(0),
                    error: tauri::ipc::CallbackFn(1),
                    url: window.url().unwrap(),
                    body: serde_json::json!({ "text": "note", "attachmentIds": [], "target": { "kind": "inbox" }, "draft": draft }).into(),
                    headers: Default::default(),
                    invoke_key: INVOKE_KEY.to_string(),
                },
            )
        };
        let stored = || drafts::list(&app.state::<AppState>().db.lock().unwrap()).unwrap().len();

        send("quick-capture", None).unwrap();
        assert!(send("quick-capture", Some("home")).is_err());
        assert_eq!(stored(), 1);
        assert!(send("main", Some("home")).is_ok());
        assert_eq!(stored(), 0);
    }
}
