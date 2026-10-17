import { useEffect, useState, type ClipboardEvent, type FormEvent, type KeyboardEvent } from "react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { capture, MAX_ATTACHMENT_BYTES, pickFiles, stageBytes, unstage, type Staged, type StagedFiles } from "./api";
import { formatSize } from "./attachments";
import Dialog from "./Dialog";
import { Icon } from "./icons";

export default function Composer({ topicId, placeholder, onCaptured }: { topicId: string | null; placeholder: string; onCaptured: () => void }) {
  const [draft, setDraft] = useState("");
  const [staged, setStaged] = useState<Staged[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [attachErrors, setAttachErrors] = useState<string[]>([]);
  const [dragging, setDragging] = useState(false);

  async function add(stage: () => Promise<Staged>) {
    try {
      const s = await stage();
      setStaged((all) => [...all, s]);
    } catch (err) {
      failed([String(err)]);
    }
  }

  function failed(errors: string[]) {
    if (errors.length > 0) setAttachErrors((all) => [...all, ...errors]);
  }

  function addAll(result: StagedFiles) {
    setStaged((all) => [...all, ...result.staged]);
    failed(result.errors);
  }

  useEffect(() => {
    const stopStaged = listen<StagedFiles>("attachments-staged", (e) => addAll(e.payload));
    const stopDrag = getCurrentWebview().onDragDropEvent((e) =>
      setDragging(e.payload.type === "enter" || e.payload.type === "over"),
    );
    return () => {
      stopStaged.then((stop) => stop());
      stopDrag.then((stop) => stop());
    };
  }, []);

  function onPaste(e: ClipboardEvent<HTMLTextAreaElement>) {
    const pasted = Array.from(e.clipboardData.files);
    if (pasted.length === 0) return;
    e.preventDefault();
    for (const file of pasted) {
      const name = file.name || "Pasted image.png";
      if (file.size > MAX_ATTACHMENT_BYTES) {
        failed([`${name} is over 100 MB`]);
        continue;
      }
      add(async () => stageBytes(name, new Uint8Array(await file.arrayBuffer())));
    }
  }

  function remove(id: string) {
    setStaged((all) => all.filter((s) => s.id !== id));
    unstage(id).catch(() => {});
  }

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
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
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
      {attachErrors.length > 0 && (
        <Dialog
          alert
          title={attachErrors.length === 1 ? "Couldn't attach a file" : `Couldn't attach ${attachErrors.length} files`}
          onClose={() => setAttachErrors([])}
          actions={
            <button type="button" className="nb-btn nb-btn-primary" autoFocus onClick={() => setAttachErrors([])}>
              OK
            </button>
          }
        >
          <ul>
            {attachErrors.map((e, i) => (
              <li key={i}>{e}</li>
            ))}
          </ul>
        </Dialog>
      )}
      <form className="nb-composer" onSubmit={submit}>
        {error && (
          <div role="alert" className="nb-send-error">
            <Icon name="alert" />
            {error}
          </div>
        )}
        <div className="nb-composer-box">
          {staged.length > 0 && (
            <ul className="nb-staged" aria-label="Attachments to send">
              {staged.map((s) => (
                <li key={s.id} className="nb-file is-staged">
                  <Icon name={s.mime_type.startsWith("image/") ? "image" : "file"} />
                  <span className="nb-file-text">
                    <span className="nb-file-name">{s.filename}</span>
                    <span className="nb-file-meta">{formatSize(s.size_bytes)}</span>
                  </span>
                  <button type="button" className="nb-iconbtn" aria-label={`Remove ${s.filename}`} title={`Remove ${s.filename}`} onClick={() => remove(s.id)}>
                    <Icon name="x" />
                  </button>
                </li>
              ))}
            </ul>
          )}
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
              <button
                type="button"
                className="nb-iconbtn"
                aria-label="Attach files"
                title="Attach files"
                onClick={() => pickFiles().then(addAll, (err) => failed([String(err)]))}
              >
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
