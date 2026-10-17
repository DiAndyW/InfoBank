import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { getSettings, listTopics, syncStatus, type Settings as SettingsData, type SyncStatus, type Topic } from "./api";
import DeleteTopic from "./DeleteTopic";
import Dialog from "./Dialog";
import Feed from "./Feed";
import Settings from "./Settings";
import Sidebar from "./Sidebar";
import { Icon } from "./icons";
import { applyTheme, storedTheme } from "./theme";

const byName = new Intl.Collator().compare;
const sorted = (topics: Topic[]) => [...topics].sort((a, b) => byName(a.name, b.name));

export default function App() {
  const [settings, setSettings] = useState<SettingsData | null>(null);
  const [editing, setEditing] = useState(false);
  const [topics, setTopics] = useState<Topic[]>([]);
  // "all", "inbox", or a Topic id.
  const [feed, setFeed] = useState("all");

  const [loadError, setLoadError] = useState<string | null>(null);
  const [status, setStatus] = useState<SyncStatus>("synced");
  const [theme, setTheme] = useState(storedTheme);

  useEffect(() => applyTheme(theme), [theme]);

  useEffect(() => {
    const unlisten = listen<SyncStatus>("sync-status", (e) => setStatus(e.payload));
    return () => {
      unlisten.then((stop) => stop());
    };
  }, []);

  const [error, setError] = useState<{ title: string; message: string } | null>(null);
  const [deleting, setDeleting] = useState<Topic | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const select = (key: string) => {
    setFeed(key);
    setNotice(null);
  };
  const showError = (title: string, err: unknown) => setError({ title, message: String(err) });

  useEffect(() => {
    const unlisten = listen("items-changed", () => listTopics().then((t) => setTopics(sorted(t)), (e) => showError("Couldn't load Topics", e)));
    return () => {
      unlisten.then((stop) => stop());
    };
  }, []);

  // Only on a Topics change, so selecting a just-created Topic isn't undone before its refresh arrives.
  useEffect(() => {
    if (feed !== "all" && feed !== "inbox" && !topics.some((t) => t.id === feed)) setFeed("inbox");
  }, [topics]);

  async function load() {
    try {
      const [s, t, st] = await Promise.all([getSettings(), listTopics(), syncStatus()]);
      setSettings(s);
      setTopics(sorted(t));
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
      <div className="nb-empty is-window">
        <Icon name="alert" size={24} />
        <p role="alert" className="nb-empty-title">
          {loadError}
        </p>
        <button className="nb-btn nb-btn-secondary" onClick={load}>
          Try again
        </button>
      </div>
    );
  }
  if (!settings) return null;
  const configured = settings.server_url !== null && settings.has_secret;
  if (!configured) {
    return <Settings initial={settings} theme={theme} onThemeChange={setTheme} onSaved={load} />;
  }
  return (
    <div className="nb-app">
      <Sidebar topics={topics} selected={feed} onSelect={select} status={status} onSettings={() => setEditing(true)} onError={showError} onDelete={setDeleting} />
      <Feed
        view={feed === "all" ? { kind: "all" } : feed === "inbox" ? { kind: "inbox" } : { kind: "topic", id: feed }}
        topics={topics}
        notice={notice}
        onDismissNotice={() => setNotice(null)}
        onError={showError}
      />
      {editing && (
        <Settings
          initial={settings}
          theme={theme}
          onThemeChange={setTheme}
          onSaved={() => {
            setEditing(false);
            load();
          }}
          onCancel={() => setEditing(false)}
        />
      )}
      {deleting && (
        <DeleteTopic
          topic={deleting}
          onClose={() => setDeleting(null)}
          onDeleted={(message) => {
            setDeleting(null);
            setNotice(message);
          }}
          onError={showError}
        />
      )}
      {error && (
        <Dialog
          alert
          title={error.title}
          onClose={() => setError(null)}
          actions={
            <button type="button" className="nb-btn nb-btn-primary" autoFocus onClick={() => setError(null)}>
              OK
            </button>
          }
        >
          <p>{error.message}</p>
        </Dialog>
      )}
    </div>
  );
}
