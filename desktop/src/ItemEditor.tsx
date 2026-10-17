import { useImperativeHandle, useRef, useState, type KeyboardEvent, type Ref } from "react";
import { editItem, unstage, type FeedItem } from "./api";
import { Icon } from "./icons";
import { Chips, useStaging } from "./staging";

export type EditorHandle = { save: () => Promise<boolean> };

type Props = { item: FeedItem; onDone: (trashed: boolean) => void; onGone: (err: unknown) => void; ref: Ref<EditorHandle> };

export default function ItemEditor({ item, onDone, onGone, ref }: Props) {
  const [draft, setDraft] = useState(item.text ?? "");
  const [kept, setKept] = useState(item.attachments);
  const { staged, onPaste, remove, pick, dialog } = useStaging();
  const [error, setError] = useState<string | null>(null);
  const saving = useRef(false);
  const empty = draft.trim() === "" && kept.length === 0 && staged.length === 0;

  async function save() {
    if (saving.current) return false;
    saving.current = true;
    try {
      const removed = item.attachments.filter((a) => !kept.some((k) => k.id === a.id)).map((a) => a.id);
      const { trashed } = await editItem(item.id, draft, staged.map((s) => s.id), removed);
      onDone(trashed);
      return true;
    } catch (err) {
      if (String(err) === "That Item no longer exists") onGone(err);
      else setError(String(err));
      return false;
    } finally {
      saving.current = false;
    }
  }
  useImperativeHandle(ref, () => ({ save }));

  function cancel() {
    for (const s of staged) unstage(s.id).catch(() => {});
    onDone(false);
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    // WebKit sends the Enter that confirms an input method's text after compositionend, as keyCode 229.
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing && e.keyCode !== 229) {
      e.preventDefault();
      save();
    } else if (e.key === "Escape") {
      e.preventDefault();
      cancel();
    }
  }

  return (
    <div className={empty ? "nb-editor is-empty" : "nb-editor"}>
      {dialog}
      <textarea
        aria-label="Edit Item"
        autoFocus
        rows={Math.max(1, draft.split("\n").length)}
        value={draft}
        onFocus={(e) => e.currentTarget.setSelectionRange(draft.length, draft.length)}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={onKeyDown}
        onPaste={onPaste}
      />
      {kept.length + staged.length > 0 && (
        <Chips
          label="Attachments"
          list={[...kept, ...staged]}
          onRemove={(id) => (kept.some((a) => a.id === id) ? setKept((all) => all.filter((a) => a.id !== id)) : remove(id))}
        />
      )}
      {error && (
        <div role="alert" className="nb-send-error">
          <Icon name="alert" />
          Couldn't save the edit. Your changes are kept. {error}
        </div>
      )}
      <div className="nb-editor-bar">
        <button type="button" className="nb-iconbtn" aria-label="Attach files" title="Attach files" onClick={pick}>
          <Icon name="paperclip" />
        </button>
        {empty ? (
          <span className="nb-editor-hint is-warn">
            <Icon name="trash" size={12} />
            An empty Item goes to Trash.
          </span>
        ) : (
          <span className="nb-editor-hint">
            <kbd>↵</kbd> save · <kbd>⇧↵</kbd> new line · <kbd>esc</kbd> cancel
          </span>
        )}
        <button type="button" className="nb-btn nb-btn-quiet" onClick={cancel}>
          Cancel
        </button>
        {empty ? (
          <button type="button" className="nb-btn nb-btn-danger" onClick={save}>
            <Icon name="trash" />
            Move to Trash
          </button>
        ) : (
          <button type="button" className="nb-btn nb-btn-primary" onClick={save}>
            Save
          </button>
        )}
      </div>
    </div>
  );
}
