import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from "react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { capture, unstage, type StagedFiles } from "./api";
import { Icon } from "./icons";
import { Chips, useStaging } from "./staging";

type Props = { acceptsDrops: boolean; topicId: string | null; placeholder: string; onCaptured: () => void };

export default function Composer({ acceptsDrops, topicId, placeholder, onCaptured }: Props) {
  const accepts = useRef(acceptsDrops);
  accepts.current = acceptsDrops;
  const [draft, setDraft] = useState("");
  const { staged, setStaged, addAll, onPaste, remove, pick, dialog } = useStaging();
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);

  useEffect(() => {
    const stopStaged = listen<StagedFiles>("attachments-staged", (e) => {
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

  async function submit(e?: FormEvent) {
    e?.preventDefault();
    if (empty) return;
    try {
      await capture(draft, staged.map((s) => s.id), topicId);
      setDraft("");
      setStaged([]);
      setError(null);
      onCaptured();
    } catch (err) {
      setError(String(err));
    }
  }

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
      <form className="nb-composer" onSubmit={submit}>
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
              aria-label="New Item"
              placeholder={placeholder}
              rows={2}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={onKeyDown}
              onPaste={onPaste}
            />
            <div className="nb-composer-actions">
              <button type="button" className="nb-iconbtn" aria-label="Attach files" title="Attach files" onClick={pick}>
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
