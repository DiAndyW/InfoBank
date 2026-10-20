import { useEffect, useState } from "react";
import { Icon } from "./icons";

const SHOW_MS = 8000;

export type NoticeData = { id: number; message: string; action?: { label: "Undo" | "Show"; onAction: () => void } };

export default function Notice({ message, action, onClose }: { message: string; action?: NoticeData["action"]; onClose: () => void }) {
  const [held, setHeld] = useState(false);
  const [focused, setFocused] = useState(document.hasFocus());

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
    if (held || !focused) return;
    const timer = setTimeout(onClose, SHOW_MS);
    return () => clearTimeout(timer);
  }, [held, focused]);

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
