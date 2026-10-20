fn main() {
    let mut windows = tauri_build::WindowsAttributes::new();
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        // Test binaries need the Common Controls v6 manifest too (rfd imports TaskDialogIndirect), and
        // tauri-build only embeds it in the app binary.
        windows = tauri_build::WindowsAttributes::new_without_app_manifest();
        let manifest = std::env::current_dir().unwrap().join("windows-app-manifest.xml");
        println!("cargo:rerun-if-changed={}", manifest.display());
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTINPUT:{}", manifest.display());
    }
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows).app_manifest(tauri_build::AppManifest::new().commands(&[
        "get_settings", "save_settings", "list_topics", "capture", "move_item", "edit_item", "trash_item",
        "restore_item", "nav_counts", "create_topic", "rename_topic", "archive_topic", "unarchive_topic",
        "delete_topic", "pick_files", "stage_attachment_bytes", "unstage_attachment", "thumbnail",
        "open_attachment", "reveal_attachment", "list_items", "search_items", "sync_status",
        "set_quick_capture_shortcut", "set_quick_capture_on", "autostart_on", "set_autostart", "dismiss_quick_capture", "startup_error",
        "show_data_folder", "quit",
    ])))
    .expect("failed to run tauri-build");
}
