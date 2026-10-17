import { useEffect, useId, useRef, useState, type ReactNode } from "react";

type Props = {
  title: ReactNode;
  hint?: ReactNode;
  alert?: boolean;
  wide?: boolean;
  className?: string;
  onClose: () => void;
  actions: ReactNode;
  children?: ReactNode;
};

export default function Dialog({ title, hint, alert, wide, className, onClose, actions, children }: Props) {
  const titleId = useId();
  const panel = useRef<HTMLDivElement>(null);
  // Read during the first render: by the time effects run, an autoFocus child has already taken focus.
  const [opener] = useState(() => document.activeElement as HTMLElement | null);

  useEffect(() => {
    if (!panel.current!.contains(document.activeElement)) panel.current!.focus();
    return () => {
      if (opener?.isConnected) opener.focus();
    };
  }, []);

  return (
    <div className="nb-scrim">
      <div
        ref={panel}
        tabIndex={-1}
        role={alert ? "alertdialog" : "dialog"}
        aria-modal="true"
        aria-labelledby={titleId}
        className={["nb-dialog", wide && "is-wide", className].filter(Boolean).join(" ")}
        onKeyDown={(e) => {
          if (e.key !== "Escape") return;
          e.stopPropagation();
          onClose();
        }}
      >
        <h2 id={titleId} className="nb-dialog-title">
          {title}
        </h2>
        {hint && <p className="nb-dialog-hint">{hint}</p>}
        {children && <div className="nb-dialog-body">{children}</div>}
        <div className="nb-dialog-actions">{actions}</div>
      </div>
    </div>
  );
}
