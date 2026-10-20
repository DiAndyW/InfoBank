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
mod tray;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
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
    notices: Mutex<Vec<sync::SyncNotice>>,
    picking_files: AtomicBool,
    prefetching: AtomicBool,
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
            notices: Mutex::new(Vec::new()),
            picking_files: AtomicBool::new(false),
            prefetching: AtomicBool::new(false),
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

#[derive(serde::Serialize, Clone)]
pub struct StartupError {
    message: String,
    data_dir: Option<String>,
}

fn open_store(dir: &Path) -> Result<rusqlite::Connection, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("Couldn't create the data folder: {e}"))?;
    let db = store::open(&dir.join("notebank.db")).map_err(|e| format!("Couldn't open the database: {e}"))?;
    files::sweep_staged(&db, dir)?;
    cache::sweep_partial_downloads(dir);
    Ok(db)
}

fn show_main_at_launch(args: &[String], failed: bool) -> bool {
    failed || !args.iter().any(|a| a == "--hidden")
}

pub(crate) fn show_main<R: tauri::Runtime>(app: &tauri::AppHandle<R>) {
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show();
        let _ = main.unminimize();
        let _ = main.set_focus();
    }
}

fn start(app: &tauri::AppHandle, dir: &Path) -> Result<(), String> {
    let db = open_store(dir)?;
    let hotkey = shortcut::get(&db)?;
    let keychain = |e: keyring_core::Error| format!("Couldn't open the keychain: {e}");
    #[cfg(target_os = "macos")]
    let store = apple_native_keyring_store::keychain::Store::new().map_err(keychain)?;
    #[cfg(target_os = "windows")]
    let store = windows_native_keyring_store::Store::new().map_err(keychain)?;
    let secret = store.build(&app.config().identifier, "shared-secret", None).map_err(keychain)?;
    app.manage(AppState::new(db, secret, dir.to_path_buf()));
    if hotkey.on {
        use tauri_plugin_global_shortcut::GlobalShortcutExt;
        if let Err(e) = app.global_shortcut().register(shortcut::parse(&hotkey.shortcut)?) {
            eprintln!("Couldn't register the quick-capture shortcut {}: {e}", hotkey.shortcut);
        }
    }
    tray::build(app, &hotkey).map_err(|e| format!("Couldn't create the tray icon: {e}"))?;
    tauri::async_runtime::spawn(sync::run(app.clone()));
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    // macOS never starts a second copy; it sends Reopen instead.
    #[cfg(target_os = "windows")]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, _, _| show_main(app)));
    builder
        .plugin(tauri_plugin_autostart::Builder::new().args(["--hidden"]).build())
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
            // Without AppState nothing else keeps the failure screen's close from leaving a windowless app running.
            if window.label() == "main" && matches!(event, tauri::WindowEvent::CloseRequested { .. }) && window.try_state::<StartupError>().is_some() {
                window.app_handle().exit(0);
                return;
            }
            // try_state: a focus event can arrive before setup has managed the state.
            let Some(state) = window.try_state::<AppState>() else { return };
            match event {
                tauri::WindowEvent::Focused(true) => state.wake.notify_one(),
                tauri::WindowEvent::Focused(false) if window.label() == quick::LABEL => quick::focus_lost(window.app_handle()),
                tauri::WindowEvent::CloseRequested { api, .. } if window.label() == "main" => {
                    api.prevent_close();
                    let _ = window.hide();
                }
                tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) => {
                    stage_dropped(window.app_handle(), window.label().to_string(), state.dir.clone(), paths.clone())
                }
                _ => {}
            }
        })
        .setup(|app| {
            let failure = match app.path().app_data_dir() {
                Err(e) => Some(StartupError { message: format!("Couldn't find the data folder: {e}"), data_dir: None }),
                Ok(dir) => start(app.handle(), &dir)
                    .err()
                    .map(|message| StartupError { message, data_dir: Some(dir.display().to_string()) }),
            };
            let failed = failure.is_some();
            if let Some(failure) = failure {
                app.manage(failure);
            }
            if show_main_at_launch(&std::env::args().collect::<Vec<_>>(), failed) {
                show_main(app.handle());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::list_topics,
            commands::capture,
            commands::move_item,
            commands::edit_item,
            commands::discard_item,
            commands::resolve_conflict,
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
            commands::autostart_on,
            commands::set_autostart,
            commands::dismiss_quick_capture,
            commands::startup_error,
            commands::show_data_folder,
            commands::quit
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            #[cfg(not(target_os = "macos"))]
            let _ = (&app, &event);
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = event {
                show_main(app);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;
    use tauri::{Listener, WebviewUrl, WebviewWindowBuilder};

    fn names(text: &str, start: &str, end: &str, prefix: &str) -> Vec<String> {
        let body = text.split(start).nth(1).unwrap().split(end).next().unwrap();
        let mut found: Vec<String> = body
            .split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '-' || c == ':'))
            .filter_map(|w| w.rsplit(':').next().unwrap().strip_prefix(prefix))
            .filter(|w| !w.is_empty())
            .map(|w| w.replace('-', "_"))
            .collect();
        found.sort();
        found
    }

    #[test]
    fn every_command_is_declared_and_allowed_for_the_main_window_and_the_quick_window_gets_six() {
        let handler = names(include_str!("lib.rs"), "generate_handler![", "]", "");
        let declared = names(include_str!("../build.rs"), "commands(&[", "]", "");
        // The permissions array closes at two-space indent; the opener entry has an inner `]`.
        let main = names(include_str!("../capabilities/default.json"), "\"permissions\"", "\n  ]", "allow-");
        let quick = names(include_str!("../capabilities/quick-capture.json"), "\"permissions\"", "\n  ]", "allow-");
        assert_eq!(declared, handler, "build.rs and generate_handler! disagree");
        assert!(handler.iter().all(|c| main.contains(c)), "the main window can't call every command: {main:?}");
        let mut expected = [
            "capture",
            "dismiss_quick_capture",
            "list_topics",
            "listen",
            "pick_files",
            "stage_attachment_bytes",
            "unlisten",
            "unstage_attachment",
        ]
        .map(String::from)
        .to_vec();
        expected.sort();
        assert_eq!(quick, expected);
    }

    #[test]
    fn the_window_stays_hidden_only_for_a_login_launch_that_started() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(show_main_at_launch(&args(&["notebank"]), false));
        assert!(!show_main_at_launch(&args(&["notebank", "--hidden"]), false));
        assert!(show_main_at_launch(&args(&["notebank", "--hidden"]), true), "a failure was invisible");
    }

    #[test]
    fn a_database_that_cant_be_opened_is_reported() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("notebank.db"), "not a database ".repeat(100)).unwrap();
        let err = open_store(dir.path()).unwrap_err();
        assert!(err.starts_with("Couldn't open the database"), "{err}");
    }

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
