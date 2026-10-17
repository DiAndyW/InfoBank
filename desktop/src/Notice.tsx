import { useEffect, useState } from "react";
import { Icon } from "./icons";

const SHOW_MS = 8000;

export type NoticeData = { id: number; message: string; action?: { label: "Undo" | "Show"; onAction: () => void } };

export default function Notice({ message, action, onClose }: { message: string; action?: NoticeData["action"]; onClose: () => void }) {
  const [held, setHeld] = useState(false);

  useEffect(() => {
    if (held) return;
    const timer = setTimeout(onClose, SHOW_MS);
    return () => clearTimeout(timer);
  }, [held]);

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
          onClick={() => {
            action.onAction();
            onClose();
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
