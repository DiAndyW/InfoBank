import { useEffect, useState } from "react";
import { getSettings, listTopics, type Settings as SettingsData, type Topic } from "./api";
import Settings from "./Settings";

export default function App() {
  const [settings, setSettings] = useState<SettingsData | null>(null);
  const [editing, setEditing] = useState(false);
  const [topics, setTopics] = useState<Topic[]>([]);
  // "all", "inbox", or a Topic id.
  const [feed, setFeed] = useState("all");

  async function load() {
    const [s, t] = await Promise.all([getSettings(), listTopics()]);
    setSettings(s);
    setTopics(t);
  }

  useEffect(() => {
    load();
  }, []);

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
        <button className="settings-button" onClick={() => setEditing(true)}>
          Settings
        </button>
      </nav>
      <main className="feed">
        <div className="empty">
          <p>Nothing here yet.</p>
          <p className="hint">Capture something below.</p>
        </div>
        <form className="composer" onSubmit={(e) => e.preventDefault()}>
          <textarea placeholder="Write something…" rows={2} />
          <button type="submit" disabled>
            Send
          </button>
        </form>
      </main>
    </div>
  );
}
