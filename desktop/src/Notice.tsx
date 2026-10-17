import { useEffect, useState } from "react";
import { Icon } from "./icons";

const SHOW_MS = 8000;

export default function Notice({ message, onClose }: { message: string; onClose: () => void }) {
  const [held, setHeld] = useState(false);

  useEffect(() => {
    if (held) return;
    const timer = setTimeout(onClose, SHOW_MS);
    return () => clearTimeout(timer);
  }, [held, message]);

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
      <button className="nb-iconbtn" aria-label="Dismiss" title="Dismiss" onClick={onClose}>
        <Icon name="x" />
      </button>
    </div>
  );
}
