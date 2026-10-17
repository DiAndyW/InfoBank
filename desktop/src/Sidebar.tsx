import { useEffect, useRef, useState, type RefObject } from "react";
import { archiveTopic, createTopic, renameTopic, unarchiveTopic, type Counts, type SyncStatus, type Topic } from "./api";
import { Icon, type IconName } from "./icons";
import Menu from "./Menu";

const STATUS: Record<Exclude<SyncStatus, "unauthorized" | "not_configured">, [IconName, string, string]> = {
  synced: ["synced", "Synced", "nb-sync-ok"],
  syncing: ["syncing", "Syncing…", ""],
  offline: ["offline", "Offline, retrying", ""],
  keychain: ["key", "Keychain access needed", "nb-sync-warn"],
};

type Props = {
  topics: Topic[];
  counts: Counts;
  selected: string;
  onSelect: (key: string) => void;
  status: SyncStatus;
  onSettings: () => void;
  onError: (title: string, err: unknown) => void;
  onDelete: (topic: Topic) => void;
  search: string;
  onSearch: (text: string) => void;
  onSearchFocus: () => void;
  searchRef: RefObject<HTMLInputElement | null>;
};

export default function Sidebar({ topics, counts, selected, onSelect, status, onSettings, onError, onDelete, search, onSearch, onSearchFocus, searchRef }: Props) {
  // The field shows what's typed even mid-composition; the query only follows once the input method is done.
  const [draft, setDraft] = useState(search);
  const composing = useRef(false);
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  // id null = a new Topic.
  const [naming, setNaming] = useState<{ id: string | null; draft: string; error: string | null } | null>(null);
  const open = topics.filter((t) => !t.archived);
  const archived = topics.filter((t) => t.archived);
  const saving = useRef(false);
  const nav = useRef<HTMLElement>(null);
  const plus = useRef<HTMLButtonElement>(null);
  // A Topic whose row should take focus once it's on screen (a new one arrives with the next Topics refresh).
  const focusRow = useRef<string | null>(null);

  useEffect(() => {
    if (archived.some((t) => t.id === selected)) setShowArchived(true);
  }, [selected, topics]);

  useEffect(() => {
    if (focusRow.current === null) return;
    const row = nav.current!.querySelector<HTMLElement>(`[data-topic="${CSS.escape(focusRow.current)}"]`);
    if (!row) return;
    row.focus();
    focusRow.current = null;
  }, [topics, naming, showArchived]);

  async function saveName() {
    if (!naming || saving.current) return;
    saving.current = true;
    try {
      if (naming.id === null) {
        const created = await createTopic(naming.draft);
        focusRow.current = created.id;
        onSelect(created.id);
      } else {
        await renameTopic(naming.id, naming.draft);
        focusRow.current = naming.id;
      }
      setNaming(null);
    } catch (err) {
      setNaming({ ...naming, error: String(err) });
    } finally {
      saving.current = false;
    }
  }

  const nameField = naming && (
    <div className={naming.error ? "nb-namefield has-error" : "nb-namefield"} key="name-field">
      <input
        className="nb-input"
        aria-invalid={naming.error ? true : undefined}
        aria-label="Topic name"
        placeholder="New Topic"
        autoFocus
        value={naming.draft}
        onChange={(e) => setNaming({ ...naming, draft: e.target.value, error: null })}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.nativeEvent.isComposing && e.keyCode !== 229) {
            e.preventDefault();
            saveName();
          } else if (e.key === "Escape") {
            if (naming.id === null) plus.current!.focus();
            else focusRow.current = naming.id;
            setNaming(null);
          }
        }}
        onBlur={() => saving.current || setNaming(null)}
      />
      {naming.error && (
        <div className="nb-field-error" role="alert">
          {naming.error}
        </div>
      )}
    </div>
  );

  const entry = (key: string, label: string, icon: IconName, count?: number) => (
    <button
      className={selected === key ? "nb-nav is-selected" : "nb-nav"}
      aria-current={selected === key ? "page" : undefined}
      onClick={() => onSelect(key)}
    >
      <Icon name={icon} />
      <span className="nb-nav-label">{label}</span>
      {count !== undefined && <span className="nb-count">{count}</span>}
    </button>
  );

  const row = (t: Topic) => {
    if (naming?.id === t.id) return nameField;
    const rename = { label: "Rename", onSelect: () => setNaming({ id: t.id, draft: t.name, error: null }) };
    const remove = { label: "Delete…", danger: true, onSelect: () => onDelete(t) };
    const className = ["nb-topic", selected === t.id && "is-selected", t.archived && "is-archived", menuFor === t.id && "is-open"];
    return (
      <div key={t.id} className={className.filter(Boolean).join(" ")}>
        <button
          className="nb-topic-name"
          data-topic={t.id}
          aria-current={selected === t.id ? "page" : undefined}
          title={t.name}
          onClick={() => onSelect(t.id)}
        >
          <span className="nb-nav-label">{t.name}</span>
        </button>
        <span className="nb-count">{t.item_count}</span>
        <Menu
          label={`${t.name} actions`}
          open={menuFor === t.id}
          onOpenChange={(o) => setMenuFor(o ? t.id : null)}
          entries={
            t.archived
              ? [rename, { label: "Unarchive", onSelect: () => unarchiveTopic(t.id).catch((e) => onError("Couldn't unarchive the Topic", e)) }, { separator: true }, remove]
              : [rename, { label: "Archive", onSelect: () => archiveTopic(t.id).catch((e) => onError("Couldn't archive the Topic", e)) }, { separator: true }, remove]
          }
        />
      </div>
    );
  };

  return (
    <nav className="nb-sidebar" ref={nav}>
      <div className="nb-search">
        <Icon name="search" />
        <input
          ref={searchRef}
          aria-label="Search"
          placeholder="Search"
          value={draft}
          onFocus={onSearchFocus}
          onChange={(e) => {
            setDraft(e.target.value);
            if (!composing.current) onSearch(e.target.value);
          }}
          onCompositionStart={() => (composing.current = true)}
          onCompositionEnd={(e) => {
            composing.current = false;
            onSearch(e.currentTarget.value);
          }}
          onKeyDown={(e) => {
            if (e.key === "Escape" && !e.nativeEvent.isComposing && e.keyCode !== 229) {
              setDraft("");
              onSearch("");
            }
          }}
        />
        {draft !== "" && (
          <button
            className="nb-iconbtn"
            aria-label="Clear search"
            title="Clear search"
            onClick={() => {
              setDraft("");
              onSearch("");
            }}
          >
            <Icon name="x" />
          </button>
        )}
      </div>
      {entry("all", "All Items", "all")}
      {entry("inbox", "Inbox", "inbox", counts.inbox)}
      {entry("trash", "Trash", "trash", counts.trash)}
      <div className="nb-section">
        <span>Topics</span>
        <button ref={plus} className="nb-iconbtn" aria-label="New Topic" title="New Topic" onClick={() => setNaming({ id: null, draft: "", error: null })}>
          <Icon name="plus" />
        </button>
      </div>
      <div className="nb-topic-list">
        {open.length === 0 && naming?.id !== null ? <div className="nb-section-empty">None yet</div> : open.map(row)}
        {naming?.id === null && nameField}
        <div className="nb-section">
          <button className="nb-section-toggle" aria-expanded={showArchived} onClick={() => setShowArchived(!showArchived)}>
            <span>Archived</span>
            {archived.length > 0 && (
              <>
                {" "}
                <span className="nb-count">{archived.length}</span>
              </>
            )}
            <span className="nb-section-chevron">
              <Icon name={showArchived ? "chevron-down" : "chevron-right"} />
            </span>
          </button>
        </div>
        {showArchived && (archived.length === 0 ? <div className="nb-section-empty">None yet</div> : archived.map(row))}
      </div>
      <div className="nb-sidebar-foot">
        {status === "unauthorized" ? (
          <button className="nb-sync nb-sync-danger is-action" title="Open Settings" onClick={onSettings}>
            <Icon name="alert" />
            <span>Secret rejected</span>
            <Icon name="chevron-right" />
          </button>
        ) : (
          status !== "not_configured" && (
            <div className={`nb-sync ${STATUS[status][2]}`} role="status">
              <Icon name={STATUS[status][0]} className={status === "syncing" ? "nb-spin" : undefined} />
              <span>{STATUS[status][1]}</span>
            </div>
          )
        )}
        <button className="nb-nav" onClick={onSettings}>
          <Icon name="settings" />
          <span className="nb-nav-label">Settings</span>
        </button>
      </div>
    </nav>
  );
}
