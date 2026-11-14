import { useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import { renameTopic, type Counts, type SyncStatus, type Topic, type UpdateStatus } from "./api";
import { Icon, type IconName } from "./icons";
import Menu from "./Menu";
import NewTopicDialog from "./NewTopicDialog";

const STATUS: Record<Exclude<SyncStatus, "unauthorized" | "not_configured">, [IconName, string, string]> = {
  synced: ["synced", "Synced", "nb-sync-ok"],
  syncing: ["syncing", "Syncing…", ""],
  offline: ["offline", "Offline, retrying", ""],
  keychain: ["key", "Keychain access needed", "nb-sync-warn"],
};

type Props = {
  collapsed: boolean;
  toggle: ReactNode;
  topics: Topic[];
  counts: Counts;
  selected: string;
  onSelect: (key: string) => void;
  status: SyncStatus;
  update: UpdateStatus;
  onRestart: () => void;
  onSettings: () => void;
  onDelete: (topic: Topic) => void;
  search: string;
  onSearch: (text: string) => void;
  onSearchFocus: () => void;
  onSearchEscape: (empty: boolean) => void;
  // While an Item is dragged: where it is now ("inbox", "tunnel", or a Topic id), and the row it would drop on.
  drag: { from: string; over: string | null } | null;
  onDragOver: (key: string | null) => void;
  searchRef: RefObject<HTMLInputElement | null>;
};

export default function Sidebar({ collapsed, toggle, topics, counts, selected, onSelect, status, update, onRestart, onSettings, onDelete, search, onSearch, onSearchFocus, onSearchEscape, searchRef, drag, onDragOver }: Props) {
  // The field shows what's typed even mid-composition; the query only follows once the input method is done.
  const [draft, setDraft] = useState(search);
  const composing = useRef(false);
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [showAll, setShowAll] = useState(false);
  const [focusedTopic, setFocusedTopic] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [naming, setNaming] = useState<{ id: string; draft: string; error: string | null } | null>(null);
  const saving = useRef(false);
  const nav = useRef<HTMLElement>(null);
  // A Topic whose row should take focus once it's on screen (a new one arrives with the next Topics refresh).
  const focusRow = useRef<string | null>(null);

  const heldOrder = useRef<string[]>([]);
  const currentTopics = new Map(topics.map(t => [t.id, t]));
  const hold = (menuFor !== null && currentTopics.has(menuFor)) ||
    (naming !== null && currentTopics.has(naming.id)) || drag !== null;
  useLayoutEffect(() => {
    if (menuFor !== null && !currentTopics.has(menuFor)) setMenuFor(null);
    if (naming !== null && !currentTopics.has(naming.id)) setNaming(null);
  });

  const heldIds = new Set(heldOrder.current);
  const ordered = hold ? [
    ...heldOrder.current.filter(id => currentTopics.has(id)).map(id => currentTopics.get(id)!),
    ...topics.filter(t => !heldIds.has(t.id)),
  ] : topics;
  useLayoutEffect(() => { heldOrder.current = ordered.map(t => t.id); });

  const visible = showAll ? ordered : ordered.filter((t, i) =>
    i < 10 || t.id === selected || t.id === naming?.id || t.id === menuFor || t.id === focusedTopic || t.id === focusRow.current);

  const positions = useRef(new Map<string, { top: number; row: HTMLElement }>());
  const activeAnimations = useRef<Animation[]>([]);
  const exitingRows = useRef<HTMLElement[]>([]);
  const previousShowAll = useRef(showAll);
  const orderedIds = JSON.stringify(ordered.map(t => t.id));
  const previousOrderedIds = useRef(orderedIds);
  const displayedOrder = JSON.stringify(visible.map(t => t.id));
  useLayoutEffect(() => {
    const list = nav.current!.querySelector<HTMLElement>("#sidebar-topics")!;
    const previous = positions.current;
    const next = new Map<string, { top: number; row: HTMLElement }>();
    const starts = new Map<string, number>();
    const listRect = list.getBoundingClientRect();
    const hidden = collapsed || listRect.height === 0;
    if (!hidden) {
      for (const row of list.querySelectorAll<HTMLElement>("[data-topic-row]")) {
        const id = row.dataset.topicRow!;
        const top = row.offsetTop;
        const old = previous.get(id);
        if (old) starts.set(id, old.top + row.getBoundingClientRect().top - listRect.top - top);
        next.set(id, { top, row });
      }
    }
    activeAnimations.current.forEach(animation => animation.cancel());
    exitingRows.current.forEach(row => row.remove());
    activeAnimations.current = [];
    exitingRows.current = [];
    positions.current = next;
    const expansionChanged = previousShowAll.current !== showAll;
    previousShowAll.current = showAll;
    const reordered = previousOrderedIds.current !== orderedIds;
    previousOrderedIds.current = orderedIds;
    if (hidden || expansionChanged || !reordered || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const animations = activeAnimations.current;
    for (const [id, { top, row }] of next) {
      const start = starts.get(id);
      if (start !== undefined && start !== top) {
        const cover = {
          ...(row.classList.contains("is-selected") ? {} : { backgroundColor: getComputedStyle(row).getPropertyValue("--surface-sidebar") }),
          ...(start > top ? { zIndex: 1 } : {}),
        };
        animations.push(row.animate([{ transform: `translateY(${start - top}px)`, ...cover }, { transform: "none", ...cover }], { duration: 250, easing: "ease-out" }));
      } else if (!previous.has(id) && previous.size > 0 && !showAll) {
        animations.push(row.animate([{ opacity: 0, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }], { duration: 250, easing: "ease-out" }));
      }
    }
    if (!showAll) {
      for (const [id, { top, row }] of previous) {
        if (next.has(id) || !currentTopics.has(id)) continue;
        const ghost = row.cloneNode(true) as HTMLElement;
        ghost.removeAttribute("data-topic-row");
        ghost.querySelectorAll("[data-topic]").forEach(node => node.removeAttribute("data-topic"));
        ghost.inert = true;
        ghost.setAttribute("aria-hidden", "true");
        Object.assign(ghost.style, { position: "absolute", top: `${top}px`, left: "0", width: "100%", pointerEvents: "none" });
        list.prepend(ghost);
        exitingRows.current.push(ghost);
        const animation = ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 250, easing: "ease-out" });
        animations.push(animation);
        animation.finished.then(() => ghost.remove(), () => ghost.remove());
      }
    }
  }, [displayedOrder, orderedIds, collapsed, showAll]);
  useLayoutEffect(() => () => {
    activeAnimations.current.forEach(animation => animation.cancel());
    exitingRows.current.forEach(row => row.remove());
  }, []);

  useEffect(() => {
    if (focusRow.current === null) return;
    const row = nav.current!.querySelector<HTMLElement>(`[data-topic="${CSS.escape(focusRow.current)}"]`);
    if (!row) return;
    row.focus();
    focusRow.current = null;
  }, [topics, naming, creating, showAll]);

  async function saveName() {
    if (!naming || saving.current) return;
    saving.current = true;
    try {
      await renameTopic(naming.id, naming.draft);
      focusRow.current = naming.id;
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
            focusRow.current = naming.id;
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

  const dropClass = (key: string, takes: boolean) => drag && (!takes || key === drag.from ? "is-drop-off" : drag.over === key && "is-drop-target");
  const dropHandlers = (key: string, takes: boolean) =>
    drag && takes && key !== drag.from ? { onPointerEnter: () => onDragOver(key), onPointerLeave: () => onDragOver(null) } : {};

  const entry = (key: string, label: string, icon: IconName, count?: number) => (
    <button
      className={["nb-nav", selected === key && "is-selected", dropClass(key, key === "inbox" || key === "tunnel")].filter(Boolean).join(" ")}
      aria-current={selected === key ? "page" : undefined}
      onClick={() => onSelect(key)}
      {...dropHandlers(key, key === "inbox" || key === "tunnel")}
    >
      <Icon name={icon} />
      <span className="nb-nav-label">{label}</span>
      {count !== undefined && <span className="nb-count">{count}</span>}
    </button>
  );

  const row = (t: Topic) => {
    if (naming?.id === t.id) return <div key={t.id} data-topic-row={t.id}>{nameField}</div>;
    const rename = { label: "Rename", onSelect: () => setNaming({ id: t.id, draft: t.name, error: null }) };
    const remove = { label: "Delete…", danger: true, onSelect: () => onDelete(t) };
    const className = ["nb-topic", selected === t.id && "is-selected", menuFor === t.id && "is-open", dropClass(t.id, true)];
    return (
      <div key={t.id} data-topic-row={t.id} className={className.filter(Boolean).join(" ")} {...dropHandlers(t.id, true)}
        onFocus={() => setFocusedTopic(t.id)}
        onBlur={(e) => { if (!e.currentTarget.contains(e.relatedTarget)) setFocusedTopic(null); }}>
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
          entries={[rename, { separator: true }, remove]}
        />
      </div>
    );
  };

  return (<>
    <nav className={`nb-sidebar${collapsed ? " is-collapsed" : ""}`} ref={nav}>
      <div className="nb-sidebar-header">
        {toggle}
      <div className="nb-search" hidden={collapsed} inert={collapsed}>
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
              onSearchEscape(draft.trim() === "");
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
              searchRef.current?.focus();
            }}
          >
            <Icon name="x" />
          </button>
        )}
      </div>
      </div>
      {collapsed && <div className="nb-sidebar-rail">
        <div className="nb-rail-divider" />
        {([ ["home", "Home", "home"], ["inbox", "Inbox", "inbox"], ["tunnel", "Tunnel", "send"] ] as const).map(([key, label, icon]) => (
          <button key={key} type="button" className={["nb-iconbtn", selected === key && "is-selected", dropClass(key, key !== "home")].filter(Boolean).join(" ")}
            aria-label={label} title={label} aria-current={selected === key ? "page" : undefined} onClick={() => onSelect(key)}
            {...dropHandlers(key, key !== "home")}>
            <Icon name={icon} />
          </button>
        ))}
      </div>}
      <div id="sidebar-content" className="nb-sidebar-full" hidden={collapsed} inert={collapsed}>
      {entry("home", "Home", "home")}
      {entry("inbox", "Inbox", "inbox", counts.inbox)}
      {entry("tunnel", "Tunnel", "send", counts.tunnel)}
      <div className="nb-section">
        <span>Topics</span>
        {topics.length > 10 && (
          <button className="nb-topic-toggle" aria-expanded={showAll} aria-controls="sidebar-topics"
            onClick={() => setShowAll(!showAll)}>
            {showAll ? "Show less" : "Show all"}
          </button>
        )}
        <button className="nb-iconbtn" aria-label="New Topic" title="New Topic" onClick={(e) => { e.currentTarget.focus(); setCreating(true); }}>
          <Icon name="plus" />
        </button>
      </div>
      <div className="nb-topic-list">
        <div id="sidebar-topics" style={{ position: "relative" }}>
          {topics.length === 0 ? <div className="nb-section-empty">None yet</div> : visible.map(row)}
        </div>
      </div>
      <div className="nb-sidebar-foot">
        {update.state === "ready" && (
          <div className="nb-sync" role="status">
            <Icon name="syncing" />
            <span style={{ flex: 1 }}>Update ready</span>
            <button type="button" className="nb-btn nb-btn-quiet" onClick={onRestart}>Restart</button>
          </div>
        )}
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
        {entry("trash", "Trash", "trash", counts.trash)}
        <button className="nb-nav" onClick={onSettings}>
          <Icon name="settings" />
          <span className="nb-nav-label">Settings</span>
        </button>
      </div>
      </div>
    </nav>
    {creating && <NewTopicDialog onClose={() => setCreating(false)} onCreated={(created) => {
      focusRow.current = created.id;
      onSelect(created.id);
      setCreating(false);
    }} />}
  </>);
}
