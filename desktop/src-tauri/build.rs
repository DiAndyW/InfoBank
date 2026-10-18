fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
        "get_settings", "save_settings", "list_topics", "capture", "move_item", "edit_item", "trash_item",
        "restore_item", "nav_counts", "create_topic", "rename_topic", "archive_topic", "unarchive_topic",
        "delete_topic", "pick_files", "stage_attachment_bytes", "unstage_attachment", "thumbnail",
        "open_attachment", "reveal_attachment", "list_items", "search_items", "sync_status",
        "set_quick_capture_shortcut", "set_quick_capture_on", "dismiss_quick_capture", "startup_error",
        "show_data_folder", "quit",
    ])))
    .expect("failed to run tauri-build");
}
