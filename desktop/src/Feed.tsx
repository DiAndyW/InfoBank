import { Fragment, useEffect, useLayoutEffect, useRef, useState, type PointerEvent, type RefObject } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { listItems, restoreItem, trashItem, unarchiveTopic, type FeedItem, type Topic, type View } from "./api";
import { Attachments } from "./attachments";
import Composer from "./Composer";
import { useShownAfterDelay } from "./delay";
import { Icon } from "./icons";
import ItemEditor, { type EditorHandle } from "./ItemEditor";
import { linkify } from "./links";
import Menu from "./Menu";
import Notice, { type NoticeData } from "./Notice";

const HIGHLIGHT_MS = 2000;
const DAY_MS = 24 * 60 * 60 * 1000;
const DRAG_START_PX = 4;

function daysLeft(purgeAtUs: number) {
  const days = Math.max(1, Math.ceil((purgeAtUs / 1000 - Date.now()) / DAY_MS));
  return days === 1 ? "1 day left" : `${days} days left`;
}

type Props = {
  view: View;
  topics: Topic[];
  covered: boolean;
  editor: RefObject<EditorHandle | null>;
  notice: NoticeData | null;
  onDismissNotice: () => void;
  onError: (title: string, err: unknown) => void;
  onTrashed: (id: string) => void;
  onRestored: (item: FeedItem) => void;
  onMove: (item: FeedItem, topicId: string | null) => void;
  onDragStart: (item: FeedItem, x: number, y: number) => void;
  highlight: string | null;
  onHighlightDone: () => void;
};

export default function Feed({ view, topics, covered, editor, notice, onDismissNotice, onError, onTrashed, onRestored, onMove, onDragStart, highlight, onHighlightDone }: Props) {
  const [items, setItems] = useState<FeedItem[]>([]); // newest first, as list_items returns them
  const [exhausted, setExhausted] = useState(false);
  const pages = useRef(1);
  const listRef = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);
  // scrollHeight before older Items were prepended, so the view doesn't jump.
  const heightBeforeOlder = useRef<number | null>(null);
  // Loads can finish out of order (a view switch, overlapping refetches); only the latest may render.
  const latestLoad = useRef(0);
  const viewKey = JSON.stringify(view);
  const [loadedView, setLoadedView] = useState<string | null>(null);
  const sought = useRef<string | null>(null);
  const [editing, setEditing] = useState<FeedItem | null>(null);
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const showLoadingOlder = useShownAfterDelay(loadingOlder);
  const current = view.kind === "topic" ? topics.find((t) => t.id === view.id) : undefined;
  const trash = view.kind === "trash";
  const noComposer = trash || current?.archived === true;
  const targets = [{ id: null as string | null, name: "Inbox" }, ...topics.filter((t) => !t.archived)];

  function startDrag(e: PointerEvent<HTMLElement>, it: FeedItem) {
    if (e.button !== 0) return;
    e.preventDefault();
    const [x0, y0] = [e.clientX, e.clientY];
    const moved = (m: globalThis.PointerEvent) => {
      if (Math.hypot(m.clientX - x0, m.clientY - y0) < DRAG_START_PX) return;
      stop();
      onDragStart(it, m.clientX, m.clientY);
    };
    const stop = () => {
      window.removeEventListener("pointermove", moved);
      window.removeEventListener("pointerup", stop);
    };
    window.addEventListener("pointermove", moved);
    window.addEventListener("pointerup", stop);
  }

  async function load(pageCount: number) {
    const id = ++latestLoad.current;
    const key = viewKey;
    let all: FeedItem[] = [];
    let page: FeedItem[] = [];
    try {
      for (let i = 0; i < pageCount; i++) {
        const last = all[all.length - 1];
        page = await listItems(view, last ? { capture_time_us: last.capture_time_us, id: last.id } : null);
        all = all.concat(page);
        if (page.length === 0) break;
      }
    } catch (e) {
      if (id !== latestLoad.current) return;
      heightBeforeOlder.current = null;
      setLoadingOlder(false);
      onError("Couldn't load the Items", e);
      return;
    }
    if (id !== latestLoad.current) return;
    setLoadingOlder(false);
    pages.current = pageCount;
    setItems(all);
    setLoadedView(key);
    setExhausted(page.length === 0);
  }

  useEffect(() => {
    if (highlight === null) sought.current = null;
    if (highlight === null || loadedView !== viewKey) return;
    const row = listRef.current!.querySelector<HTMLElement>(`[data-item="${CSS.escape(highlight)}"]`);
    if (row) {
      atBottom.current = false;
      row.scrollIntoView?.({ block: "center" });
      const timer = setTimeout(onHighlightDone, HIGHLIGHT_MS);
      return () => clearTimeout(timer);
    }
    // The loaded Items may predate the restore that set the highlight, so look again before giving up.
    if (sought.current !== highlight) {
      sought.current = highlight;
      load(exhausted ? pages.current : pages.current + 1);
    } else if (exhausted) onHighlightDone();
    else load(pages.current + 1);
  }, [highlight, items, loadedView, exhausted]);

  useEffect(() => {
    atBottom.current = true;
    load(1);
    const unlisten = listen("items-changed", () => load(pages.current));
    return () => {
      unlisten.then((stop) => stop());
    };
  }, [viewKey]);

  useLayoutEffect(() => {
    const el = listRef.current!;
    if (heightBeforeOlder.current !== null) {
      el.scrollTop = el.scrollHeight - heightBeforeOlder.current;
      heightBeforeOlder.current = null;
    } else if (atBottom.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [items]);

  function onScroll() {
    const el = listRef.current!;
    atBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    if (el.scrollTop === 0 && !exhausted && heightBeforeOlder.current === null) {
      heightBeforeOlder.current = el.scrollHeight;
      setLoadingOlder(true);
      load(pages.current + 1);
    }
  }

  async function edit(it: FeedItem) {
    if (editing?.id === it.id) return;
    if (editing && !(await editor.current!.save())) return;
    setEditing(it);
  }

  // The editor keeps its Item on screen even after a refetch drops it (trashed or purged elsewhere).
  const listed =
    editing && !items.some((i) => i.id === editing.id)
      ? [...items, editing].sort((a, b) => b.capture_time_us - a.capture_time_us || (a.id < b.id ? 1 : -1))
      : items;
  const shown = [...listed].reverse();
  const today = new Date().toDateString();
  return (
    <main className={covered ? "nb-feed is-covered" : "nb-feed"} aria-hidden={covered || undefined} inert={covered}>
      <div className="nb-feed-scroll" ref={listRef} onScroll={onScroll} data-testid="feed-items">
        <div className="nb-feed-col">
          {loadingOlder && showLoadingOlder && (
            <div className="nb-loading" role="status">
              <Icon name="syncing" className="nb-spin" />
              <span>Loading earlier Items…</span>
            </div>
          )}
          {shown.length === 0 ? (
            trash ? (
              <div className="nb-empty">
                <Icon name="trash" size={24} />
                <p className="nb-empty-title">Trash is empty.</p>
                <p className="nb-empty-hint">Deleted Items stay here for 30 days.</p>
              </div>
            ) : (
              <div className="nb-empty">
                <p className="nb-empty-title">Nothing here yet.</p>
                <p className="nb-empty-hint">Capture something below.</p>
              </div>
            )
          ) : (
            shown.map((it, i) => {
              const time = new Date(it.capture_time_us / 1000);
              const prev = shown[i - 1];
              const topic = topics.find((t) => t.id === it.topic_id);
              const place = view.kind === "all" || trash ? (topic?.name ?? "Inbox") : undefined;
              const newDay = !prev || new Date(prev.capture_time_us / 1000).toDateString() !== time.toDateString();
              return (
                <Fragment key={it.id}>
                  {newDay && (
                    <div className="nb-day" role="separator">
                      <span>
                        {time.toDateString() === today
                          ? "Today"
                          : time.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", year: "numeric" })}
                      </span>
                    </div>
                  )}
                  {editing?.id === it.id ? (
                    <article className="nb-item is-editing" data-item={it.id}>
                      <ItemEditor
                        ref={editor}
                        item={it}
                        onDone={(trashed) => {
                          setEditing(null);
                          if (trashed) onTrashed(it.id);
                        }}
                        onGone={(e) => onError("Couldn't save the edit", e)}
                      />
                    </article>
                  ) : (
                    <article
                      data-item={it.id}
                      onDoubleClick={trash ? undefined : () => edit(it)}
                      className={["nb-item", menuFor === it.id && "is-open", highlight === it.id && "is-highlight"].filter(Boolean).join(" ")}
                      onContextMenu={
                        trash
                          ? undefined
                          : (e) => {
                              e.preventDefault();
                              setMenuFor(it.id);
                            }
                      }
                    >
                      {!trash && (
                        <span className="nb-grip nb-reveal" title="Drag to a Topic" aria-hidden="true" onPointerDown={(e) => startDrag(e, it)}>
                          <Icon name="grip" />
                        </span>
                      )}
                      <div className="nb-item-body">
                        {it.text && (
                          <p className="nb-item-text">
                            {linkify(it.text).map((part, j) =>
                              typeof part === "string" ? (
                                part
                              ) : (
                                <a
                                  key={j}
                                  className="nb-link"
                                  href={part.url}
                                  onClick={(e) => {
                                    e.preventDefault();
                                    openUrl(part.url);
                                  }}
                                  onAuxClick={(e) => {
                                    if (e.button !== 1) return;
                                    e.preventDefault();
                                    openUrl(part.url);
                                  }}
                                >
                                  {part.url}
                                </a>
                              ),
                            )}
                          </p>
                        )}
                        {it.attachments.length > 0 && <Attachments list={it.attachments} />}
                      </div>
                      <div className="nb-item-meta">
                        {place && (
                          <span className="nb-topic-chip" title={`In ${place}`}>
                            <Icon name={topic ? "topic" : "inbox"} size={12} />
                            <span className="nb-chip-label">{place}</span>
                          </span>
                        )}
                        {trash && it.purge_at_us !== null && <span className="nb-days">{daysLeft(it.purge_at_us)}</span>}
                        {it.pending && (
                          <span className="nb-pending" title="Not synced yet">
                            <Icon name="pending" label="Not synced yet" />
                          </span>
                        )}
                        <time className="nb-item-time">{time.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time>
                        {trash ? (
                          <button className="nb-btn nb-btn-quiet" onClick={() => restoreItem(it.id).then(() => onRestored(it), (e) => onError("Couldn't restore the Item", e))}>
                            <Icon name="restore" />
                            Restore
                          </button>
                        ) : (
                          <Menu
                            label="Item actions"
                            open={menuFor === it.id}
                            onOpenChange={(o) => setMenuFor(o ? it.id : null)}
                            entries={[
                              { label: "Edit", onSelect: () => edit(it) },
                              {
                                label: "Move to…",
                                submenu: targets.map((t) => ({
                                  label: t.name,
                                  checked: it.topic_id === t.id,
                                  onSelect: () => {
                                    if (it.topic_id !== t.id) onMove(it, t.id);
                                  },
                                })),
                              },
                              ...(it.text ? [{ label: "Copy text", onSelect: () => navigator.clipboard.writeText(it.text!).catch((e) => onError("Couldn't copy the text", e)) }] : []),
                              { separator: true },
                              {
                                label: "Move to Trash",
                                danger: true,
                                onSelect: () => trashItem(it.id).then(() => onTrashed(it.id), (e) => onError("Couldn't move the Item to Trash", e)),
                              },
                            ]}
                          />
                        )}
                      </div>
                    </article>
                  )}
                </Fragment>
              );
            })
          )}
        </div>
      </div>
      <div className="nb-notice-slot">{notice && <Notice key={notice.id} message={notice.message} action={notice.action} onClose={onDismissNotice} />}</div>
      {current?.archived && (
        <div className="nb-archived-bar">
          <Icon name="archive" />
          <span>"{current.name}" is archived.</span>
          <button className="nb-btn nb-btn-secondary" onClick={() => unarchiveTopic(current.id).catch((e) => onError("Couldn't unarchive the Topic", e))}>
            Unarchive
          </button>
        </div>
      )}
      {/* Hidden, not unmounted: the draft and staged files are shared by every view. */}
      {trash && (
        <div className="nb-archived-bar">
          <Icon name="trash" />
          <span>Items in Trash are deleted for good after 30 days.</span>
        </div>
      )}
      <div hidden={noComposer}>
        <Composer
          acceptsDrops={!noComposer}
          topicId={view.kind === "topic" ? view.id : null}
          placeholder={`Write to ${current ? current.name : "Inbox"}…`}
          onCaptured={() => {
            atBottom.current = true;
            load(pages.current);
          }}
        />
      </div>
    </main>
  );
}
