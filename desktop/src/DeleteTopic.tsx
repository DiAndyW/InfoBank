import { useEffect, useId, useRef, useState } from "react";
import { deleteTopic, listItems, type FeedItem, type Keep, type Topic } from "./api";
import { useShownAfterDelay } from "./delay";
import Dialog from "./Dialog";
import { Icon } from "./icons";

// list_items' page size.
const PAGE_SIZE = 100;

type Before = { capture_time_us: number; id: string } | null;
type Props = {
  topic: Topic;
  onClose: () => void;
  onDeleted: (message: string) => void;
  onError: (title: string, err: unknown) => void;
};

const count = (n: number) => (n === 1 ? "1 Item" : `${n} Items`);

export default function DeleteTopic({ topic, onClose, onDeleted, onError }: Props) {
  const [manual, setManual] = useState(false);
  const [starts, setStarts] = useState<Before[]>([null]); // where each visited page starts
  const [items, setItems] = useState<FeedItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [kept, setKept] = useState<string[]>([]);
  const [working, setWorking] = useState<Keep | null>(null);
  const deleting = useRef(false);
  const list = useRef<HTMLDivElement>(null);
  const noteId = useId();
  const showLoading = useShownAfterDelay(loading);
  const showWorking = useShownAfterDelay(working !== null);
  const page = starts.length - 1;
  const pages = Math.max(1, Math.ceil(topic.item_count / PAGE_SIZE));
  const trashed = Math.max(0, topic.item_count - kept.length);

  useEffect(() => {
    if (!manual) return;
    let current = true;
    setLoading(true);
    setLoadError(null);
    listItems({ kind: "topic", id: topic.id }, starts[page]).then(
      (page) => {
        if (!current) return;
        setItems(page);
        setLoading(false);
      },
      (e) => {
        if (!current) return;
        setLoadError(String(e));
        setLoading(false);
      },
    );
    return () => {
      current = false;
    };
  }, [manual, starts, attempt]);

  useEffect(() => {
    if (manual && !loading) list.current?.querySelector<HTMLElement>("input, button")?.focus();
  }, [manual, loading]);

  async function remove(keep: Keep) {
    if (deleting.current) return;
    deleting.current = true;
    setWorking(keep);
    try {
      await deleteTopic(topic.id, keep);
      const moved =
        topic.item_count === 0
          ? ""
          : keep.kind === "all"
            ? ` ${count(topic.item_count)} moved to the Inbox.`
            : keep.kind === "none"
              ? ` ${count(topic.item_count)} moved to Trash.`
              : ` ${count(kept.length)} moved to the Inbox, ${trashed} to Trash.`;
      onDeleted(`Deleted "${topic.name}".${moved}`);
    } catch (e) {
      onError("Couldn't delete the Topic", e);
    } finally {
      deleting.current = false;
      setWorking(null);
    }
  }

  const workingLabel = !working
    ? ""
    : topic.item_count === 0
      ? "Deleting…"
      : working.kind === "all"
        ? `Moving ${count(topic.item_count)} to the Inbox…`
        : working.kind === "none"
          ? `Moving ${count(topic.item_count)} to Trash…`
          : `Moving ${count(kept.length)} to the Inbox and ${trashed} to Trash…`;
  const loadingLine = (label: string) => (
    <div className={manual ? "nb-loading is-block" : "nb-loading"} role="status">
      <Icon name="syncing" className="nb-spin" />
      <span>{label}</span>
    </div>
  );
  const cancel = (
    <button className="nb-btn nb-btn-secondary" autoFocus={!manual} disabled={working !== null} onClick={onClose}>
      Cancel
    </button>
  );
  const choice = (label: string, note: string, keep: Keep) => (
    <div className={keep.kind === "none" ? "nb-choice is-danger" : "nb-choice"}>
      <button className="nb-choice-label" aria-describedby={`${noteId}-${keep.kind}`} onClick={() => remove(keep)}>
        {label}
      </button>
      <span className="nb-choice-note" id={`${noteId}-${keep.kind}`}>
        {note}
      </span>
    </div>
  );

  if (!manual) {
    return (
      <Dialog
        title={`Delete "${topic.name}"?`}
        onClose={() => working || onClose()}
        actions={
          topic.item_count === 0 ? (
            <>
              {cancel}
              <button className="nb-btn nb-btn-danger" disabled={working !== null} onClick={() => remove({ kind: "none" })}>
                Delete
              </button>
            </>
          ) : (
            cancel
          )
        }
      >
        {topic.item_count > 0 && <p>It has {count(topic.item_count)}.</p>}
        {showWorking
          ? loadingLine(workingLabel)
          : topic.item_count > 0 && (
              <div className="nb-choices">
                {choice("Keep all", "move them to the Inbox", { kind: "all" })}
                {choice("Delete all", "move them to Trash", { kind: "none" })}
                <div className="nb-choice">
                  <button className="nb-choice-label" onClick={() => setManual(true)}>
                    Select manually…
                  </button>
                  <Icon name="chevron-right" />
                </div>
              </div>
            )}
      </Dialog>
    );
  }

  const last = items[items.length - 1];
  const busy = loading || working !== null;
  return (
    <Dialog
      wide
      title={`Choose Items to keep from "${topic.name}"`}
      hint="Checked Items move to the Inbox. The rest go to Trash."
      onClose={() => working || onClose()}
      actions={
        <>
          {cancel}
          <button
            className={trashed > 0 ? "nb-btn nb-btn-danger" : "nb-btn nb-btn-primary"}
            disabled={busy}
            onClick={() => remove({ kind: "only", ids: kept })}
          >
            Keep {kept.length} · Trash {trashed}
          </button>
        </>
      }
    >
      <div ref={list}>
        {showWorking ? (
          loadingLine(workingLabel)
        ) : showLoading ? (
          loadingLine("Loading Items…")
        ) : loadError ? (
          <div className="nb-empty" role="alert">
            <p className="nb-empty-title">Couldn't load the Items</p>
            <p className="nb-empty-hint">{loadError}</p>
            <button className="nb-btn nb-btn-secondary" onClick={() => setAttempt(attempt + 1)}>
              Try again
            </button>
          </div>
        ) : (
          <ul className="nb-selectlist">
            {items.map((it) => (
              <li key={it.id}>
                <label className="nb-selectrow">
                  <span className="nb-check">
                    <input
                      type="checkbox"
                      checked={kept.includes(it.id)}
                      onChange={() => setKept(kept.includes(it.id) ? kept.filter((k) => k !== it.id) : [...kept, it.id])}
                    />
                    <span className="nb-check-box" aria-hidden="true">
                      <Icon name="check" size={12} />
                    </span>
                  </span>
                  <time>
                    {new Date(it.capture_time_us / 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}
                  </time>
                  <span className="nb-selectrow-text">
                    {it.text ? (
                      it.text.split("\n")[0]
                    ) : (
                      <>
                        <Icon name="paperclip" /> {it.attachments.map((a) => a.filename).join(", ")}
                      </>
                    )}
                  </span>
                </label>
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="nb-pager">
        <button className="nb-btn nb-btn-quiet" disabled={busy || page === 0} onClick={() => setStarts(starts.slice(0, -1))}>
          <Icon name="chevron-left" />
          Prev
        </button>
        <span className="nb-pager-label">
          Page {page + 1} of {pages}
        </span>
        <button
          className="nb-btn nb-btn-quiet"
          disabled={busy || page + 1 >= pages || items.length < PAGE_SIZE}
          onClick={() => setStarts([...starts, { capture_time_us: last.capture_time_us, id: last.id }])}
        >
          Next
          <Icon name="chevron-right" />
        </button>
      </div>
    </Dialog>
  );
}
