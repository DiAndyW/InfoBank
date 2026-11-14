import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { getSettings, itemTarget, listTopics, moveItem, navCounts, quit, restoreItem, showDataFolder, startupError, syncStatus, updateStatus, checkForUpdates, restartToUpdate, type UpdateInfo, type UpdateStatus, type Counts, type FeedItem, type Settings as SettingsData, type StartupFailure, type SyncNotice, type SyncStatus, type Topic, type Target } from "./api";
import type { ComposerHandle } from "./Composer";
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
  // Home or a feed place.
  const [feed, setFeed] = useState(() => {
    const saved = localStorage.getItem("place");
    return saved === "all" ? "home" : saved ?? "home";
  });
  const [counts, setCounts] = useState<Counts>({ inbox: 0, tunnel: 0, trash: 0 });
  const [sidebarOpen, setSidebarOpen] = useState(() => localStorage.getItem("sidebarOpen") !== "false");
  const sidebarSlot = useRef<HTMLDivElement>(null);
  const beforeSearch = useRef<boolean | null>(null);
  const focusSearch = useRef(false);
  const focusAfterLayout = useRef(false);
  const sidebarToggle = useRef<HTMLButtonElement>(null);
  const [highlight, setHighlight] = useState<string | null>(null);

  const [startup, setStartup] = useState<StartupFailure | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [status, setStatus] = useState<SyncStatus>("synced");
  // Rust only announces a change, so a stale read that lands after one would stick.
  const statusEvents = useRef(0);
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const latestUpdate = useRef<UpdateStatus | null>(null);
  const [theme, setTheme] = useState(storedTheme);

  useEffect(() => applyTheme(theme), [theme]);

  useEffect(() => {
    const unlisten = listen<UpdateStatus>("update-status", (e) => {
      latestUpdate.current = e.payload;
      setUpdate((current) => current ? { ...current, status: e.payload } : current);
    });
    return () => { unlisten.then((stop) => stop()); };
  }, []);

  useEffect(() => {
    const unlisten = listen<SyncStatus>("sync-status", (e) => {
      statusEvents.current++;
      setStatus(e.payload);
    });
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
  const composer = useRef<ComposerHandle>(null);
  const [restartFiles, setRestartFiles] = useState(0);
  const restarting = useRef(false);
  const [searchText, setSearchText] = useState("");
  const [resultsOpen, setResultsOpen] = useState(false);
  const searchField = useRef<HTMLInputElement>(null);
  const searching = searchText.trim() !== "";
  const covered = searching && resultsOpen;
  const dialogOpen = () => document.querySelector('[aria-modal="true"]') !== null;
  const focusEditor = () => {
    if (editor.current) editor.current.focus();
    else (document.querySelector<HTMLTextAreaElement>(".nb-composer textarea") ?? sidebarToggle.current)?.focus();
  };
  const toggleSidebar = () => {
    if (sidebarOpen) {
      focusAfterLayout.current = !!sidebarSlot.current?.contains(document.activeElement);
      setResultsOpen(false);
    }
    beforeSearch.current = null;
    setSidebarOpen(!sidebarOpen);
    localStorage.setItem("sidebarOpen", String(!sidebarOpen));
  };
  const openSearch = () => {
    if (beforeSearch.current === null) beforeSearch.current = sidebarOpen;
    if (!sidebarOpen) {
      focusSearch.current = true;
      setSidebarOpen(true);
    } else {
      searchField.current?.focus();
      searchField.current?.select();
    }
  };
  useLayoutEffect(() => {
    if (focusAfterLayout.current && !covered) {
      focusAfterLayout.current = false;
      focusEditor();
    }
    if (sidebarOpen && focusSearch.current && searchField.current) {
      focusSearch.current = false;
      searchField.current.focus();
      searchField.current.select();
    }
  }, [sidebarOpen, covered, settings]);
  const select = async (key: string) => {
    if (editor.current && !(await editor.current.save())) return false;
    setFeed(key);
    localStorage.setItem("place", key);
    setNotice(null);
    setResultsOpen(false);
    return true;
  };
  const showError = (title: string, err: unknown) => setError({ title, message: String(err) });
  async function restart(confirmedFiles = 0) {
    composer.current?.freeze(true);
    try {
      await Promise.all([composer.current?.saveDrafts(), composer.current?.waitForStaging()]);
    } catch (err) {
      restarting.current = false;
      composer.current?.freeze(false);
      showError("Couldn't save your drafts", err);
      return;
    }
    const files = composer.current?.unsentFiles() ?? 0;
    if (files > confirmedFiles) {
      setRestartFiles(files);
      return;
    }
    try {
      await restartToUpdate();
    } catch (err) {
      composer.current?.freeze(false);
      showError("Couldn't update", err);
    } finally {
      restarting.current = false;
    }
  }
  const cancelRestart = () => {
    composer.current?.freeze(false);
    setRestartFiles(0);
    restarting.current = false;
  };
  const onRestart = () => {
    if (restarting.current) return;
    restarting.current = true;
    const files = composer.current?.unsentFiles() ?? 0;
    if (files > 0) setRestartFiles(files);
    else void restart();
  };
  const onCheckForUpdates = () => { checkForUpdates().catch((err) => showError("Couldn't update", err)); };
  const [dragging, setDragging] = useState<{ item: FeedItem; x: number; y: number } | null>(null);
  const [dropOn, setDropOn] = useState<string | null>(null);

  const move = (it: FeedItem, target: Target, newTopicName?: string) =>
    moveItem(it.id, target).then(
      () => {
        const place = topics.find((t) => target.kind === "topic" && t.id === target.id)?.name ?? newTopicName;
        show(target.kind === "tunnel" ? "Moved to the Tunnel" : place ? `Moved to ${place}` : "Moved to the Inbox", {
          label: "Undo",
          onAction: () => moveItem(it.id, itemTarget(it)).then(() => setHighlight(it.id), (e) => showError("Couldn't move the Item back", e)),
        });
      },
      (e) => showError("Couldn't move the Item", e),
    );

  useEffect(() => {
    if (!dragging) return;
    const end = () => {
      setDragging(null);
      setDropOn(null);
    };
    const drop = () => {
      if (dropOn) move(dragging.item, dropOn === "inbox" || dropOn === "tunnel" ? { kind: dropOn } : { kind: "topic", id: dropOn });
      end();
    };
    const cancel = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      end();
    };
    window.addEventListener("pointerup", drop);
    window.addEventListener("pointercancel", end);
    window.addEventListener("keydown", cancel, true);
    document.documentElement.classList.add("nb-dragging");
    return () => {
      window.removeEventListener("pointerup", drop);
      window.removeEventListener("pointercancel", end);
      window.removeEventListener("keydown", cancel, true);
      document.documentElement.classList.remove("nb-dragging");
    };
  }, [dragging, dropOn]);

  useEffect(() => {
    const unlisten = listen<SyncNotice[]>("sync-notices", (e) => {
      const n = e.payload[e.payload.length - 1];
      if (!n) return;
      const sentence = {
        move: n.topic_deleted
          ? `Couldn't move "${n.label}" to ${n.topic}: it was deleted on another Device.`
          : `Couldn't move "${n.label}" to ${n.topic}: it isn't on this Server.`,
        inbox: n.topic == null || !n.topic_deleted
          ? `Saved "${n.label}" to the Inbox: its Topic isn't on this Server.`
          : `Saved "${n.label}" to the Inbox: ${n.topic} was deleted on another Device.`,
        empty: `Couldn't restore "${n.label}": it has no text or files left.`,
        gone: `Couldn't save your change to "${n.label}": it was deleted for good on another Device.`,
        failed: "The Server refused this change. Its version will be restored when sync completes.",
        topic: "The Server refused a Topic change. Its current version has been kept.",
        topicRenamed: "A Topic name was already in use. The Server gave it a unique name.",
      }[n.kind];
      const more = e.payload.length > 1 ? ` And ${e.payload.length - 1} more.` : "";
      const showable = n.kind === "move" || n.kind === "inbox" || (n.kind === "failed" && n.item_id !== "");
      show(
        sentence + more,
        showable
          ? {
              label: "Show",
              onAction: () => {
                select(n.place ?? "inbox");
                setHighlight(n.item_id);
              },
            }
          : undefined,
      );
    });
    return () => {
      unlisten.then((stop) => stop());
    };
  }, []);

  useEffect(() => {
    const unlisten = listen("items-changed", () =>
      Promise.all([listTopics(), navCounts()]).then(
        ([t, c]) => {
          setTopics(t);
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
    if (!settings) return;
    if (!["home", "inbox", "tunnel", "trash"].includes(feed) && !topics.some((t) => t.id === feed)) {
      setFeed("home");
      localStorage.setItem("place", "home");
    }
  }, [topics, !!settings]);

  useEffect(() => {
    const undo = notice?.action?.label === "Undo" ? notice.action : null;
    const undoID = notice?.id;
    if (!undo || editing || (covered && !notice?.inSearch)) return;
    const onKey = (e: KeyboardEvent) => {
      const typing = (e.target as HTMLElement).closest("input, textarea, [contenteditable]");
      if (e.key !== "z" || !(e.metaKey || e.ctrlKey) || e.shiftKey || dialogOpen()) return;
      if (e.defaultPrevented) {
        if (notice?.message === "Cleared") setNotice(current => current?.id === undoID ? null : current);
        return;
      }
      if (typing) return;
      e.preventDefault();
      void Promise.resolve(undo.onAction()).then(result => { if (result !== false) setNotice(current => current?.id === undoID ? null : current); });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [notice, editing, covered]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey || e.isComposing || dialogOpen()) return;
      if (e.key === "\\") {
        e.preventDefault();
        toggleSidebar();
      } else if (e.key === "f") {
        e.preventDefault();
        openSearch();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [sidebarOpen]);

  async function load() {
    try {
      const failure = await startupError();
      if (failure) return setStartup(failure);
      const seen = statusEvents.current;
      const [s, t, st, c, u] = await Promise.all([getSettings(), listTopics(), syncStatus(), navCounts(), updateStatus()]);
      setSettings(s);
      setTopics(t);
      if (statusEvents.current === seen) setStatus(st);
      setCounts(c);
      setUpdate({ ...u, status: latestUpdate.current ?? u.status });
      setLoadError(null);
    } catch (err) {
      setLoadError(String(err));
    }
  }

  useEffect(() => {
    load();
  }, []);

  if (startup) {
    return (
      <div className="nb-empty is-window">
        <Icon name="alert" size={24} />
        <p className="nb-empty-title">NoteBank couldn't start</p>
        <p role="alert">{startup.message}</p>
        {startup.data_dir && <p className="nb-empty-hint">Your data is in {startup.data_dir}</p>}
        <div className="nb-dialog-actions">
          {startup.data_dir && (
            <button className="nb-btn nb-btn-secondary" onClick={() => showDataFolder().catch(() => {})}>
              Show folder
            </button>
          )}
          <button className="nb-btn nb-btn-primary" onClick={() => quit()}>
            Quit
          </button>
        </div>
      </div>
    );
  }
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
  const errorDialog = error && (
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
  );
  if (!configured) {
    return <><Settings initial={settings} theme={theme} onThemeChange={setTheme} onSaved={load} update={update} onCheckForUpdates={onCheckForUpdates} onRestart={onRestart} />{errorDialog}</>;
  }
  return (
    <div className={`nb-app${sidebarOpen ? "" : " is-sidebar-collapsed"}`}>
      <div className="nb-sidebar-slot" ref={sidebarSlot}>
        <Sidebar topics={topics} counts={counts} selected={feed} onSelect={select} status={status} update={update?.status ?? { state: "off" }} onRestart={onRestart} onSettings={() => setEditing(true)} onDelete={setDeleting}
          collapsed={!sidebarOpen}
          toggle={<button ref={sidebarToggle} type="button" className="nb-iconbtn" aria-label={sidebarOpen ? "Hide sidebar" : "Show sidebar"}
            title={`${sidebarOpen ? "Hide" : "Show"} sidebar (⌘\\)`} aria-expanded={sidebarOpen} aria-controls="sidebar-content" onClick={toggleSidebar}>
            <Icon name="sidebar" />
          </button>}
          search={searchText}
          drag={dragging && { from: dragging.item.in_tunnel ? "tunnel" : dragging.item.topic_id ?? "inbox", over: dropOn }}
          onDragOver={setDropOn}
          onSearch={(text) => {
            setSearchText(text);
            setResultsOpen(true);
          }}
          onSearchFocus={() => setResultsOpen(true)}
          onSearchEscape={(empty) => {
            if (empty && beforeSearch.current !== null) {
              setSidebarOpen(beforeSearch.current);
              beforeSearch.current = null;
            }
            if (covered) focusAfterLayout.current = true;
            else focusEditor();
          }}
          searchRef={searchField}
        />
      </div>
      <Feed
        home={feed === "home"}
        view={feed === "home" ? { kind: "all" } : feed === "inbox" || feed === "tunnel" || feed === "trash" ? { kind: feed } : { kind: "topic", id: feed }}
        topics={topics}
        covered={covered}
        editor={editor}
        composer={composer}
        notice={notice}
        onDismissNotice={() => setNotice(null)}
        onNotice={show}
        onError={showError}
        onTrashed={(id, copied = false) =>
          show(copied ? "Copied, moved to Trash" : "Item moved to Trash", {
            label: "Undo",
            onAction: () => restoreItem(id).then(() => setHighlight(id), (e) => showError("Couldn't restore the Item", e)),
          })
        }
        onMove={move}
        onDragStart={(item, x, y) => setDragging({ item, x, y })}
        onRestored={(it) => {
          const place = topics.find((t) => t.id === it.topic_id);
          show(`Restored to ${it.in_tunnel ? "Tunnel" : place ? place.name : "Inbox"}`, {
            label: "Show",
            onAction: () => {
              select(it.in_tunnel ? "tunnel" : place ? place.id : "inbox");
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
          startPlace={feed === "home" || feed === "trash" ? "all" : feed}
          hidden={!resultsOpen}
          notice={notice?.inSearch ? notice : null}
          onNotice={(message, action) => setNotice({ id: ++noticeId.current, message, action, inSearch: true })}
          onError={showError}
          onDismissNotice={() => setNotice(null)}
          onOpenTopic={async (topic) => {
            if (!(await select(topic.id))) setResultsOpen(false);
          }}
          onOpen={async (it) => {
            const place = it.in_tunnel ? "tunnel" : topics.some((t) => t.id === it.topic_id) ? it.topic_id! : "inbox";
            if (await select(place)) setHighlight(it.id);
            // The save failed: uncover the Feed so the editor's error line shows.
            else setResultsOpen(false);
          }}
        />
      )}
      {editing && (
        <Settings
          initial={settings}
          update={update}
          onCheckForUpdates={onCheckForUpdates}
          onRestart={onRestart}
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
      {restartFiles > 0 && (
        <Dialog alert title={`Restart and remove ${restartFiles} unsent ${restartFiles === 1 ? "file" : "files"}?`}
          hint="Files you attached but haven't sent aren't kept across a restart."
          onClose={cancelRestart}
          actions={<>
            <button type="button" className="nb-btn nb-btn-secondary" autoFocus onClick={cancelRestart}>Cancel</button>
            <button type="button" className="nb-btn nb-btn-primary" onClick={() => { setRestartFiles(0); void restart(restartFiles); }}>Restart</button>
          </>}
        />
      )}
      {errorDialog}
      {dragging && <DragCard item={dragging.item} x={dragging.x} y={dragging.y} />}
    </div>
  );
}

function DragCard({ item, x, y }: { item: FeedItem; x: number; y: number }) {
  const [at, setAt] = useState({ x, y });
  useEffect(() => {
    const follow = (e: PointerEvent) => setAt({ x: e.clientX, y: e.clientY });
    window.addEventListener("pointermove", follow);
    return () => window.removeEventListener("pointermove", follow);
  }, []);
  const label = item.text?.split("\n")[0] || item.attachments[0]?.filename || "Item";
  return (
    <div className="nb-drag-card" style={{ left: at.x + 12, top: at.y + 8 }}>
      {label}
    </div>
  );
}
