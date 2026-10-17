import { useRef, useState } from "react";
import { archiveTopic, createTopic, renameTopic, unarchiveTopic, type SyncStatus, type Topic } from "./api";
import Menu from "./Menu";

const STATUS_LABELS: Record<SyncStatus, string> = {
  synced: "● Synced",
  syncing: "↻ Syncing…",
  offline: "○ Offline, retrying",
  unauthorized: "⚠ Secret rejected",
  keychain: "⚠ Keychain access needed",
  not_configured: "",
};

type Props = {
  topics: Topic[];
  selected: string;
  onSelect: (key: string) => void;
  status: SyncStatus;
  onSettings: () => void;
  onError: (title: string, err: unknown) => void;
  onDelete: (topic: Topic) => void;
};

export default function Sidebar({ topics, selected, onSelect, status, onSettings, onError, onDelete }: Props) {
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  // id null = a new Topic.
  const [naming, setNaming] = useState<{ id: string | null; draft: string; error: string | null } | null>(null);
  const saving = useRef(false);

  async function saveName() {
    if (!naming || saving.current) return;
    saving.current = true;
    try {
      if (naming.id === null) onSelect((await createTopic(naming.draft)).id);
      else await renameTopic(naming.id, naming.draft);
      setNaming(null);
    } catch (err) {
      setNaming({ ...naming, error: String(err) });
    } finally {
      saving.current = false;
    }
  }

  const nameField = naming && (
    <div className="name-field" key="name-field">
      <input
        aria-label="Topic name"
        placeholder="New Topic"
        autoFocus
        value={naming.draft}
        onChange={(e) => setNaming({ ...naming, draft: e.target.value, error: null })}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.nativeEvent.isComposing) {
            e.preventDefault();
            saveName();
          } else if (e.key === "Escape") {
            setNaming(null);
          }
        }}
        onBlur={() => saving.current || setNaming(null)}
      />
      {naming.error && <p role="alert">{naming.error}</p>}
    </div>
  );
  const open = topics.filter((t) => !t.archived);
  const archived = topics.filter((t) => t.archived);

  const entry = (key: string, label: string) => (
    <button className={selected === key ? "selected" : undefined} onClick={() => onSelect(key)}>
      {label}
    </button>
  );

  const row = (t: Topic) => {
    if (naming?.id === t.id) return nameField;
    const rename = { label: "Rename", onSelect: () => setNaming({ id: t.id, draft: t.name, error: null }) };
    const remove = { label: "Delete…", onSelect: () => onDelete(t) };
    return (
      <div key={t.id} className={t.archived ? "topic-row archived" : "topic-row"}>
        {entry(t.id, t.name)}
        <Menu
          label={`${t.name} actions`}
          open={menuFor === t.id}
          onOpenChange={(o) => setMenuFor(o ? t.id : null)}
          entries={
            t.archived
              ? [rename, { label: "Unarchive", onSelect: () => unarchiveTopic(t.id).catch((e) => onError("Couldn't unarchive the Topic", e)) }, remove]
              : [rename, { label: "Archive", onSelect: () => archiveTopic(t.id).catch((e) => onError("Couldn't archive the Topic", e)) }, remove]
          }
        />
      </div>
    );
  };

  return (
    <nav className="sidebar">
      {entry("all", "All Items")}
      {entry("inbox", "Inbox")}
      <div className="topics-heading">
        <h2>Topics</h2>
        <button aria-label="New Topic" onClick={() => setNaming({ id: null, draft: "", error: null })}>
          +
        </button>
      </div>
      <div className="topic-list">
        {open.length === 0 && naming?.id !== null ? <p className="hint">None yet</p> : open.map(row)}
        {naming?.id === null && nameField}
        {archived.length > 0 && (
          <>
            <button className="archived-toggle" aria-expanded={showArchived} onClick={() => setShowArchived(!showArchived)}>
              <span aria-hidden="true">{showArchived ? "▾ " : "▸ "}</span>
              Archived ({archived.length})
            </button>
            {showArchived && archived.map(row)}
          </>
        )}
      </div>
      {status === "unauthorized" ? (
        <button className="status warn" onClick={onSettings}>
          ⚠ Secret rejected
        </button>
      ) : (
        <p className="status">{STATUS_LABELS[status]}</p>
      )}
      <button className="settings-button" onClick={onSettings}>
        Settings
      </button>
    </nav>
  );
}
