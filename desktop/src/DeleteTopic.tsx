import { useEffect, useRef, useState, type ReactNode } from "react";
import { deleteTopic, listItems, type FeedItem, type Keep, type Topic } from "./api";
import { PaperclipIcon } from "./attachments";

// list_items' page size.
const PAGE_SIZE = 100;

type Before = { capture_time_us: number; id: string } | null;
type Props = { topic: Topic; onClose: () => void; onError: (title: string, err: unknown) => void };

export default function DeleteTopic({ topic, onClose, onError }: Props) {
  const [manual, setManual] = useState(false);
  const [starts, setStarts] = useState<Before[]>([null]); // where each visited page starts
  const [items, setItems] = useState<FeedItem[]>([]);
  const [kept, setKept] = useState<string[]>([]);
  const deleting = useRef(false);
  const page = starts.length - 1;
  const pages = Math.max(1, Math.ceil(topic.item_count / PAGE_SIZE));

  useEffect(() => {
    if (!manual) return;
    let current = true;
    listItems({ kind: "topic", id: topic.id }, starts[page]).then(
      (list) => current && setItems(list),
      (e) => onError("Couldn't load the Items", e),
    );
    return () => {
      current = false;
    };
  }, [manual, starts]);

  async function remove(keep: Keep) {
    if (deleting.current) return;
    deleting.current = true;
    try {
      await deleteTopic(topic.id, keep);
      onClose();
    } catch (e) {
      onError("Couldn't delete the Topic", e);
    } finally {
      deleting.current = false;
    }
  }

  const dialog = (titleId: string, className: string, children: ReactNode) => (
    <div className="modal-backdrop">
      <div role="dialog" aria-modal="true" aria-labelledby={titleId} className={`modal ${className}`} onKeyDown={(e) => e.key === "Escape" && onClose()}>
        {children}
      </div>
    </div>
  );

  if (!manual) {
    return dialog(
      "delete-topic-title",
      "delete-topic",
      <>
        <h2 id="delete-topic-title">Delete "{topic.name}"?</h2>
        {topic.item_count === 0 ? (
          <div className="actions">
            <button className="secondary" autoFocus onClick={onClose}>
              Cancel
            </button>
            <button onClick={() => remove({ kind: "none" })}>Delete</button>
          </div>
        ) : (
          <>
            <p>It has {topic.item_count === 1 ? "1 Item" : `${topic.item_count} Items`}.</p>
            <div className="choice">
              <button onClick={() => remove({ kind: "all" })}>Keep all</button>
              <span>move them to the Inbox</span>
            </div>
            <div className="choice">
              <button onClick={() => remove({ kind: "none" })}>Delete all</button>
              <span>move them to Trash</span>
            </div>
            <div className="choice">
              <button onClick={() => setManual(true)}>Select manually…</button>
            </div>
            <div className="actions">
              <button className="secondary" autoFocus onClick={onClose}>
                Cancel
              </button>
            </div>
          </>
        )}
      </>,
    );
  }

  const last = items[items.length - 1];
  return dialog(
    "keep-title",
    "select-items",
    <>
      <h2 id="keep-title">Choose Items to keep from "{topic.name}"</h2>
      <p className="hint">Checked Items move to the Inbox. The rest go to Trash.</p>
      <ul className="pick">
        {items.map((it) => (
          <li key={it.id}>
            <label>
              <input
                type="checkbox"
                checked={kept.includes(it.id)}
                onChange={() => setKept(kept.includes(it.id) ? kept.filter((k) => k !== it.id) : [...kept, it.id])}
              />
              <time>
                {new Date(it.capture_time_us / 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}
              </time>
              <span className="summary">
                {it.text ? (
                  it.text.split("\n")[0]
                ) : (
                  <>
                    <PaperclipIcon /> {it.attachments.map((a) => a.filename).join(", ")}
                  </>
                )}
              </span>
            </label>
          </li>
        ))}
      </ul>
      <div className="pager">
        <button className="secondary" disabled={page === 0} onClick={() => setStarts(starts.slice(0, -1))}>
          ‹ Prev
        </button>
        <span>
          Page {page + 1} of {pages}
        </span>
        <button
          className="secondary"
          disabled={items.length < PAGE_SIZE}
          onClick={() => setStarts([...starts, { capture_time_us: last.capture_time_us, id: last.id }])}
        >
          Next ›
        </button>
      </div>
      <div className="actions">
        <button className="secondary" onClick={onClose}>
          Cancel
        </button>
        <button onClick={() => remove({ kind: "only", ids: kept })}>
          Keep {kept.length} · Trash {Math.max(0, topic.item_count - kept.length)}
        </button>
      </div>
    </>,
  );
}
