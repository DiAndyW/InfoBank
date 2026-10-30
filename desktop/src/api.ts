import { invoke } from "@tauri-apps/api/core";

// shortcut is the stored form, e.g. "shift+super+Space"; it is kept while quick capture is off.
export type Hotkey = { shortcut: string; on: boolean };
export type Settings = { server_url: string | null; has_secret: boolean; quick_capture: Hotkey };
export type Topic = { id: string; name: string; archived: boolean; item_count: number };
export type Keep = { kind: "all" } | { kind: "none" } | { kind: "only"; ids: string[] };

export const getSettings = () => invoke<Settings>("get_settings");
export const autostartOn = () => invoke<boolean>("autostart_on");
export const setAutostart = (on: boolean) => invoke<boolean>("set_autostart", { on });
// secret null keeps the stored one.
export const saveSettings = (serverUrl: string, secret: string | null) =>
  invoke<void>("save_settings", { serverUrl, secret });
export const listTopics = () => invoke<Topic[]>("list_topics");
export const createTopic = (name: string) => invoke<Topic>("create_topic", { name });
export const renameTopic = (id: string, name: string) => invoke<void>("rename_topic", { id, name });
export const archiveTopic = (id: string) => invoke<void>("archive_topic", { id });
export const unarchiveTopic = (id: string) => invoke<void>("unarchive_topic", { id });
export const deleteTopic = (id: string, keep: Keep) => invoke<void>("delete_topic", { id, keep });

export type FeedItem = {
  id: string;
  text: string | null;
  capture_time_us: number;
  topic_id: string | null;
  in_tunnel: boolean;
  pending: boolean;
  attachments: FeedAttachment[];
  purge_at_us: number | null;
  edit_base: number;
  sync_error: string | null;
  conflict: { text: string | null; mine: boolean } | null;
};
export type Target = { kind: "inbox" } | { kind: "tunnel" } | { kind: "topic"; id: string };
export const itemTarget = (item: FeedItem): Target => item.in_tunnel ? { kind: "tunnel" } : item.topic_id ? { kind: "topic", id: item.topic_id } : { kind: "inbox" };
export type View = { kind: "all" } | { kind: "inbox" } | { kind: "tunnel" } | { kind: "trash" } | { kind: "topic"; id: string };
export type Counts = { inbox: number; tunnel: number; trash: number };
export type SyncNotice = {
  kind: "move" | "inbox" | "empty" | "gone";
  item_id: string;
  label: string;
  topic: string | null;
  topic_state: "archived" | "deleted" | null;
  place: string | null;
};
export type SyncStatus = "synced" | "syncing" | "offline" | "unauthorized" | "keychain" | "not_configured";

export type FeedAttachment = { id: string; filename: string; mime_type: string; size_bytes: number; has_thumbnail: boolean; runnable: boolean };
export type Staged = { id: string; filename: string; size_bytes: number; mime_type: string };
export type StagedFiles = { staged: Staged[]; errors: string[] };
export const MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;

export const moveItem = (itemId: string, target: Target) => invoke<void>("move_item", { itemId, target });
export const editItem = (itemId: string, text: string, addIds: string[], removeIds: string[], baseRev: number) =>
  invoke<{ trashed: boolean }>("edit_item", { itemId, text, addIds, removeIds, baseRev });
export const discardItem = (itemId: string) => invoke<void>("discard_item", { itemId });
export const resolveConflict = (itemId: string, keep: "theirs" | "mine") =>
  invoke<{ trashed: boolean }>("resolve_conflict", { itemId, keep });
export const trashItem = (itemId: string) => invoke<void>("trash_item", { itemId });
export const restoreItem = (itemId: string) => invoke<void>("restore_item", { itemId });
export const navCounts = () => invoke<Counts>("nav_counts");
export const capture = (text: string, attachmentIds: string[], target: Target) =>
  invoke<void>("capture", { text, attachmentIds, target });
export const doubleClickIntervalMs = () => invoke<number>("double_click_interval_ms");
export const trashAfterCopy = () => invoke<boolean | null>("trash_after_copy");
export const setTrashAfterCopy = (on: boolean) => invoke<void>("set_trash_after_copy", { on });
export const pickFiles = () => invoke<StagedFiles>("pick_files");
// Headers are ASCII, so the name is percent-encoded; Rust decodes it.
export const stageBytes = (filename: string, bytes: Uint8Array) =>
  invoke<Staged>("stage_attachment_bytes", bytes, { headers: { "X-Filename": encodeURIComponent(filename) } });
export const unstage = (id: string) => invoke<void>("unstage_attachment", { id });
export const thumbnail = (id: string) => invoke<string>("thumbnail", { id });
export const copyWholeItem = (itemId: string) => invoke<void>("copy_item", { itemId });
export const openAttachment = (id: string) => invoke<void>("open_attachment", { id });
export const revealAttachment = (id: string) => invoke<void>("reveal_attachment", { id });
export type Before = { capture_time_us: number; id: string };
// Nested keys aren't renamed by Tauri, so `before` and `query` keep Rust's snake_case.
export const listItems = (view: View, before: Before | null) => invoke<FeedItem[]>("list_items", { view, before });
export type Place = { kind: "all" } | Target;
export type SearchQuery = { text: string; place: Place; from_us: number | null; to_us: number | null; has_files: boolean };
// Matches arrive wrapped in U+E000 … U+E001; marked_filenames follows attachments' order.
export type SearchItem = FeedItem & { marked_text: string | null; marked_filenames: string[] };
export const searchItems = (query: SearchQuery, before: Before | null) => invoke<SearchItem[]>("search_items", { query, before });
export const syncStatus = () => invoke<SyncStatus>("sync_status");
export const dismissQuickCapture = () => invoke<void>("dismiss_quick_capture");
export const setQuickCaptureShortcut = (shortcut: string) => invoke<Hotkey>("set_quick_capture_shortcut", { shortcut });
export const setQuickCaptureOn = (on: boolean) => invoke<Hotkey>("set_quick_capture_on", { on });
const byName = new Intl.Collator().compare;
export const sortedTopics = (topics: Topic[]) => [...topics].sort((a, b) => byName(a.name, b.name));

export type StartupFailure = { message: string; data_dir: string | null };
export const startupError = () => invoke<StartupFailure | null>("startup_error");
export const showDataFolder = () => invoke<void>("show_data_folder");
export const quit = () => invoke<void>("quit");
