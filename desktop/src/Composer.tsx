import { useEffect, useImperativeHandle, useRef, useState, type FormEvent, type KeyboardEvent, type ReactNode, type Ref } from "react";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { capture, unstage, type StagedFiles } from "./api";
import { Icon } from "./icons";
import { Chips, useStaging } from "./staging";

export type ComposerHandle = { discard: () => void; focus: () => void };

type Props = {
  acceptsDrops: boolean;
  topicId: string | null;
  placeholder: string;
  onCaptured: () => void;
  // Given in the quick-capture window: Escape cancels and the text box takes no suggestions.
  onCancel?: () => void;
  picker?: ReactNode;
  ref?: Ref<ComposerHandle>;
};

export default function Composer({ acceptsDrops, topicId, placeholder, onCaptured, onCancel, picker, ref }: Props) {
  const accepts = useRef(acceptsDrops);
  accepts.current = acceptsDrops;
  const [draft, setDraft] = useState("");
  const { staged, setStaged, addAll, onPaste, remove, pick, discard: discardStaged, dialog } = useStaging();
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const saving = useRef(false);
  // Set from Enter until the draft is cleared, so a quick second Enter can't send it twice.
  const sent = useRef(false);
  const discardAfterSave = useRef(false);
  const textarea = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const stopStaged = getCurrentWebviewWindow().listen<StagedFiles>("attachments-staged", (e) => {
      if (accepts.current) addAll(e.payload);
      else for (const s of e.payload.staged) unstage(s.id).catch(() => {});
    });
    const stopDrag = getCurrentWebview().onDragDropEvent((e) =>
      setDragging(accepts.current && (e.payload.type === "enter" || e.payload.type === "over")),
    );
    return () => {
      stopStaged.then((stop) => stop());
      stopDrag.then((stop) => stop());
    };
  }, []);

  const empty = draft.trim() === "" && staged.length === 0;

  function clear() {
    sent.current = false;
    setDraft("");
    setStaged([]);
    setError(null);
  }

  async function submit(e?: FormEvent) {
    e?.preventDefault();
    if (empty || sent.current) return;
    sent.current = true;
    saving.current = true;
    try {
      await capture(draft, staged.map((s) => s.id), topicId);
      // The quick box keeps its text until it's hidden, so it never flashes empty.
      if (!onCancel || discardAfterSave.current) clear();
      onCaptured();
    } catch (err) {
      sent.current = false;
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
        className="nb-composer"
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
            <div className="nb-composer-actions">
              {picker}
              <button type="button" className="nb-iconbtn" aria-label="Attach files" title="Attach files" onClick={() => pick().then(() => textarea.current?.focus())}>
                <Icon name="paperclip" />
              </button>
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
