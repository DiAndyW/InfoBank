import { useEffect, useImperativeHandle, useLayoutEffect, useRef, useState, type FormEvent, type KeyboardEvent, type ReactNode, type Ref } from "react";
import { capture, saveDraft, unstage, type Draft, type Staged, type Target } from "./api";
import { failure as failureMessage } from "./failure";
import { Icon } from "./icons";
import { Chips, useStaging } from "./staging";
import type { ShowNotice } from "./Selection";

export type ComposerHandle = { freeze: (value: boolean) => void; waitForStaging: () => Promise<void>; discard: () => void; focus: () => void; saveDrafts: () => Promise<void> };

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

type Place = { text: string; staged: Staged[]; touched: boolean; pending: boolean; timer?: ReturnType<typeof setTimeout>; homeTopicId: string | null; sent: boolean; busy: boolean; epoch: number; persisting: Set<string>; mutations: number };

export default function Composer({ drafts, acceptsDrops, target, placeholder, onCaptured, onNotice, onCancel, picker, ref }: Props) {
  const frozen = useRef(false);
  const places = useRef(new Map<string, Place>());
  const cleared = useRef<{ place: string; text: string; staged: Staged[] } | null>(null);
  const [, redraw] = useState(0);
  const place = drafts?.place ?? "";
  function entry(key: string) {
    let value = places.current.get(key);
    if (!value) {
      value = { text: "", staged: [], touched: false, pending: false, homeTopicId: null, sent: false, busy: false, epoch: 0, persisting: new Set(), mutations: 0 };
      places.current.set(key, value);
    }
    return value;
  }
  const current = entry(place);
  const chain = useRef(Promise.resolve());
  const draftSaves = useRef(new Set<Promise<void>>());
  const draftFailure = useRef<{ reason: unknown } | null>(null);
  const draftFailures = useRef(0);
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
    const save = enqueue(() => saveDraft(key, value.text, value.homeTopicId, value.staged.map(s => s.id)));
    draftSaves.current.add(save);
    save.then(() => {
      draftSaves.current.delete(save);
      draftFailures.current = 0;
      setFailure(previous => previous?.draft ? null : previous);
    }, (err) => {
      draftSaves.current.delete(save);
      draftFailure.current = { reason: err };
      value.pending = true;
      draftFailures.current += 1;
      if (value.staged.length > 0 || draftFailures.current >= 3) setFailure(previous => previous ?? { message: failureMessage("Draft failed to save.", err), draft: true });
    });
    return save;
  }
  function schedule(key = place) {
    if (!drafts) return;
    const value = entry(key);
    value.pending = true;
    clearTimeout(value.timer);
    value.timer = setTimeout(() => flush(key), 300);
  }
  function setDraft(text: string) {
    if (frozen.current || current.busy) return;
    if (text && cleared.current?.place === place) cleared.current = null;
    current.text = text;
    current.touched = true;
    schedule();
    redraw(n => n + 1);
  }
  const epoch = current.epoch;
  async function updateStaged(change: (files: Staged[]) => Staged[]) {
    if (!drafts) {
      const next = change(current.staged);
      if (current.epoch !== epoch) {
        for (const file of next) if (!current.staged.some(s => s.id === file.id)) void unstage(file.id).catch(() => {});
        return;
      }
      current.staged = next;
      current.touched = true;
      redraw(n => n + 1);
      return;
    }
    current.mutations++;
    redraw(n => n + 1);
    return enqueue(async () => {
      const next = change(current.staged);
      try {
        if (current.epoch !== epoch) {
          for (const file of next) if (!current.staged.some(s => s.id === file.id)) void unstage(file.id).catch(() => {});
          return;
        }
        const previous = current.staged;
        const adding = next.filter(s => !previous.some(p => p.id === s.id));
        for (const file of adding) current.persisting.add(file.id);
        current.staged = next;
        current.touched = true;
        if (next.length > 0 && cleared.current?.place === place) cleared.current = null;
        current.pending = false;
        clearTimeout(current.timer);
        try {
          await saveDraft(place, current.text, current.homeTopicId, next.map(s => s.id));
          draftFailures.current = 0;
          setFailure(previous => previous?.draft ? null : previous);
        } catch (err) {
          current.pending = true;
          draftFailure.current = { reason: err };
          setFailure(previous => previous ?? { message: failureMessage("Draft failed to save.", err), draft: true });
          if (next.length < previous.length) current.staged = previous;
          if (next.length < previous.length) throw err;
        } finally {
          for (const file of adding) current.persisting.delete(file.id);
        }
      } finally {
        current.mutations--;
        redraw(n => n + 1);
      }
    });
  }

  const draft = current.text;
  const { dropTarget, setDragging, setViewing, wait, pendingImportCount, retire, staged, onPaste, remove, pick, discard: discardStaged, errors, clearErrors } = useStaging({ scope: JSON.stringify([place, epoch]), state: { staged: current.staged.filter(s => !current.persisting.has(s.id)), setStaged: next => { current.staged = typeof next === "function" ? next(current.staged) : next; redraw(n => n + 1); }, update: updateStaged }, acceptsDrops: acceptsDrops && !current.busy, frozen });

  useLayoutEffect(() => {
    if (!drafts?.initial) return;
    for (const row of drafts.initial) {
      const value = entry(row.place);
      if (!value.touched) {
        value.text = row.text;
        value.staged = row.attachments;
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
    if (home.text.trim() || home.staged.length) schedule("home");
  }, [drafts?.homeTopicId, drafts?.initial]);
  useLayoutEffect(() => {
    if (!drafts) return;
    return () => { void flush(place)?.catch(() => {}); };
  }, [place]);
  useEffect(() => {
    if (!drafts) return;
    const blur = () => { for (const key of places.current.keys()) void flush(key)?.catch(() => {}); };
    window.addEventListener("blur", blur);
    return () => {
      blur();
      window.removeEventListener("blur", blur);
    };
  }, []);
  const [failure, setFailure] = useState<{ message: string; draft: boolean } | null>(null);
  const error = failure?.message ?? null;
  function setError(message: string | null) {
    setFailure(message === null ? null : { message, draft: false });
  }
  const saving = useRef(false);
  const discardAfterSave = useRef(false);
  const textarea = useRef<HTMLTextAreaElement>(null);

  const fit = () => {
    const el = textarea.current!;
    const row = el.parentElement!;
    // Collapsing the textarea must not resize the Feed above, or the browser clamps its scroll position.
    row.style.height = `${row.offsetHeight}px`;
    el.style.overflowY = "hidden";
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
    row.style.height = "";
    el.style.overflowY = el.scrollHeight > el.clientHeight ? "auto" : "hidden";
  };

  useLayoutEffect(fit, [draft]);

  useLayoutEffect(() => {
    const observer = new ResizeObserver(fit);
    observer.observe(textarea.current!.parentElement!);
    return () => observer.disconnect();
  }, []);

  const empty = draft.trim() === "" && staged.length === 0;

  function clear() {
    current.sent = false;
    current.text = "";
    current.touched = true;
    redraw(n => n + 1);
    current.staged = [];
    setError(null);
    clearErrors();
  }

  async function restore(snapshot = cleared.current) {
    if (frozen.current || current.busy || !snapshot || cleared.current !== snapshot) return;
    const value = entry(snapshot.place);
    value.busy = true;
    redraw(n => n + 1);
    try {
      await enqueue(() => saveDraft(snapshot.place, snapshot.text, value.homeTopicId, snapshot.staged.map(s => s.id)));
      cleared.current = null;
      value.text = snapshot.text;
      value.staged = snapshot.staged;
      value.touched = true;
      redraw(n => n + 1);
    } catch (err) { setError(failureMessage("Draft failed to save.", err)); }
    finally { value.busy = false; redraw(n => n + 1); }
  }

  async function clearBox() {
    if (frozen.current || current.busy || current.mutations > 0) return;
    current.busy = true;
    redraw(n => n + 1);
    const snapshot = { place, text: draft, staged: current.staged };
    current.touched = true;
    const pending = current.pending;
    current.pending = false;
    clearTimeout(current.timer);
    try {
      await enqueue(() => saveDraft(place, "", current.homeTopicId, []));
      retire();
      current.epoch++;
      cleared.current = snapshot;
      clear();
      current.pending = false;
      textarea.current?.focus();
      onNotice?.("Cleared", { label: "Undo", onAction: () => { void restore(snapshot); } });
    } catch (err) { current.pending = pending; setError(failureMessage("Draft failed to save.", err)); }
    finally { current.busy = false; redraw(n => n + 1); }
  }

  async function submit(e?: FormEvent) {
    e?.preventDefault();
    if (frozen.current || current.busy || current.persisting.size > 0 || current.mutations > 0 || empty || current.sent) return;
    current.sent = true;
    current.epoch++;
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
      clearErrors();
      onCaptured();
    } catch (err) {
      current.sent = false;
      redraw(n => n + 1);
      if (drafts) { current.pending = true; flush(place); }
      setError(failureMessage("Item failed to send.", err));
    } finally {
      saving.current = false;
      discardAfterSave.current = false;
    }
  }

  useImperativeHandle(ref, () => ({
    freeze(value) { frozen.current = value; setDragging(false); redraw(n => n + 1); },
    waitForStaging: wait,
    discard() {
      // Unstaging now would delete files the Item being saved points to.
      if (saving.current) {
        discardAfterSave.current = true;
        return;
      }
      current.epoch++;
      discardStaged();
      clear();
    },
    focus: () => textarea.current?.focus(),
    async saveDrafts() {
      const previousFailure = draftFailure.current;
      let queued: Promise<void>;
      do {
        for (const key of places.current.keys()) flush(key);
        queued = chain.current;
        const results = await Promise.allSettled([...draftSaves.current, queued]);
        for (const result of results) {
          if (result.status === "rejected") throw result.reason;
        }
        if (draftFailure.current !== previousFailure) throw draftFailure.current!.reason;
      } while (draftSaves.current.size > 0 || chain.current !== queued || [...places.current.values()].some(value => value.pending && !value.sent));
    },
  }));

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (frozen.current || current.busy) return;
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
      {dropTarget}
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
        <div className="nb-composer-box">
          {(staged.length > 0 || pendingImportCount > 0) && <Chips onViewing={setViewing} pendingImportCount={pendingImportCount} label="Attachments to send" list={staged} onRemove={(id) => { if (!frozen.current && !current.busy) remove(id); }} />}
          <div className="nb-composer-row">
            <textarea
              ref={textarea}
              aria-label="New Item"
              placeholder={placeholder}
              style={draft === "" ? { whiteSpace: "nowrap" } : undefined}
              rows={2}
              readOnly={frozen.current || current.busy}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={onKeyDown}
              onPaste={(e) => { if (frozen.current || current.busy) e.preventDefault(); else onPaste(e); }}
              {...(onCancel && { autoCorrect: "off", spellCheck: false, writingsuggestions: "false" })}
            />
          </div>
          {error && (
            <div role="alert" className="nb-send-error">
              <Icon name="alert" />
              {error}
            </div>
          )}
          {errors.map((message, i) => (
            <div key={i} role="alert" className="nb-send-error">
              <Icon name="alert" />
              {message}
            </div>
          ))}
          <div className="nb-composer-footer">
            <div className="nb-composer-destination">{picker}</div>
            <div className="nb-composer-actions">
              <button type="button" className="nb-iconbtn" aria-label="Attach files" title="Attach files" disabled={frozen.current || current.busy} onClick={() => pick().then(() => textarea.current?.focus())}>
                <Icon name="paperclip" />
              </button>
              {drafts && (draft !== "" || staged.length > 0 || pendingImportCount > 0) && !current.sent && <button type="button" className="nb-btn nb-btn-quiet" disabled={frozen.current || current.busy || current.mutations > 0} onClick={clearBox}>Clear draft</button>}
              <button type="submit" className="nb-btn nb-btn-primary" disabled={frozen.current || current.busy || current.persisting.size > 0 || current.mutations > 0 || empty}>
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
