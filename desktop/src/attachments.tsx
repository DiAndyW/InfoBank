import { useEffect, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { openAttachment, revealAttachment, thumbnail, type FeedAttachment } from "./api";

const REVEAL_LABEL = navigator.userAgent.includes("Windows") ? "Show in Explorer" : "Show in Finder";

export function formatSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function FileIcon() {
  return (
    <svg className="icon" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M4 1.5h5l3.5 3.5v9.5h-8.5z M9 1.5v3.5h3.5" fill="none" stroke="currentColor" strokeWidth="1.2" />
    </svg>
  );
}

export function PaperclipIcon() {
  return (
    <svg className="icon" viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M11 4.5 5.8 9.7a1.3 1.3 0 0 0 1.8 1.8l5.3-5.3a2.6 2.6 0 0 0-3.7-3.7L3.9 7.8a3.9 3.9 0 0 0 5.5 5.5L13.5 9"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
      />
    </svg>
  );
}

function Attachment({ a }: { a: FeedAttachment }) {
  const [src, setSrc] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [refused, setRefused] = useState(false);
  const image = !a.runnable && (a.has_thumbnail || a.mime_type.startsWith("image/"));

  useEffect(() => {
    if (!image) return;
    let live = true;
    thumbnail(a.id).then((path) => live && setSrc(convertFileSrc(path)), () => {});
    return () => {
      live = false;
    };
  }, [a.id, image]);

  async function fetchThen(action: (id: string) => Promise<void>) {
    if (note === "Downloading…") return;
    setNote("Downloading…");
    try {
      await action(a.id);
      setNote(null);
    } catch (err) {
      setNote(String(err));
    }
  }

  function open() {
    if (a.runnable) setRefused(true);
    else fetchThen(openAttachment);
  }

  return image ? (
    <button type="button" className="thumb" onClick={open} aria-label={`Open ${a.filename}`}>
      {src ? <img src={src} alt={a.filename} /> : <span className="placeholder">{a.filename}</span>}
      {note && <span className="note">{note}</span>}
    </button>
  ) : (
    <span className="attachment">
      <button type="button" className="chip" onClick={open} aria-label={`Open ${a.filename}`}>
        <FileIcon />
        <span className="name">{a.filename}</span>
        <span className="size">{formatSize(a.size_bytes)}</span>
        {note && <span className="note">{note}</span>}
      </button>
      {refused && (
        <span className="refusal">
          <span>NoteBank won't open {a.filename} because it can run code.</span>
          <button type="button" onClick={() => fetchThen(revealAttachment)}>
            {REVEAL_LABEL}
          </button>
        </span>
      )}
    </span>
  );
}

export function Attachments({ list }: { list: FeedAttachment[] }) {
  return (
    <div className="attachments">
      {list.map((a) => (
        // has_thumbnail in the key remounts it, and so refetches, once the Server makes one.
        <Attachment key={`${a.id}:${a.has_thumbnail}`} a={a} />
      ))}
    </div>
  );
}
