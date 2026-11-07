import { Fragment, useEffect, useLayoutEffect, useRef, useState, type PointerEvent, type RefObject } from "react";
import { flushSync } from "react-dom";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { doubleClickIntervalMs, discardItem, itemTarget, listItems, setTrashAfterCopy, trashAfterCopy, resolveConflict, restoreItem, trashItem, unarchiveTopic, type FeedAttachment, type FeedItem, type Topic, type View, type Target } from "./api";
import ImageViewer from "./ImageViewer";
import { Attachments, viewable } from "./attachments";
import { copyWholeItem } from "./api";
import Composer from "./Composer";
import CaptureDestination from "./CaptureDestination";
import ConflictDialog from "./ConflictDialog";
import { useShownAfterDelay } from "./delay";
import Dialog from "./Dialog";
import NewTopicDialog from "./NewTopicDialog";
import { Icon } from "./icons";
import ItemEditor, { type EditorHandle } from "./ItemEditor";
import { linkify } from "./links";
import Menu from "./Menu";
import Notice, { type NoticeData } from "./Notice";
import { SelectionBar, useItemSelection, type ShowNotice } from "./Selection";

const HIGHLIGHT_MS = 2000;
const DAY_MS = 24 * 60 * 60 * 1000;
const DRAG_START_PX = 4;

function daysRemaining(purgeAtUs: number | null) {
  if (purgeAtUs === null) return "Waiting for sync";
  const days = Math.max(1, Math.ceil((purgeAtUs / 1000 - Date.now()) / DAY_MS));
  return days === 1 ? "1 day remaining" : `${days} days remaining`;
}

type Props = {
  view: View;
  home?: boolean;
  topics: Topic[];
  covered: boolean;
  editor: RefObject<EditorHandle | null>;
  notice: NoticeData | null;
  onDismissNotice: () => void;
  onNotice: ShowNotice;
  onError: (title: string, err: unknown) => void;
  onTrashed: (id: string, copied?: boolean) => void;
  onRestored: (item: FeedItem) => void;
  onMove: (item: FeedItem, target: Target, newTopicName?: string) => void;
  onDragStart: (item: FeedItem, x: number, y: number) => void;
  highlight: string | null;
  onHighlightDone: () => void;
};

function refusal(reason: string) {
  const why = reason === "invalid" ? "as invalid" : reason === "exists" ? "" : `(${reason})`;
  const what = reason === "exists" ? "The Server already has an Item with this id." : `The Server refused this Item ${why}.`;
  return `${what} It's only on this Device.`;
}

export default function Feed({ home, view, topics, covered, editor, notice, onDismissNotice, onNotice, onError, onTrashed, onRestored, onMove, onDragStart, highlight, onHighlightDone }: Props) {
  const [homeTunnel, setHomeTunnel] = useState(() => localStorage.getItem("tunnelSwitch") === "true");
  const [homeTopic, setHomeTopic] = useState<string | null>(null);
  useEffect(() => {
    const changed = (event: StorageEvent) => {
      if (event.key === "tunnelSwitch") setHomeTunnel(event.newValue === "true");
    };
    window.addEventListener("storage", changed);
    return () => window.removeEventListener("storage", changed);
  }, []);
  const homeChosen = topics.find((t) => t.id === homeTopic && !t.archived);
  useEffect(() => { if (homeTopic && !homeChosen) setHomeTopic(null); }, [topics]);
  const displayed = useRef<{ key: string; items: FeedItem[] }>({ key: "", items: [] });
  const [viewing, setViewing] = useState<{ item: string; attachment: string; images: FeedAttachment[]; view: string } | null>(null);
  const viewingRef = useRef(viewing);
  viewingRef.current = viewing;
  const [closedCount, setClosedCount] = useState(0);
  const [items, setItems] = useState<FeedItem[]>([]); // newest first, as list_items returns them
  const images = items.find(it => it.id === viewing?.item)?.attachments.filter(viewable) ?? viewing?.images ?? [];
  const viewingExists = images.some(a => a.id === viewing?.attachment);
  function closeViewer() {
    setViewing(null);
    setClosedCount(count => count + 1);
  }
  useEffect(() => {
    if (viewing && (!viewingExists || viewing.view !== JSON.stringify(view))) closeViewer();
  }, [viewing, viewingExists, view]);
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
  const [initialText, setInitialText] = useState<string | null | undefined>(undefined);
  const [resolving, setResolving] = useState<string | null>(null);
  const [discarding, setDiscarding] = useState<FeedItem | null>(null);
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const showLoadingOlder = useShownAfterDelay(loadingOlder);
  const current = view.kind === "topic" ? topics.find((t) => t.id === view.id) : undefined;
  const trash = view.kind === "trash";
  const noComposer = !home && (trash || current?.archived === true);
  const targets: { id: string; name: string; target: Target }[] = [
    { id: "inbox", name: "Inbox", target: { kind: "inbox" } },
    { id: "tunnel", name: "Tunnel", target: { kind: "tunnel" } },
    ...topics.filter((t) => !t.archived).map((t) => ({ id: t.id, name: t.name, target: { kind: "topic" as const, id: t.id } })),
  ];
  const [copied, setCopied] = useState<{ id: string } | null>(null);
  const [asking, setAsking] = useState<FeedItem | null>(null);
  const [answering, setAnswering] = useState(false);
  const copyTimers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const rowVersions = useRef(new Map<string, number>());
  const copyVersion = useRef(0);
  const answerBusy = useRef(false);
  const [naming, setNaming] = useState<FeedItem | null>(null);

  function cancelCopy(itemID?: string) {
    if (itemID !== undefined) {
      clearTimeout(copyTimers.current.get(itemID));
      copyTimers.current.delete(itemID);
      rowVersions.current.set(itemID, (rowVersions.current.get(itemID) ?? 0) + 1);
    } else {
      for (const timer of copyTimers.current.values()) clearTimeout(timer);
      copyTimers.current.clear();
      rowVersions.current.clear();
      copyVersion.current++;
    }
  }

  useEffect(() => {
    cancelCopy();
    setCopied(null);
    setAsking(null);
    return cancelCopy;
  }, [viewKey, covered, !!home]);

  useEffect(() => {
    if (copied === null) return;
    // A newer confirmation can be set but not yet rendered when this fires, so this timer can't have been cancelled.
    const timer = setTimeout(() => setCopied((now) => (now === copied ? null : now)), 1500);
    return () => clearTimeout(timer);
  }, [copied]);

  function copyItem(it: FeedItem, delay = false) {
    if ((!it.text && !it.attachments.length) || asking || answerBusy.current) return;
    cancelCopy(it.id);
    const version = copyVersion.current;
    const rowVersion = rowVersions.current.get(it.id);
    const current = () => version === copyVersion.current && rowVersion === rowVersions.current.get(it.id);
    const written = copyWholeItem(it.id).then(() => true, (err) => {
      if (current()) onError("Couldn't copy the Item", err);
      return false;
    });
    const finish = async () => {
      copyTimers.current.delete(it.id);
      if (!(await written) || !current()) return;
      try {
        const trash = await trashAfterCopy();
        if (!current()) return;
        if (trash === true) {
          await trashItem(it.id);
          setCopied(null);
          onTrashed(it.id, true);
        } else if (trash === null) setAsking(it);
        else setCopied({ id: it.id });
      } catch (err) {
        if (current()) onError("Couldn't finish copying the Item", err);
      }
    };
    if (delay) {
      doubleClickIntervalMs().then((interval) => {
        if (current()) copyTimers.current.set(it.id, setTimeout(finish, interval + 50));
      }, (err) => { if (current()) onError("Couldn't finish copying the Item", err); });
    } else finish();
  }

  async function answerCopy(on: boolean) {
    if (!asking || answerBusy.current) return;
    const it = asking;
    answerBusy.current = true;
    setAnswering(true);
    try {
      await setTrashAfterCopy(on);
      if (on) {
        await trashItem(it.id);
        onTrashed(it.id, true);
      } else setCopied({ id: it.id });
      setAsking(null);
    } catch (err) {
      setAsking(null);
      onError("Couldn't save Trash after copy", err);
    } finally {
      answerBusy.current = false;
      setAnswering(false);
    }
  }


  function startDrag(e: PointerEvent<HTMLElement>, it: FeedItem) {
    if (e.button !== 0) return;
    cancelCopy(it.id);
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
        page = await listItems(view, last ? { capture_time_us: last.capture_time_us, id: last.id, purge_at_us: last.purge_at_us } : null);
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
    const previous = displayed.current;
    displayed.current = { key, items: all };
    const removed = previous.key === key && previous.items.some((it) => !all.some((next) => next.id === it.id));
    if (view.kind === "tunnel" && removed && !viewingRef.current && document.startViewTransition && !window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
      document.startViewTransition(() => flushSync(() => setItems(all))).ready.catch(() => {});
    } else setItems(all);
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
    if (home) { latestLoad.current++; return; }
    load(1);
    const unlisten = listen("items-changed", () => load(pages.current));
    return () => {
      unlisten.then((stop) => stop());
    };
  }, [viewKey, !!home]);

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

  async function edit(it: FeedItem, text?: string | null) {
    cancelCopy(it.id);
    setAsking(null);
    if (editing?.id === it.id) return;
    if (editing && !(await editor.current!.save())) return;
    setInitialText(text);
    setEditing(it);
  }

  const open = (it: FeedItem) => (it.conflict ? setResolving(it.id) : edit(it));
  const conflictItem = items.find((i) => i.id === resolving && i.conflict);

  // The editor keeps its Item on screen even after a refetch drops it (trashed or purged elsewhere).
  const listed =
    editing && !items.some((i) => i.id === editing.id)
      ? [...items, editing].sort((a, b) => b.capture_time_us - a.capture_time_us || (a.id < b.id ? 1 : -1))
      : items;
  const shown = [...listed].reverse();
  const selection = useItemSelection({ items: shown, scope: viewKey, enabled: !home && !covered && !editing, onNotice, onError });
  const today = new Date().toDateString();
  return (
    <main className={["nb-feed", covered && "is-covered", home && "is-home"].filter(Boolean).join(" ")} aria-hidden={covered || undefined} inert={covered}>
      {home && <h1 className="nb-home-title">NoteBank</h1>}
      {!home && <div className="nb-selection-controls">
        <button className="nb-btn nb-btn-quiet" onClick={() => {
          cancelCopy();
          setMenuFor(null);
          if (selection.selecting) selection.clear(); else selection.enter();
        }}>{selection.selecting ? "Done" : "Select"}</button>
      </div>}
      <div hidden={!!home} className="nb-feed-scroll" ref={listRef} onScroll={onScroll} data-testid="feed-items">
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
              const place = trash ? (it.in_tunnel ? "Tunnel" : topic?.name ?? "Inbox") : undefined;
              const copy = view.kind === "tunnel" ? [{ label: "Copy Item", onSelect: () => copyItem(it) }] : it.text ? [{ label: "Copy text", onSelect: () => navigator.clipboard.writeText(it.text!).catch((e) => onError("Couldn't copy the text", e)) }] : [];
              const heading = trash
                ? daysRemaining(it.purge_at_us)
                : time.toDateString() === today
                  ? "Today"
                  : time.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", year: "numeric" });
              const newDay = !prev || (trash ? daysRemaining(prev.purge_at_us) !== heading : new Date(prev.capture_time_us / 1000).toDateString() !== time.toDateString());
              const sameMinute = !newDay && Math.floor(prev.capture_time_us / 60e6) === Math.floor(it.capture_time_us / 60e6);
              return (
                <Fragment key={it.id}>
                  {newDay && (
                    <div className="nb-day" role="separator">
                      <span>{heading}</span>
                    </div>
                  )}
                  {editing?.id === it.id ? (
                    <article className="nb-item is-editing" data-item={it.id}>
                      <ItemEditor
                        ref={editor}
                        item={it}
                        initialText={initialText}
                        onDone={(trashed) => {
                          setEditing(null);
                          if (trashed) onTrashed(it.id);
                        }}
                        onGone={(e) => onError("Couldn't save the edit", e)}
                      />
                    </article>
                  ) : (
                    <article
                      style={view.kind === "tunnel" ? { viewTransitionName: `item-${it.id}` } : undefined}
                      data-item={it.id}
                      role={selection.selecting ? "checkbox" : undefined}
                      aria-checked={selection.selecting ? selection.ids.has(it.id) : undefined}
                      aria-label={selection.selecting ? it.text || it.attachments[0]?.filename || "Item" : undefined}
                      tabIndex={selection.selecting ? 0 : undefined}
                      onKeyDown={e => {
                        if (e.key === " " && selection.selecting) { e.preventDefault(); selection.pick(it.id, e); }
                      }}
                      onClickCapture={e => {
                        if (selection.pick(it.id, e)) { cancelCopy(); setMenuFor(null); e.preventDefault(); e.stopPropagation(); }
                      }}
                      onPointerDownCapture={e => {
                        if (selection.selecting || e.metaKey || e.ctrlKey) e.stopPropagation();
                      }}
                      onClick={view.kind === "tunnel" && !it.sync_error ? (e) => {
                        if (selection.selecting || e.metaKey || e.ctrlKey || e.detail !== 1 || covered || (e.target as HTMLElement).closest("a, button, input, .nb-attachment, .nb-grip")) return;
                        copyItem(it, true);
                      } : undefined}
                      onDoubleClick={trash || it.sync_error ? undefined : (e) => {
                        if (selection.selecting || e.metaKey || e.ctrlKey || (e.target as HTMLElement).closest("a, button, input")) return;
                        cancelCopy(it.id);
                        open(it);
                      }}
                      className={["nb-item", selection.ids.has(it.id) && "is-batch-selected", selection.selecting && "is-selecting", view.kind === "tunnel" && it.text && !it.sync_error && !selection.selecting && "is-copyable", menuFor === it.id && "is-open", highlight === it.id && "is-highlight"].filter(Boolean).join(" ")}
                      onContextMenu={
                        trash
                          ? undefined
                          : (e) => {
                              e.preventDefault();
                              if (selection.selecting) return;
                              setMenuFor(it.id);
                            }
                      }
                    >
                      {selection.selecting && <span className="nb-selection-check" aria-hidden="true">{selection.ids.has(it.id) && <Icon name="check" />}</span>}
                      {!selection.selecting && !trash && !it.sync_error && (
                        <span className="nb-grip nb-reveal" title="Drag to a Topic" aria-hidden="true" onPointerDown={(e) => startDrag(e, it)}>
                          <Icon name="grip" />
                        </span>
                      )}
                      <div className="nb-item-body" inert={selection.selecting}>
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
                        {it.attachments.length > 0 && <Attachments list={it.attachments} onView={attachment => setViewing({ item: it.id, attachment, images: it.attachments.filter(viewable), view: viewKey })} closedCount={closedCount} />}
                      </div>
                      <div className="nb-item-meta" inert={selection.selecting}>
                        {place && (
                          <span className="nb-topic-chip" title={`In ${place}`}>
                            <Icon name={it.in_tunnel ? "send" : topic ? "topic" : "inbox"} size={12} />
                            <span className="nb-chip-label">{place}</span>
                          </span>
                        )}
                        {it.sync_error && (
                          <span className="nb-mark is-danger" title={refusal(it.sync_error)}>
                            <Icon name="alert" size={12} />
                            Couldn't sync
                          </span>
                        )}
                        {it.conflict && (
                          <button type="button" className="nb-mark is-warn" onClick={() => setResolving(it.id)}>
                            <Icon name="alert" size={12} />
                            Conflict
                          </button>
                        )}
                        {copied?.id === it.id && <span className="nb-mark is-copied" role="status"><Icon name="check" size={12} />Copied</span>}
                        {it.pending && (
                          <span className="nb-pending" title="Not synced yet">
                            <Icon name="pending" label="Not synced yet" />
                          </span>
                        )}
                        {!trash && <time className={sameMinute ? "nb-item-time nb-reveal" : "nb-item-time"}>{time.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time>}
                        {trash ? (
                          <button className="nb-btn nb-btn-quiet" onClick={() => restoreItem(it.id).then(() => onRestored(it), (e) => onError("Couldn't restore the Item", e))}>
                            <Icon name="restore" />
                            Restore
                          </button>
                        ) : selection.selecting ? (
                          <span className="nb-iconbtn" aria-hidden="true" />
                        ) : (
                          <Menu
                            label="Item actions"
                            open={menuFor === it.id}
                            onOpenChange={(o) => setMenuFor(o ? it.id : null)}
                            entries={it.sync_error ? [...copy, { label: "Discard…", onSelect: () => setDiscarding(it) }] : [
                              { label: "Edit", onSelect: () => open(it) },
                              {
                                label: "Move to",
                                submenu: [
                                  {
                                    filter: "Find a place",
                                    choices: targets.map((t) => ({
                                      label: t.name,
                                      checked: (it.in_tunnel ? "tunnel" : it.topic_id ?? "inbox") === t.id,
                                      onSelect: () => {
                                        if ((it.in_tunnel ? "tunnel" : it.topic_id ?? "inbox") !== t.id) onMove(it, t.target);
                                      },
                                    })),
                                  },
                                  { separator: true },
                                  { label: "New Topic…", onSelect: () => setNaming(it) },
                                ],
                              },
                              ...copy,
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
      {conflictItem && (
        <ConflictDialog
          item={conflictItem}
          onClose={() => setResolving(null)}
          onResolve={(keep) =>
            resolveConflict(conflictItem.id, keep).then(
              ({ trashed }) => {
                setResolving(null);
                if (trashed) onTrashed(conflictItem.id);
              },
              (e) => onError("Couldn't resolve the conflict", e),
            )
          }
          onEdit={(mineText) => {
            setResolving(null);
            edit(conflictItem, mineText);
          }}
        />
      )}
      {asking && (
        <Dialog alert title="Move Tunnel notes to Trash after you copy them?" onClose={() => answering || setAsking(null)}
          actions={<>
            <button type="button" className="nb-btn nb-btn-secondary" disabled={answering} autoFocus onClick={() => answerCopy(false)}>Not now</button>
            <button type="button" className="nb-btn nb-btn-primary" disabled={answering} onClick={() => answerCopy(true)}>Turn on</button>
          </>} />
      )}
      {naming && (
        <NewTopicDialog onClose={() => setNaming(null)}
          onCreated={(topic) => {
            setNaming(null);
            const here = itemTarget(naming);
            if (here.kind !== "topic" || here.id !== topic.id) onMove(naming, { kind: "topic", id: topic.id }, topic.name);
          }} />
      )}
      {discarding && (
        <Dialog
          alert
          title="Discard this Item?"
          hint={`"${discarding.text?.split("\n")[0] || discarding.attachments[0]?.filename || "Item"}"${discarding.attachments.length > 0 ? ` and its ${discarding.attachments.length === 1 ? "file" : `${discarding.attachments.length} files`}` : ""} will be deleted from this Device. The Server never accepted it, so there is no Trash and no Undo.`}
          onClose={() => setDiscarding(null)}
          actions={
            <>
              <button type="button" className="nb-btn nb-btn-secondary" autoFocus onClick={() => setDiscarding(null)}>
                Cancel
              </button>
              <button
                type="button"
                className="nb-btn nb-btn-danger"
                onClick={() => discardItem(discarding.id).then(() => setDiscarding(null), (e) => onError("Couldn't discard the Item", e))}
              >
                Discard
              </button>
            </>
          }
        />
      )}
      <div className="nb-notice-slot">{!covered && notice && <Notice key={notice.id} message={notice.message} action={notice.action} onClose={onDismissNotice} />}</div>
      {selection.selecting && <SelectionBar selection={selection} trash={trash} tunnel={view.kind === "tunnel"} />}
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
      <div hidden={noComposer || selection.selecting} className="nb-main-composer">
        <Composer
          acceptsDrops={!noComposer && !covered && !viewing}
          picker={home ? <CaptureDestination topics={topics.filter((t) => !t.archived)} tunnel={homeTunnel} topicId={homeChosen?.id ?? null} onTunnelChange={setHomeTunnel} onTopicChange={setHomeTopic} /> : undefined}
          target={home ? homeTunnel ? { kind: "tunnel" } : homeChosen ? { kind: "topic", id: homeChosen.id } : { kind: "inbox" } : view.kind === "topic" ? { kind: "topic", id: view.id } : view.kind === "tunnel" ? { kind: "tunnel" } : { kind: "inbox" }}
          placeholder={home ? homeTunnel ? "Send to your other devices…" : "Capture something…" : view.kind === "tunnel" ? "Send to your other devices…" : `Write to ${current ? current.name : "Inbox"}…`}
          onCaptured={() => {
            atBottom.current = true;
            if (!home) load(pages.current);
          }}
        />
      </div>
      {viewing && viewingExists && <ImageViewer images={images} selected={viewing.attachment}
        onSelect={attachment => setViewing({ ...viewing, attachment, images })} onClose={closeViewer} />}
    </main>
  );
}
