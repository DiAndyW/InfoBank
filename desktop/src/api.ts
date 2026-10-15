import { invoke } from "@tauri-apps/api/core";

export type Settings = { server_url: string | null; has_secret: boolean };
export type Topic = { id: string; name: string };

export const getSettings = () => invoke<Settings>("get_settings");
// secret null keeps the stored one.
export const saveSettings = (serverUrl: string, secret: string | null) =>
  invoke<void>("save_settings", { serverUrl, secret });
export const listTopics = () => invoke<Topic[]>("list_topics");
