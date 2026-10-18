import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { getSettings, listTopics, sortedTopics, navCounts, restoreItem, syncStatus, type Counts, type Settings as SettingsData, type SyncStatus, type Topic } from "./api";
import DeleteTopic from "./DeleteTopic";
import Dialog from "./Dialog";
import Feed from "./Feed";
import SearchResults from "./SearchResults";
import type { EditorHandle } from "./ItemEditor";
import type { NoticeData } from "./Notice";
import Settings from "./Settings";
import Sidebar from "./Sidebar";
import { Icon } from "./icons";
import { applyTheme, storedTheme } from "./theme";

export default function App() {
  const [settings, setSettings] = useState<SettingsData | null>(null);
  const [editing, setEditing] = useState(false);
  const [topics, setTopics] = useState<Topic[]>([]);
  // "all", "inbox", "trash", or a Topic id.
  const [feed, setFeed] = useState("all");
  const [counts, setCounts] = useState<Counts>({ inbox: 0, trash: 0 });
  const [highlight, setHighlight] = useState<string | null>(null);

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
  const [notice, setNotice] = useState<NoticeData | null>(null);
  const noticeId = useRef(0);
  const show = (message: string, action?: NoticeData["action"]) => setNotice({ id: ++noticeId.current, message, action });
  const editor = useRef<EditorHandle>(null);
  const [searchText, setSearchText] = useState("");
  const [resultsOpen, setResultsOpen] = useState(false);
  const searchField = useRef<HTMLInputElement>(null);
  const searching = searchText.trim() !== "";
  const select = async (key: string) => {
    if (editor.current && !(await editor.current.save())) return false;
    setFeed(key);
    setNotice(null);
    setResultsOpen(false);
    return true;
  };
  const showError = (title: string, err: unknown) => setError({ title, message: String(err) });

  useEffect(() => {
    const unlisten = listen("items-changed", () =>
      Promise.all([listTopics(), navCounts()]).then(
        ([t, c]) => {
          setTopics(sortedTopics(t));
          setCounts(c);
        },
        (e) => showError("Couldn't load Topics", e),
      ),
    );
    return () => {
      unlisten.then((stop) => stop());
    };
  }, []);

  // Only on a Topics change, so selecting a just-created Topic isn't undone before its refresh arrives.
  useEffect(() => {
    if (!["all", "inbox", "trash"].includes(feed) && !topics.some((t) => t.id === feed)) setFeed("inbox");
  }, [topics]);

  useEffect(() => {
    const undo = notice?.action?.label === "Undo" ? notice.action : null;
    if (!undo) return;
    const onKey = (e: KeyboardEvent) => {
      const typing = (e.target as HTMLElement).closest("input, textarea, [contenteditable]");
      if (e.key !== "z" || !(e.metaKey || e.ctrlKey) || e.shiftKey || typing) return;
      e.preventDefault();
      undo.onAction();
      setNotice(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [notice]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "f" || !(e.metaKey || e.ctrlKey) || e.shiftKey) return;
      e.preventDefault();
      searchField.current?.focus();
      searchField.current?.select();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  async function load() {
    try {
      const [s, t, st, c] = await Promise.all([getSettings(), listTopics(), syncStatus(), navCounts()]);
      setSettings(s);
      setTopics(sortedTopics(t));
      setStatus(st);
      setCounts(c);
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
      <Sidebar topics={topics} counts={counts} selected={feed} onSelect={select} status={status} onSettings={() => setEditing(true)} onError={showError} onDelete={setDeleting}
        search={searchText}
        onSearch={(text) => {
          setSearchText(text);
          setResultsOpen(true);
        }}
        onSearchFocus={() => setResultsOpen(true)}
        searchRef={searchField}
      />
      <Feed
        view={feed === "all" || feed === "inbox" || feed === "trash" ? { kind: feed } : { kind: "topic", id: feed }}
        topics={topics}
        covered={searching && resultsOpen}
        editor={editor}
        notice={notice}
        onDismissNotice={() => setNotice(null)}
        onError={showError}
        onTrashed={(id) =>
          show("Item moved to Trash", {
            label: "Undo",
            onAction: () => restoreItem(id).then(() => setHighlight(id), (e) => showError("Couldn't restore the Item", e)),
          })
        }
        onRestored={(it) => {
          const place = topics.find((t) => t.id === it.topic_id);
          show(`Restored to ${place ? place.name : "Inbox"}`, {
            label: "Show",
            onAction: () => {
              select(place ? place.id : "inbox");
              setHighlight(it.id);
            },
          });
        }}
        highlight={highlight}
        onHighlightDone={() => setHighlight(null)}
      />
      {searching && (
        <SearchResults
          text={searchText}
          topics={topics}
          hidden={!resultsOpen}
          onOpen={async (it) => {
            const place = topics.some((t) => t.id === it.topic_id) ? it.topic_id! : "inbox";
            if (await select(place)) setHighlight(it.id);
            // The save failed: uncover the Feed so the editor's error line shows.
            else setResultsOpen(false);
          }}
        />
      )}
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
            show(message);
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
