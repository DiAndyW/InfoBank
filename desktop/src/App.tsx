import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { getSettings, listTopics, syncStatus, type Settings as SettingsData, type SyncStatus, type Topic } from "./api";
import Feed from "./Feed";
import Settings from "./Settings";

const STATUS_LABELS: Record<SyncStatus, string> = {
  synced: "● Synced",
  syncing: "↻ Syncing…",
  offline: "○ Offline, retrying",
  unauthorized: "⚠ Secret rejected",
  keychain: "⚠ Keychain access needed",
  not_configured: "",
};

export default function App() {
  const [settings, setSettings] = useState<SettingsData | null>(null);
  const [editing, setEditing] = useState(false);
  const [topics, setTopics] = useState<Topic[]>([]);
  // "all", "inbox", or a Topic id.
  const [feed, setFeed] = useState("all");

  const [loadError, setLoadError] = useState<string | null>(null);
  const [status, setStatus] = useState<SyncStatus>("synced");

  useEffect(() => {
    const unlisten = listen<SyncStatus>("sync-status", (e) => setStatus(e.payload));
    return () => {
      unlisten.then((stop) => stop());
    };
  }, []);

  async function load() {
    try {
      const [s, t, st] = await Promise.all([getSettings(), listTopics(), syncStatus()]);
      setSettings(s);
      setTopics(t);
      setStatus(st);
      setLoadError(null);
    } catch (err) {
      setLoadError(String(err));
    }
  }

  useEffect(() => {
    load();
  }, []);

  if (loadError) {
    return (
      <div className="empty load-error">
        <p role="alert">{loadError}</p>
        <button onClick={load}>Try again</button>
      </div>
    );
  }
  if (!settings) return null;
  const configured = settings.server_url !== null && settings.has_secret;
  if (!configured || editing) {
    return (
      <Settings
        initial={settings}
        onSaved={() => {
          setEditing(false);
          load();
        }}
        onCancel={configured ? () => setEditing(false) : undefined}
      />
    );
  }

  const entry = (key: string, label: string) => (
    <button key={key} className={feed === key ? "selected" : undefined} onClick={() => setFeed(key)}>
      {label}
    </button>
  );

  return (
    <div className="app">
      <nav className="sidebar">
        {entry("all", "All Items")}
        {entry("inbox", "Inbox")}
        <h2>Topics</h2>
        {topics.length === 0 ? <p className="hint">None yet</p> : topics.map((t) => entry(t.id, t.name))}
        {status === "unauthorized" ? (
          <button className="status warn" onClick={() => setEditing(true)}>
            ⚠ Secret rejected
          </button>
        ) : (
          <p className="status">{STATUS_LABELS[status]}</p>
        )}
        <button className="settings-button" onClick={() => setEditing(true)}>
          Settings
        </button>
      </nav>
      <Feed view={feed === "all" ? { kind: "all" } : feed === "inbox" ? { kind: "inbox" } : { kind: "topic", id: feed }} />
    </div>
  );
}
