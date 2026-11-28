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
    feed::nav_counts(&state.db.lock().unwrap(), now_us()).map_err(crate::error_message::message)
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
    topics::list(&state.db.lock().unwrap()).map_err(crate::error_message::message)
}

#[tauri::command]
pub async fn list_items(
    state: State<'_, AppState>,
    view: feed::View,
    before: Option<feed::Before>,
    limit: Option<u32>,
) -> Result<Vec<feed::FeedItem>, String> {
    let db = state.db.lock().unwrap();
    match limit {
        None => feed::list_items(&db, &view, before.as_ref(), now_us()),
        Some(limit) if limit > 0 && i64::from(limit) <= feed::PAGE_SIZE =>
            feed::list_items_limited(&db, &view, before.as_ref(), now_us(), i64::from(limit)),
        Some(_) => return Err("Couldn't load the Items".into()),
    }.map_err(crate::error_message::message)
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
    let paths = picked.map_err(crate::error_message::message)?.into_iter().map(|p| p.into_path()).collect::<Result<Vec<_>, _>>();
    Ok(files::stage_paths(&state.dir, &paths.map_err(crate::error_message::message)?))
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
pub async fn list_drafts<R: Runtime>(window: tauri::WebviewWindow<R>, state: State<'_, AppState>) -> Result<Vec<drafts::Draft>, String> {
    if window.label() != "main" { return Err("Only the main window has drafts".into()); }
    drafts::list(&state.db.lock().unwrap())
}

#[tauri::command]
pub async fn save_draft<R: Runtime>(window: tauri::WebviewWindow<R>, state: State<'_, AppState>, place: String, text: String, home_topic_id: Option<String>, attachment_ids: Vec<String>) -> Result<(), String> {
    if window.label() != "main" { return Err("Only the main window has drafts".into()); }
    drafts::save_with_attachments(&state.db.lock().unwrap(), &state.dir, &place, &text, home_topic_id.as_deref(), &attachment_ids)
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
    app.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(crate::error_message::message)
}

#[tauri::command]
pub async fn open_staged_attachment<R: Runtime>(app: AppHandle<R>, window: tauri::WebviewWindow<R>, state: State<'_, AppState>, id: String) -> Result<(), String> {
    if window.label() != "main" { files::require_unowned(&state.db.lock().unwrap(), &id, None)?; }
    let path = files::staged_open_path(&state.dir, &id)?;
    app.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(crate::error_message::message)
}

#[tauri::command]
pub async fn staged_thumbnail<R: Runtime>(window: tauri::WebviewWindow<R>, state: State<'_, AppState>, id: String) -> Result<String, String> {
    if window.label() != "main" { files::require_unowned(&state.db.lock().unwrap(), &id, None)?; }
    let source = files::staged_open_path(&state.dir, &id)?;
    let key = format!("preview:{id}");
    if crate::thumbnails::backing_off(&state, &key) { return Err("No preview".into()); }
    let Some(bytes) = crate::preview::make(source).await else {
        crate::thumbnails::note_failure(&state, &key);
        return Err("No preview".into());
    };
    let target = state.dir.join("thumbnails").join(format!("{id}.jpg"));
    let temporary = target.with_file_name(format!(".dl-{}", uuid::Uuid::new_v4()));
    tokio::fs::create_dir_all(target.parent().unwrap()).await.map_err(crate::error_message::message)?;
    let published = async {
        tokio::fs::write(&temporary, bytes).await.map_err(crate::error_message::message)?;
        let conn = state.db.lock().unwrap();
        if window.label() != "main" { files::require_unowned(&conn, &id, None)?; }
        let owned: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM attachments WHERE id = ?1)", [&id], |r| r.get(0)).map_err(crate::error_message::message)?;
        if owned { return Err("No preview".into()); }
        files::staged_open_path(&state.dir, &id)?;
        std::fs::rename(&temporary, &target).map_err(crate::error_message::message)
    }.await;
    if let Err(error) = published {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(error);
    }
    state.thumbnail_retries.lock().unwrap().remove(&key);
    Ok(target.to_string_lossy().into_owned())
}

#[tauri::command]
pub async fn save_attachment(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let filename: String = state.db.lock().unwrap()
        .query_row("SELECT filename FROM attachments WHERE id = ?1", [&id], |r| r.get(0))
        .map_err(|_| "Unknown attachment")?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.picking_files.store(true, std::sync::atomic::Ordering::SeqCst);
    app.dialog().file().set_file_name(&filename).save_file(move |picked| {
        let _ = tx.send(picked);
    });
    let picked = rx.await;
    state.picking_files.store(false, std::sync::atomic::Ordering::SeqCst);
    let Some(path) = picked.map_err(crate::error_message::message)? else { return Ok(()) };
    let path = path.into_path().map_err(crate::error_message::message)?;
    cache::save(&state, &id, now_us(), &path).await
}

fn register(shortcuts: &GlobalShortcut<tauri::Wry>, shortcut: &Shortcut) -> Result<(), String> {
    if shortcuts.is_registered(*shortcut) {
        return Ok(());
    }
    shortcuts.register(*shortcut).map_err(|e| format!("Couldn't use this shortcut: {}", crate::error_message::message(e)))
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
    app.autolaunch().is_enabled().map_err(|e| format!("Couldn't read Open at login: {}", crate::error_message::message(e)))
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, on: bool) -> Result<bool, String> {
    let launcher = app.autolaunch();
    let changed = if on { launcher.enable() } else { launcher.disable() };
    changed.map_err(|e| format!("Couldn't change Open at login: {}", crate::error_message::message(e)))?;
    launcher.is_enabled().map_err(|e| format!("Couldn't read Open at login: {}", crate::error_message::message(e)))
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
    app.opener().reveal_item_in_dir(dir).map_err(crate::error_message::message)
}

#[tauri::command]
pub fn quit(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub fn update_status<R: Runtime>(app: AppHandle<R>, window: tauri::WebviewWindow<R>, state: State<'_, AppState>) -> Result<crate::updater::UpdateInfo, String> {
    if window.label() != "main" {
        return Err("Only the main window can manage updates".into());
    }
    Ok(crate::updater::UpdateInfo { current_version: app.package_info().version.to_string(), status: state.update.status() })
}

#[tauri::command]
pub fn check_for_updates<R: Runtime>(window: tauri::WebviewWindow<R>, state: State<'_, AppState>) -> Result<(), String> {
    if window.label() != "main" {
        return Err("Only the main window can manage updates".into());
    }
    state.update.request();
    Ok(())
}

#[tauri::command]
pub async fn restart_to_update<R: Runtime>(app: AppHandle<R>, window: tauri::WebviewWindow<R>) -> Result<(), String> {
    if window.label() != "main" {
        return Err("Only the main window can manage updates".into());
    }
    let handle = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let state = handle.state::<AppState>();
        let marker = state.dir.join(crate::RESTART_AFTER_UPDATE);
        std::fs::write(&marker, []).map_err(crate::error_message::message)?;
        let result = state.update.install(true, &mut |status| crate::updater::emit(&handle, status));
        if result.is_err() {
            let _ = std::fs::remove_file(marker);
        }
        result
    }).await.map_err(crate::error_message::message)??;
    app.restart();
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
    fn draft_commands_persist_ids_and_deny_quick_capture() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let owned = files::stage_bytes(dir.path(), "owned.txt", b"private").unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![list_drafts, save_draft, unstage_attachment, open_staged_attachment, staged_thumbnail, capture])
            .build(tauri::generate_context!(test = true)).unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let send = |label: &str, cmd: &str, body: serde_json::Value| {
            let window = app.get_webview_window(label).unwrap_or_else(|| WebviewWindowBuilder::new(&app, label, WebviewUrl::default()).build().unwrap());
            get_ipc_response(&window, tauri::webview::InvokeRequest {
                cmd: cmd.into(), callback: tauri::ipc::CallbackFn(0), error: tauri::ipc::CallbackFn(1),
                url: window.url().unwrap(), body: body.into(), headers: Default::default(), invoke_key: INVOKE_KEY.to_string(),
            })
        };
        app.add_capability(r#"{"identifier":"draft-command-test","windows":["quick-capture"],"permissions":["allow-list-drafts","allow-save-draft"]}"#).unwrap();
        let body = serde_json::json!({"place":"home", "text":"", "homeTopicId":null, "attachmentIds":[owned.id]});
        send("main", "save_draft", body.clone()).unwrap();
        assert_eq!(drafts::list(&app.state::<AppState>().db.lock().unwrap()).unwrap().len(), 1);
        for cmd in ["list_drafts", "save_draft", "open_staged_attachment", "staged_thumbnail", "unstage_attachment", "capture"] {
            let args = match cmd {
                "list_drafts" => serde_json::json!({}),
                "save_draft" => body.clone(),
                "capture" => serde_json::json!({"text":"", "attachmentIds":[owned.id], "target":{"kind":"inbox"}, "draft":null}),
                _ => serde_json::json!({"id":owned.id}),
            };
            let error = send("quick-capture", cmd, args).unwrap_err();
            if cmd == "list_drafts" || cmd == "save_draft" {
                assert_eq!(error, serde_json::json!("Only the main window has drafts"));
            }

            assert_eq!(drafts::list(&app.state::<AppState>().db.lock().unwrap()).unwrap().len(), 1);
            assert!(files::staged_open_path(dir.path(), &owned.id).is_ok());
        }
        assert!(send("main", "list_drafts", serde_json::json!({})).is_ok());
    }

    #[test]
    fn a_quick_capture_window_cannot_preview_an_owned_attachment() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let owned = files::stage_bytes(dir.path(), "clip.mp4", b"video").unwrap();
        drafts::save_with_attachments(&conn, dir.path(), "home", "", None, std::slice::from_ref(&owned.id)).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![staged_thumbnail])
            .build(tauri::generate_context!(test = true)).unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let window = WebviewWindowBuilder::new(&app, "quick-capture", WebviewUrl::default()).build().unwrap();
        let error = get_ipc_response(&window, tauri::webview::InvokeRequest {
            cmd: "staged_thumbnail".into(), callback: tauri::ipc::CallbackFn(0), error: tauri::ipc::CallbackFn(1),
            url: window.url().unwrap(), body: serde_json::json!({"id": owned.id}).into(),
            headers: Default::default(), invoke_key: INVOKE_KEY.to_string(),
        }).unwrap_err();
        assert_eq!(error, serde_json::json!("Attachment belongs to another saved Item or draft"));
        assert!(!dir.path().join("thumbnails").exists());
    }

    #[test]
    #[cfg_attr(target_os = "windows", ignore = "Windows CI lacks Media Foundation; run with --ignored on a PC")]
    fn unstaging_during_preview_publication_leaves_no_poster() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let staged = files::stage_bytes(dir.path(), "clip.mp4", include_bytes!("../fixtures/clip.mp4")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder().build(tauri::generate_context!(test = true)).unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let window = WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().unwrap();
        let state = app.state::<AppState>();
        let conn = state.db.lock().unwrap();
        let id = staged.id.clone();
        let worker = std::thread::spawn(move || {
            let handle = window.app_handle().clone();
            let runtime = tokio::runtime::Runtime::new().unwrap();
            let result = runtime.block_on(staged_thumbnail(window, handle.state::<AppState>(), id));
            runtime.shutdown_background();
            result
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        let pending = loop {
            if std::fs::read_dir(dir.path().join("thumbnails")).is_ok_and(|mut entries| entries.next().is_some()) {
                break true;
            }
            if std::time::Instant::now() >= deadline { break false; }
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        files::unstage(&conn, dir.path(), &staged.id).unwrap();
        drop(conn);
        let result = worker.join().unwrap();
        assert!(pending, "preview must reach temporary publication");
        assert!(result.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("thumbnails")).unwrap().count(), 0);
    }

    #[test]
    #[cfg_attr(target_os = "windows", ignore = "Windows CI lacks Media Foundation; run with --ignored on a PC")]
    fn capture_during_staged_publication_leaves_no_untracked_poster() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let staged = files::stage_bytes(dir.path(), "clip.mp4", include_bytes!("../fixtures/clip.mp4")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder().build(tauri::generate_context!(test = true)).unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let window = WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().unwrap();
        let state = app.state::<AppState>();
        let conn = state.db.lock().unwrap();
        let id = staged.id.clone();
        let worker = std::thread::spawn(move || {
            let handle = window.app_handle().clone();
            let runtime = tokio::runtime::Runtime::new().unwrap();
            let result = runtime.block_on(staged_thumbnail(window, handle.state::<AppState>(), id));
            runtime.shutdown_background();
            result
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        let pending = loop {
            if std::fs::read_dir(dir.path().join("thumbnails")).is_ok_and(|mut entries| entries.next().is_some()) {
                break true;
            }
            if std::time::Instant::now() >= deadline { break false; }
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        feed::capture(&conn, dir.path(), "", std::slice::from_ref(&staged.id), &feed::Target::Inbox, None, 1).unwrap();
        drop(conn);
        let result = worker.join().unwrap();
        assert!(pending, "preview must reach temporary publication");
        assert!(result.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("thumbnails")).unwrap().count(), 0);
    }

    #[tokio::test]
    #[cfg_attr(target_os = "windows", ignore = "Windows CI lacks Media Foundation; run with --ignored on a PC")]
    async fn a_staged_poster_is_a_local_jpeg_without_a_cache_row() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let staged = files::stage_bytes(dir.path(), "clip.mp4", include_bytes!("../fixtures/clip.mp4")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder().build(tauri::generate_context!(test = true)).unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let window = WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().unwrap();
        let path = staged_thumbnail(window, app.state::<AppState>(), staged.id.clone()).await.unwrap();
        assert_eq!(std::path::PathBuf::from(&path), dir.path().join("thumbnails").join(format!("{}.jpg", staged.id)));
        let bytes = std::fs::read(path).unwrap();
        assert!(bytes.starts_with(&[0xff, 0xd8]));
        assert!(bytes.len() as u64 <= crate::cache::MAX_THUMBNAIL_BYTES);
        let count: i64 = app.state::<AppState>().db.lock().unwrap().query_row("SELECT COUNT(*) FROM cached_files", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn failed_staged_previews_share_generation_backoff() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let staged = files::stage_bytes(dir.path(), "clip.mp4", b"broken video").unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder().build(tauri::generate_context!(test = true)).unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let window = WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().unwrap();
        let key = format!("preview:{}", staged.id);
        assert_eq!(staged_thumbnail(window.clone(), app.state::<AppState>(), staged.id.clone()).await.unwrap_err(), "No preview");
        let retry = app.state::<AppState>().thumbnail_retries.lock().unwrap()[&key];
        assert_eq!(retry.0, 1);
        assert_eq!(staged_thumbnail(window, app.state::<AppState>(), staged.id).await.unwrap_err(), "No preview");
        assert_eq!(app.state::<AppState>().thumbnail_retries.lock().unwrap()[&key], retry);
    }

    #[test]
    fn only_the_main_window_can_clear_a_draft() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        drafts::save(&conn, "home", "keep me", None).unwrap();
        let owned = files::stage_bytes(dir.path(), "owned.txt", b"private").unwrap();
        drafts::save_with_attachments(&conn, dir.path(), "home", "keep me", None, &[owned.id.clone()]).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![capture])
            .build(tauri::generate_context!(test = true))
            .unwrap();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        let send = |label: &str, draft: Option<&str>, ids: &[String]| {
            let window = app.get_webview_window(label).unwrap_or_else(|| WebviewWindowBuilder::new(&app, label, WebviewUrl::default()).build().unwrap());
            get_ipc_response(
                &window,
                tauri::webview::InvokeRequest {
                    cmd: "capture".into(),
                    callback: tauri::ipc::CallbackFn(0),
                    error: tauri::ipc::CallbackFn(1),
                    url: window.url().unwrap(),
                    body: serde_json::json!({ "text": "note", "attachmentIds": ids, "target": { "kind": "inbox" }, "draft": draft }).into(),
                    headers: Default::default(),
                    invoke_key: INVOKE_KEY.to_string(),
                },
            )
        };
        let stored = || drafts::list(&app.state::<AppState>().db.lock().unwrap()).unwrap().len();

        send("quick-capture", None, &[]).unwrap();
        assert!(send("quick-capture", None, &[owned.id.clone()]).is_err());
        assert!(send("quick-capture", Some("home"), &[owned.id.clone()]).is_err());
        assert_eq!(stored(), 1);
        assert!(send("main", Some("home"), &[owned.id.clone()]).is_ok());
        assert_eq!(stored(), 0);
    }
}
