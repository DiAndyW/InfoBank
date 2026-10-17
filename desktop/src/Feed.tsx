import { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { listItems, moveItem, unarchiveTopic, type FeedItem, type Topic, type View } from "./api";
import { Attachments } from "./attachments";
import Composer from "./Composer";
import { Icon } from "./icons";
import { linkify } from "./links";
import Menu from "./Menu";

export default function Feed({ view, topics, onError }: { view: View; topics: Topic[]; onError: (title: string, err: unknown) => void }) {
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
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const current = view.kind === "topic" ? topics.find((t) => t.id === view.id) : undefined;
  const targets = [{ id: null as string | null, name: "Inbox" }, ...topics.filter((t) => !t.archived)];

  async function load(pageCount: number) {
    const id = ++latestLoad.current;
    let all: FeedItem[] = [];
    let page: FeedItem[] = [];
    for (let i = 0; i < pageCount; i++) {
      const last = all[all.length - 1];
      page = await listItems(view, last ? { capture_time_us: last.capture_time_us, id: last.id } : null);
      all = all.concat(page);
      if (page.length === 0) break;
    }
    if (id !== latestLoad.current) return;
    pages.current = pageCount;
    setItems(all);
    setExhausted(page.length === 0);
  }

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
      load(pages.current + 1);
    }
  }

  const shown = [...items].reverse();
  const today = new Date().toDateString();
  return (
    <main className="nb-feed">
      <div className="nb-feed-scroll" ref={listRef} onScroll={onScroll} data-testid="feed-items">
        <div className="nb-feed-col">
          {shown.length === 0 ? (
            <div className="nb-empty">
              <p className="nb-empty-title">Nothing here yet.</p>
              <p className="nb-empty-hint">Capture something below.</p>
            </div>
          ) : (
            shown.map((it, i) => {
              const time = new Date(it.capture_time_us / 1000);
              const prev = shown[i - 1];
              const place = view.kind !== "all" ? undefined : it.topic_id === null ? "Inbox" : topics.find((t) => t.id === it.topic_id)?.name;
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
                  <article
                    className={menuFor === it.id ? "nb-item is-open" : "nb-item"}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      setMenuFor(it.id);
                    }}
                  >
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
                          <Icon name={it.topic_id === null ? "inbox" : "topic"} size={12} />
                          <span className="nb-chip-label">{place}</span>
                        </span>
                      )}
                      {it.pending && (
                        <span className="nb-pending" title="Not synced yet">
                          <Icon name="pending" label="Not synced yet" />
                        </span>
                      )}
                      <time className="nb-item-time">{time.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time>
                      <Menu
                        label="Item actions"
                        open={menuFor === it.id}
                        onOpenChange={(o) => setMenuFor(o ? it.id : null)}
                        entries={[
                          {
                            label: "Move to…",
                            submenu: targets.map((t) => ({
                              label: t.name,
                              checked: it.topic_id === t.id,
                              onSelect: () => {
                                if (it.topic_id !== t.id) moveItem(it.id, t.id).catch((e) => onError("Couldn't move the Item", e));
                              },
                            })),
                          },
                        ]}
                      />
                    </div>
                  </article>
                </Fragment>
              );
            })
          )}
        </div>
      </div>
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
      <div hidden={current?.archived}>
        <Composer
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
