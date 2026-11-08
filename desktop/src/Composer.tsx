import { useEffect, useImperativeHandle, useLayoutEffect, useRef, useState, type Dispatch, type SetStateAction, type FormEvent, type KeyboardEvent, type ReactNode, type Ref } from "react";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { capture, saveDraft, unstage, type Draft, type Staged, type Target, type StagedFiles } from "./api";
import { Icon } from "./icons";
import { Chips, useStaging } from "./staging";
import type { ShowNotice } from "./Selection";

export type ComposerHandle = { discard: () => void; focus: () => void };

type Props = {
  drafts?: { place: string; initial: Draft[] | null; homeTopicId: string | null; restoreHomeTopic?: (id: string | null) => void };
  acceptsDrops: boolean;
  target: Target;
  placeholder: string;
  onCaptured: () => void;
  onNotice?: ShowNotice;
  // Given in the quick-capture window: Escape cancels and the text box takes no suggestions.
  onCancel?: () => void;
  picker?: ReactNode;
  ref?: Ref<ComposerHandle>;
};

type Place = { text: string; staged: Staged[]; touched: boolean; pending: boolean; timer?: ReturnType<typeof setTimeout>; homeTopicId: string | null; sent: boolean };

export default function Composer({ drafts, acceptsDrops, target, placeholder, onCaptured, onNotice, onCancel, picker, ref }: Props) {
  const accepts = useRef(acceptsDrops);
  accepts.current = acceptsDrops;
  const places = useRef(new Map<string, Place>());
  const cleared = useRef<{ place: string; text: string; staged: Staged[] } | null>(null);
  const [, redraw] = useState(0);
  const place = drafts?.place ?? "";
  function entry(key: string) {
    let value = places.current.get(key);
    if (!value) {
      value = { text: "", staged: [], touched: false, pending: false, homeTopicId: null, sent: false };
      places.current.set(key, value);
    }
    return value;
  }
  const current = entry(place);
  const chain = useRef(Promise.resolve());
  function enqueue(action: () => Promise<void>) {
    const result = chain.current.then(action);
    chain.current = result.catch(() => {});
    return result;
  }
  function flush(key: string) {
    const value = entry(key);
    clearTimeout(value.timer);
    value.timer = undefined;
    if (!value.pending || value.sent) return;
    value.pending = false;
    const text = value.text;
    const homeTopicId = value.homeTopicId;
    enqueue(() => saveDraft(key, text, homeTopicId)).catch((err) => {
      value.pending = true;
      setError(String(err));
    });
  }
  function schedule(key = place) {
    if (!drafts) return;
    const value = entry(key);
    value.pending = true;
    clearTimeout(value.timer);
    value.timer = setTimeout(() => flush(key), 300);
  }
  function setDraft(text: string) {
    if (text && cleared.current?.place === place) cleared.current = null;
    current.text = text;
    current.touched = true;
    schedule();
    redraw(n => n + 1);
  }
  const setStaged: Dispatch<SetStateAction<Staged[]>> = (next) => {
    current.staged = typeof next === "function" ? next(current.staged) : next;
    if (current.staged.length > 0 && cleared.current?.place === place) cleared.current = null;
    redraw(n => n + 1);
  };
  const draft = current.text;
  const { staged, addAll, onPaste, remove, pick, discard: discardStaged, dialog } = useStaging({ staged: current.staged, setStaged });
  const addStaged = useRef(addAll);
  addStaged.current = addAll;

  useLayoutEffect(() => {
    if (!drafts?.initial) return;
    for (const row of drafts.initial) {
      const value = entry(row.place);
      if (!value.touched) {
        value.text = row.text;
        value.homeTopicId = row.home_topic_id;
        if (row.place === "home") drafts.restoreHomeTopic?.(row.home_topic_id);
      }
    }
    redraw(n => n + 1);
  }, [drafts?.initial]);
  useLayoutEffect(() => {
    if (!drafts) return;
    const home = entry("home");
    if (home.homeTopicId === drafts.homeTopicId) return;
    home.homeTopicId = drafts.homeTopicId;
    if (home.text.trim()) schedule("home");
  }, [drafts?.homeTopicId, drafts?.initial]);
  useLayoutEffect(() => {
    if (!drafts) return;
    return () => flush(place);
  }, [place]);
  useEffect(() => {
    if (!drafts) return;
    const blur = () => { for (const key of places.current.keys()) flush(key); };
    window.addEventListener("blur", blur);
    return () => {
      blur();
      window.removeEventListener("blur", blur);
    };
  }, []);
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const saving = useRef(false);
  const discardAfterSave = useRef(false);
  const textarea = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const drops = new Map<string, typeof addAll | null>();
    const stopStaging = getCurrentWebviewWindow().listen<string>("attachments-staging", (e) => {
      drops.set(e.payload, accepts.current ? addStaged.current : null);
    });
    const stopStaged = getCurrentWebviewWindow().listen<StagedFiles & { drop_id?: string }>("attachments-staged", (e) => {
      const add = e.payload.drop_id === undefined ? (accepts.current ? addStaged.current : null) : drops.get(e.payload.drop_id);
      if (e.payload.drop_id !== undefined) drops.delete(e.payload.drop_id);
      if (add) add(e.payload);
      else for (const s of e.payload.staged) unstage(s.id).catch(() => {});
    });
    const stopDrag = getCurrentWebview().onDragDropEvent((e) =>
      setDragging(accepts.current && (e.payload.type === "enter" || e.payload.type === "over")),
    );
    return () => {
      stopStaging.then((stop) => stop());
      stopStaged.then((stop) => stop());
      stopDrag.then((stop) => stop());
    };
  }, []);

  const empty = draft.trim() === "" && staged.length === 0;

  function clear() {
    current.sent = false;
    current.text = "";
    current.touched = true;
    redraw(n => n + 1);
    setStaged([]);
    setError(null);
  }

  function restore(snapshot = cleared.current) {
    if (!snapshot || cleared.current !== snapshot) return;
    cleared.current = null;
    const value = entry(snapshot.place);
    value.text = snapshot.text;
    value.staged = snapshot.staged;
    value.touched = true;
    value.pending = true;
    flush(snapshot.place);
    redraw(n => n + 1);
  }

  function clearBox() {
    const snapshot = { place, text: draft, staged };
    cleared.current = snapshot;
    clear();
    current.pending = true;
    flush(place);
    textarea.current?.focus();
    onNotice?.("Cleared", { label: "Undo", onAction: () => restore(snapshot) });
  }

  async function submit(e?: FormEvent) {
    e?.preventDefault();
    if (empty || current.sent) return;
    current.sent = true;
    redraw(n => n + 1);
    current.touched = true;
    clearTimeout(current.timer);
    current.timer = undefined;
    current.pending = false;
    saving.current = true;
    try {
      const ids = staged.map((s) => s.id);
      await enqueue(() => capture(draft, ids, target, drafts ? place : undefined));
      if (discardAfterSave.current) {
        discardStaged(ids);
        clear();
      }
      // The quick box keeps its text until it's hidden, so it never flashes empty.
      else if (!onCancel) {
        current.text = "";
        current.staged = current.staged.filter(s => !ids.includes(s.id));
        current.sent = false;
        clearTimeout(current.timer);
        current.timer = undefined;
        current.pending = false;
        redraw(n => n + 1);
        setError(null);
      }
      onCaptured();
    } catch (err) {
      current.sent = false;
      redraw(n => n + 1);
      if (drafts) { current.pending = true; flush(place); }
      setError(String(err));
    } finally {
      saving.current = false;
      discardAfterSave.current = false;
    }
  }

  useImperativeHandle(ref, () => ({
    discard() {
      // Unstaging now would delete files the Item being saved points to.
      if (saving.current) {
        discardAfterSave.current = true;
        return;
      }
      discardStaged();
      clear();
    },
    focus: () => textarea.current?.focus(),
  }));

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "z" && (e.metaKey || e.ctrlKey) && !e.shiftKey && cleared.current?.place === place && draft === "" && staged.length === 0) {
      e.preventDefault();
      restore();
    }
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing && e.keyCode !== 229) {
      e.preventDefault();
      submit();
    }
  }

  return (
    <>
      {dragging && (
        <div className="nb-drop">
          <div className="nb-drop-target">
            <Icon name="paperclip" size={24} />
            <span>Drop to attach</span>
          </div>
        </div>
      )}
      {dialog}
      <form
        className={target.kind === "tunnel" ? "nb-composer is-tunnel" : "nb-composer"}
        onSubmit={submit}
        onKeyDown={(e) => {
          if (onCancel && e.key === "Escape" && !e.nativeEvent.isComposing && e.keyCode !== 229) {
            e.preventDefault();
            onCancel();
          }
        }}
      >
        {error && (
          <div role="alert" className="nb-send-error">
            <Icon name="alert" />
            {error}
          </div>
        )}
        <div className="nb-composer-box">
          {staged.length > 0 && <Chips label="Attachments to send" list={staged} onRemove={remove} />}
          <div className="nb-composer-row">
            <textarea
              ref={textarea}
              aria-label="New Item"
              placeholder={placeholder}
              rows={2}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={onKeyDown}
              onPaste={onPaste}
              {...(onCancel && { autoCorrect: "off", spellCheck: false, writingsuggestions: "false" })}
            />
          </div>
          <div className="nb-composer-footer">
            <div className="nb-composer-destination">{picker}</div>
            <div className="nb-composer-actions">
              <button type="button" className="nb-iconbtn" aria-label="Attach files" title="Attach files" onClick={() => pick().then(() => textarea.current?.focus())}>
                <Icon name="paperclip" />
              </button>
              {drafts && (draft !== "" || staged.length > 0) && !current.sent && <button type="button" className="nb-btn nb-btn-quiet" onClick={clearBox}>Clear</button>}
              <button type="submit" className="nb-btn nb-btn-primary" disabled={empty}>
                <Icon name="send" />
                Send
              </button>
            </div>
          </div>
        </div>
      </form>
    </>
  );
}
