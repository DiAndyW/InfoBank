import { useEffect, useId, useRef, useState } from "react";
import { deleteTopic, listItems, type FeedItem, type Keep, type Topic } from "./api";
import Dialog from "./Dialog";
import { Icon } from "./icons";

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

  const cancel = (
    <button className="nb-btn nb-btn-secondary" autoFocus={!manual} onClick={onClose}>
      Cancel
    </button>
  );
  const noteId = useId();
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
    const count = topic.item_count;
    return (
      <Dialog
        title={`Delete "${topic.name}"?`}
        onClose={onClose}
        actions={
          count === 0 ? (
            <>
              {cancel}
              <button className="nb-btn nb-btn-danger" onClick={() => remove({ kind: "none" })}>
                Delete
              </button>
            </>
          ) : (
            cancel
          )
        }
      >
        {count > 0 && (
          <>
            <p>It has {count === 1 ? "1 Item" : `${count} Items`}.</p>
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
          </>
        )}
      </Dialog>
    );
  }

  const last = items[items.length - 1];
  const trashed = Math.max(0, topic.item_count - kept.length);
  return (
    <Dialog
      wide
      title={`Choose Items to keep from "${topic.name}"`}
      hint="Checked Items move to the Inbox. The rest go to Trash."
      onClose={onClose}
      actions={
        <>
          {cancel}
          <button className={trashed > 0 ? "nb-btn nb-btn-danger" : "nb-btn nb-btn-primary"} onClick={() => remove({ kind: "only", ids: kept })}>
            Keep {kept.length} · Trash {trashed}
          </button>
        </>
      }
    >
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
      <div className="nb-pager">
        <button className="nb-btn nb-btn-quiet" disabled={page === 0} onClick={() => setStarts(starts.slice(0, -1))}>
          <Icon name="chevron-left" />
          Prev
        </button>
        <span className="nb-pager-label">
          Page {page + 1} of {pages}
        </span>
        <button
          className="nb-btn nb-btn-quiet"
          disabled={items.length < PAGE_SIZE}
          onClick={() => setStarts([...starts, { capture_time_us: last.capture_time_us, id: last.id }])}
        >
          Next
          <Icon name="chevron-right" />
        </button>
      </div>
    </Dialog>
  );
}
