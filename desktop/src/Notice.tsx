import { useEffect, useState } from "react";
import { Icon } from "./icons";

export type NoticeData = { id: number; message: string; inSearch?: boolean; action?: { label: "Undo" | "Show" | "Download"; onAction: () => void | boolean | Promise<void | boolean> } };

export function noticeFilename(filename: string): string {
  const characters = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(filename)];
  return characters.length > 40 ? characters.slice(0, 40).map(s => s.segment).join("") + "…" : filename;
}

export default function Notice({ message, action, onClose }: { message: string; action?: NoticeData["action"]; onClose: () => void }) {
  const [held, setHeld] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    // Leaving for another app can skip mouseleave, which would hold the notice forever.
    const release = () => setHeld(false);
    window.addEventListener("blur", release);
    return () => window.removeEventListener("blur", release);
  }, []);

  useEffect(() => {
    if (held || busy) return;
    const timer = setTimeout(onClose, 4000);
    return () => clearTimeout(timer);
  }, [held, busy]);

  return (
    <div
      className="nb-notice"
      role="status"
      onMouseEnter={() => setHeld(true)}
      onMouseLeave={() => setHeld(false)}
      onFocus={() => setHeld(true)}
      onBlur={() => setHeld(false)}
    >
      <span className="nb-notice-text">{message}</span>
      {action && (
        <button
          className="nb-notice-action"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try { if (await action.onAction() !== false) onClose(); }
            finally { setBusy(false); }
          }}
        >
          {action.label}
        </button>
      )}
      <button className="nb-iconbtn" aria-label="Dismiss" title="Dismiss" onClick={onClose}>
        <Icon name="x" />
      </button>
    </div>
  );
}
