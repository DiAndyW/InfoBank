import { attachmentFailure } from "./failure";
import { useEffect, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { attachmentStored, copyAttachment, openAttachment, revealAttachment, thumbnail, type FeedAttachment } from "./api";
import { Icon } from "./icons";

export function formatSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

const downloading = "Downloading…";
const pendingLabel = "Not uploaded yet";

export function viewable(a: FeedAttachment): boolean {
  return !a.runnable && a.mime_type.startsWith("image/");
}

function Attachment({ a, onView, onCopied, copyButtonVisible = true, closedCount }: { a: FeedAttachment; onView: (id: string) => void; onCopied?: (filename: string) => void; copyButtonVisible?: boolean; closedCount: number }) {
  const revealLabel = navigator.userAgent.includes("Windows") ? "Show in Explorer" : "Show in Finder";
  const [src, setSrc] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const busy = useRef(false);
  const [refused, setRefused] = useState(false);
  const image = !a.runnable && (a.has_thumbnail || a.mime_type.startsWith("image/"));
  const video = a.mime_type.startsWith("video/");

  useEffect(() => {
    if (!image || src) return;
    let live = true;
    thumbnail(a.id).then((path) => live && setSrc(convertFileSrc(path)), () => {});
    return () => {
      live = false;
    };
  }, [a.id, image, closedCount]);

  useEffect(() => {
    if (!note || note === downloading) return;
    const timer = setTimeout(() => setNote(null), 4000);
    return () => clearTimeout(timer);
  }, [note]);

  async function fetchThen(action: (id: string) => Promise<void>, headline = "Attachment failed to open.") {
    if (busy.current) return false;
    busy.current = true;
    try {
      const stored = await attachmentStored(a.id).catch(() => false);
      if (!stored && !a.uploaded) return false;
      setNote(stored ? null : downloading);
      await action(a.id);
      setNote(null);
      if (image && !src) {
        try { setSrc(convertFileSrc(await thumbnail(a.id))); } catch {}
      }
      return true;
    } catch (err) {
      setNote(attachmentFailure(err, headline));
      return false;
    } finally {
      busy.current = false;
    }
  }

  function open() {
    if (a.runnable) setRefused(true);
    else if (viewable(a)) {
      if (a.uploaded) onView(a.id);
      else attachmentStored(a.id).then((stored) => stored && onView(a.id), () => {});
    } else fetchThen(openAttachment);
  }

  const status = note ?? (a.uploaded ? null : pendingLabel);
  const opener = refused ? (
    <div className="nb-file is-blocked">
      <Icon name="alert" />
      <span className="nb-file-text">
        <span className="nb-file-name">NoteBank won't open {a.filename} because it can run code.</span>
        {note && <span className="nb-file-meta">{note}</span>}
      </span>
      <button type="button" className="nb-btn nb-btn-quiet" onClick={() => fetchThen(revealAttachment, "Attachment failed to reveal.")}>
        <Icon name="reveal" />
        {revealLabel}
      </button>
    </div>
  ) : image ? (
    <button type="button" className="nb-thumb" data-attachment-id={a.id} onClick={open} aria-label={`${video ? "Play" : "Open"} ${a.filename}`}>
      {src ? (
        <>
          <img src={src} alt={a.filename} onError={() => setSrc(null)} />
          {video && (
            <span className="nb-thumb-play">
              <Icon name="play" size={20} />
            </span>
          )}
        </>
      ) : (
        <span className="nb-thumb-ph">
          <Icon name="image" />
          {a.filename}
        </span>
      )}
      {status && <span className="nb-thumb-note">{status}</span>}
    </button>
  ) : (
    <button type="button" className={note && note !== downloading ? "nb-file is-error" : "nb-file"} onClick={open} aria-label={`Open ${a.filename}`}>
      <Icon name="file" />
      <span className="nb-file-text">
        <span className="nb-file-name">{a.filename}</span>
        <span className="nb-file-meta">{formatSize(a.size_bytes)}</span>
        {status && <span className="nb-file-meta">{status}</span>}
      </span>
    </button>
  );
  if (!onCopied) return opener;
  return (
    <div className="nb-attachment">
      {opener}
      {copyButtonVisible && <button type="button" className="nb-iconbtn nb-reveal nb-attachment-copy" aria-label={`Copy ${a.filename}`} title="Copy" onClick={() => fetchThen(copyAttachment, "Attachment failed to copy.").then((ok) => ok && onCopied(a.filename))}>
        <Icon name="copy" />
      </button>}
    </div>
  );
}

export function Attachments({ list, onView, onCopied, copyButtonVisible, closedCount }: { list: FeedAttachment[]; onView: (id: string) => void; onCopied?: (filename: string) => void; copyButtonVisible?: boolean; closedCount: number }) {
  return (
    <div className="nb-item-files">
      {list.map((a) => (
        // has_thumbnail in the key remounts it, and so refetches, once the Server makes one.
        <Attachment key={`${a.id}:${a.has_thumbnail}`} a={a} onView={onView} onCopied={onCopied} copyButtonVisible={copyButtonVisible} closedCount={closedCount} />
      ))}
    </div>
  );
}
