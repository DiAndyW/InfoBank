import { invoke } from "@tauri-apps/api/core";

export type Settings = { server_url: string | null; has_secret: boolean };
export type Topic = { id: string; name: string };

export const getSettings = () => invoke<Settings>("get_settings");
// secret null keeps the stored one.
export const saveSettings = (serverUrl: string, secret: string | null) =>
  invoke<void>("save_settings", { serverUrl, secret });
export const listTopics = () => invoke<Topic[]>("list_topics");

export type FeedItem = {
  id: string;
  text: string | null;
  capture_time_us: number;
  topic_id: string | null;
  pending: boolean;
  attachments: FeedAttachment[];
};
export type View = { kind: "all" } | { kind: "inbox" } | { kind: "topic"; id: string };
export type SyncStatus = "synced" | "syncing" | "offline" | "unauthorized" | "keychain" | "not_configured";

export type FeedAttachment = { id: string; filename: string; mime_type: string; size_bytes: number; has_thumbnail: boolean; runnable: boolean };
export type Staged = { id: string; filename: string; size_bytes: number; mime_type: string };
export type StagedFiles = { staged: Staged[]; errors: string[] };
export const MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;

export const capture = (text: string, attachmentIds: string[]) => invoke<void>("capture", { text, attachmentIds });
export const pickFiles = () => invoke<StagedFiles>("pick_files");
// Headers are ASCII, so the name is percent-encoded; Rust decodes it.
export const stageBytes = (filename: string, bytes: Uint8Array) =>
  invoke<Staged>("stage_attachment_bytes", bytes, { headers: { "X-Filename": encodeURIComponent(filename) } });
export const unstage = (id: string) => invoke<void>("unstage_attachment", { id });
export const thumbnail = (id: string) => invoke<string>("thumbnail", { id });
export const openAttachment = (id: string) => invoke<void>("open_attachment", { id });
export const revealAttachment = (id: string) => invoke<void>("reveal_attachment", { id });
// Nested keys aren't renamed by Tauri, so `before` keeps Rust's snake_case.
export const listItems = (view: View, before: { capture_time_us: number; id: string } | null) =>
  invoke<FeedItem[]>("list_items", { view, before });
export const syncStatus = () => invoke<SyncStatus>("sync_status");
