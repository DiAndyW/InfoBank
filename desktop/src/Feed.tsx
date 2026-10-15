import { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { listItems, type FeedItem, type View } from "./api";
import { Attachments } from "./attachments";
import Composer from "./Composer";
import { linkify } from "./links";

export default function Feed({ view }: { view: View }) {
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
    <main className="feed">
      <div className="items" ref={listRef} onScroll={onScroll} data-testid="feed-items">
        {shown.length === 0 ? (
          <div className="empty">
            <p>Nothing here yet.</p>
            <p className="hint">Capture something below.</p>
          </div>
        ) : (
          shown.map((it, i) => {
            const time = new Date(it.capture_time_us / 1000);
            const prev = shown[i - 1];
            const newDay = !prev || new Date(prev.capture_time_us / 1000).toDateString() !== time.toDateString();
            return (
              <Fragment key={it.id}>
                {newDay && (
                  <div className="day" role="separator">
                    {time.toDateString() === today
                      ? "Today"
                      : time.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", year: "numeric" })}
                  </div>
                )}
                <article className="item">
                  <time>{time.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time>
                  <div className="body">
                    {it.text && (
                      <p className="text">
                        {linkify(it.text).map((part, j) =>
                          typeof part === "string" ? (
                            part
                          ) : (
                            <a
                              key={j}
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
                  {it.pending && (
                    <span className="pending" aria-label="Not synced yet" title="Not synced yet">
                      ◌
                    </span>
                  )}
                </article>
              </Fragment>
            );
          })
        )}
      </div>
      <Composer
        onCaptured={() => {
          atBottom.current = true;
          load(pages.current);
        }}
      />
    </main>
  );
}
