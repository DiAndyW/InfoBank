import { useEffect, useState, type ClipboardEvent, type FormEvent, type KeyboardEvent } from "react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { capture, MAX_ATTACHMENT_BYTES, pickFiles, stageBytes, unstage, type Staged, type StagedFiles } from "./api";
import { FileIcon, formatSize, PaperclipIcon } from "./attachments";

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
      {dragging && <div className="drop-overlay">Drop to attach</div>}
      {attachErrors.length > 0 && (
        <div className="modal-backdrop">
          <div
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="attach-errors-title"
            className="modal"
            onKeyDown={(e) => e.key === "Escape" && setAttachErrors([])}
          >
            <h2 id="attach-errors-title">
              {attachErrors.length === 1 ? "Couldn't attach a file" : `Couldn't attach ${attachErrors.length} files`}
            </h2>
            <ul>
              {attachErrors.map((e, i) => (
                <li key={i}>{e}</li>
              ))}
            </ul>
            <button type="button" autoFocus onClick={() => setAttachErrors([])}>
              OK
            </button>
          </div>
        </div>
      )}
      {error && (
        <p role="alert" className="composer-error">
          {error}
        </p>
      )}
      <form className="composer" onSubmit={submit}>
        {staged.length > 0 && (
          <ul className="staged" aria-label="Attachments to send">
            {staged.map((s) => (
              <li key={s.id} className="chip">
                <FileIcon />
                <span className="name">{s.filename}</span>
                <span className="size">{formatSize(s.size_bytes)}</span>
                <button type="button" aria-label={`Remove ${s.filename}`} onClick={() => remove(s.id)}>
                  ✕
                </button>
              </li>
            ))}
          </ul>
        )}
        <div className="composer-row">
          <textarea
            aria-label="New Item"
            placeholder={placeholder}
            rows={2}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKeyDown}
            onPaste={onPaste}
          />
          <button
            type="button"
            className="attach"
            aria-label="Attach files"
            onClick={() => pickFiles().then(addAll, (err) => failed([String(err)]))}
          >
            <PaperclipIcon />
          </button>
          <button type="submit" disabled={empty}>
            Send
          </button>
        </div>
      </form>
    </>
  );
}
