import { Fragment, useEffect, useLayoutEffect, useRef, useState, type FormEvent, type KeyboardEvent } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { capture, listItems, type FeedItem, type View } from "./api";
import { linkify } from "./links";

export default function Feed({ view }: { view: View }) {
  const [items, setItems] = useState<FeedItem[]>([]); // newest first, as list_items returns them
  const [exhausted, setExhausted] = useState(false);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
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

  async function submit(e?: FormEvent) {
    e?.preventDefault();
    if (draft.trim() === "") return;
    try {
      await capture(draft);
      setDraft("");
      setError(null);
      atBottom.current = true;
      await load(pages.current);
    } catch (err) {
      setError(String(err));
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      submit();
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
                  <p className="text">
                    {it.text === null ? (
                      <span className="hint">Attachment</span>
                    ) : (
                      linkify(it.text).map((part, j) =>
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
                      )
                    )}
                  </p>
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
      {error && (
        <p role="alert" className="composer-error">
          {error}
        </p>
      )}
      <form className="composer" onSubmit={submit}>
        <textarea
          aria-label="New Item"
          placeholder="Write something…"
          rows={2}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKeyDown}
        />
        <button type="submit" disabled={draft.trim() === ""}>
          Send
        </button>
      </form>
    </main>
  );
}
