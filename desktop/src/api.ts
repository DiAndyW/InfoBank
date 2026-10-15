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
};
export type View = { kind: "all" } | { kind: "inbox" } | { kind: "topic"; id: string };
export type SyncStatus = "synced" | "syncing" | "offline" | "unauthorized" | "not_configured";

export const capture = (text: string) => invoke<void>("capture", { text });
// Nested keys aren't renamed by Tauri, so `before` keeps Rust's snake_case.
export const listItems = (view: View, before: { capture_time_us: number; id: string } | null) =>
  invoke<FeedItem[]>("list_items", { view, before });
export const syncStatus = () => invoke<SyncStatus>("sync_status");
