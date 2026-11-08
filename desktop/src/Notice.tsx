import { useEffect, useState } from "react";
import { Icon } from "./icons";

export type NoticeData = { id: number; message: string; inSearch?: boolean; action?: { label: "Undo" | "Show"; onAction: () => void | boolean | Promise<void | boolean> } };

export default function Notice({ message, action, onClose }: { message: string; action?: NoticeData["action"]; onClose: () => void }) {
  const [held, setHeld] = useState(false);
  const [focused, setFocused] = useState(document.hasFocus());
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const on = () => setFocused(true);
    const off = () => setFocused(false);
    window.addEventListener("focus", on);
    window.addEventListener("blur", off);
    return () => {
      window.removeEventListener("focus", on);
      window.removeEventListener("blur", off);
    };
  }, []);

  useEffect(() => {
    if (held || !focused || busy) return;
    const timer = setTimeout(onClose, 4000);
    return () => clearTimeout(timer);
  }, [held, focused, busy]);

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
