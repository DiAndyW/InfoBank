import { useImperativeHandle, useLayoutEffect, useRef, useState, type KeyboardEvent, type Ref } from "react";
import { editItem, type FeedItem } from "./api";
import Dialog from "./Dialog";
import { failure } from "./failure";
import { Icon } from "./icons";
import { Chips, useStaging } from "./staging";

export type EditorHandle = { readonly isSaving: boolean; hasChanges: boolean; discard: () => void; focus: () => void };

type Props = { acceptsDrops: boolean; item: FeedItem; initialText?: string | null; onDone: (trashed: boolean) => void; ref: Ref<EditorHandle> };

export default function ItemEditor({ acceptsDrops, item, initialText, onDone, ref }: Props) {
  const [draft, setDraft] = useState((initialText === undefined ? item.text : initialText) ?? "");
  const [openingText] = useState(draft);
  const [openingAttachments] = useState(item.attachments);
  const [baseRev] = useState(() => item.edit_base);
  const [kept, setKept] = useState(item.attachments);
  const { dropTarget, setViewing, staged, onPaste, remove, pick, errors, clearErrors, isImporting, pendingImportCount, discard } = useStaging({ acceptsDrops });
  const [error, setError] = useState<string | null>(null);
  const [confirmingTrash, setConfirmingTrash] = useState(false);
  const saving = useRef(false);
  const box = useRef<HTMLTextAreaElement>(null);
  const empty = draft.trim() === "" && kept.length === 0 && staged.length === 0 && !isImporting;

  const fit = () => {
    const el = box.current!;
    const row = el.parentElement!;
    const scrollTop = el.scrollTop;
    // Hold the container while measuring so the Feed's scroll position cannot be clamped.
    row.style.height = `${row.offsetHeight}px`;
    el.style.overflowY = "hidden";
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
    row.style.height = "";
    el.style.overflowY = el.scrollHeight > el.clientHeight ? "auto" : "hidden";
    el.scrollTop = scrollTop;
  };

  useLayoutEffect(fit, [draft]);
  useLayoutEffect(() => {
    box.current!.scrollTop = box.current!.scrollHeight;
    const observer = new ResizeObserver(fit);
    observer.observe(box.current!.parentElement!);
    return () => observer.disconnect();
  }, []);

  async function save() {
    if (saving.current || isImporting) return false;
    saving.current = true;
    try {
      const removed = item.attachments.filter((a) => !kept.some((k) => k.id === a.id)).map((a) => a.id);
      const { trashed } = await editItem(item.id, draft, staged.map((s) => s.id), removed, baseRev);
      clearErrors();
      onDone(trashed);
      return true;
    } catch (err) {
      setError(failure("Edit failed to save.", err));
      return false;
    } finally {
      saving.current = false;
    }
  }
  useImperativeHandle(ref, () => ({ get isSaving() { return saving.current; }, hasChanges: draft !== openingText || kept.length !== openingAttachments.length || staged.length > 0 || isImporting, discard: cancel, focus: () => box.current?.focus() }));

  function cancel() {
    discard();
    onDone(false);
  }

  function clear() {
    discard();
    setDraft("");
    setKept([]);
    box.current?.focus();
  }

  function submit() {
    if (empty) setConfirmingTrash(true);
    else save();
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    // WebKit sends the Enter that confirms an input method's text after compositionend, as keyCode 229.
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing && e.keyCode !== 229) {
      e.preventDefault();
      submit();
    } else if (e.key === "Escape") {
      e.preventDefault();
      cancel();
    }
  }

  return (
    <>
      <div className={empty ? "nb-editor is-empty" : "nb-editor"}>
        {dropTarget}
        {(kept.length + staged.length > 0 || isImporting) && (
          <Chips
            onViewing={setViewing}
            pendingImportCount={pendingImportCount}
            keptIds={kept.map(a => a.id)}
            label="Attachments"
            list={[...kept, ...staged]}
            onRemove={(id) => (kept.some((a) => a.id === id) ? setKept((all) => all.filter((a) => a.id !== id)) : remove(id))}
          />
        )}
        <textarea
          ref={box}
          aria-label="Edit Item"
          autoFocus
          rows={1}
          value={draft}
          onFocus={(e) => e.currentTarget.setSelectionRange(draft.length, draft.length)}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
        />
        {errors.map((message, i) => (
          <div key={i} role="alert" className="nb-send-error">
            <Icon name="alert" />
            {message}
          </div>
        ))}
        {error && (
          <div role="alert" className="nb-send-error">
            <Icon name="alert" />
            {error}
          </div>
        )}
        <div className="nb-editor-bar">
          <button type="button" className="nb-iconbtn" aria-label="Attach files" title="Attach files" onClick={pick}>
            <Icon name="paperclip" />
          </button>
          <span className="nb-editor-hint">
            <kbd>↵</kbd> save · <kbd>⇧↵</kbd> new line · <kbd>esc</kbd> cancel
          </span>
          <button type="button" className="nb-btn nb-btn-quiet" onClick={clear} disabled={empty}>
            Clear
          </button>
          <button type="button" className="nb-btn nb-btn-quiet" onClick={cancel}>
            Cancel
          </button>
          {empty ? (
            <button type="button" className="nb-btn nb-btn-danger" onClick={submit} disabled={isImporting}>
              <Icon name="trash" />
              Move to Trash
            </button>
          ) : (
            <button type="button" className="nb-btn nb-btn-primary" onClick={save} disabled={isImporting}>
              Save
            </button>
          )}
        </div>
      </div>
      {confirmingTrash && (
        <Dialog alert title="Move this Item to Trash?" onClose={() => setConfirmingTrash(false)} actions={<>
          <button type="button" className="nb-btn nb-btn-secondary" autoFocus onClick={() => setConfirmingTrash(false)}>Cancel</button>
          <button type="button" className="nb-btn nb-btn-danger" onClick={() => { setConfirmingTrash(false); save(); }}>Move to Trash</button>
        </>} />
      )}
    </>
  );
}
