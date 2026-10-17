import { useId, type ReactNode } from "react";

type Props = {
  title: ReactNode;
  hint?: ReactNode;
  alert?: boolean;
  wide?: boolean;
  onClose: () => void;
  actions: ReactNode;
  children?: ReactNode;
};

export default function Dialog({ title, hint, alert, wide, onClose, actions, children }: Props) {
  const titleId = useId();
  return (
    <div className="nb-scrim">
      <div
        role={alert ? "alertdialog" : "dialog"}
        aria-modal="true"
        aria-labelledby={titleId}
        className={wide ? "nb-dialog is-wide" : "nb-dialog"}
        onKeyDown={(e) => e.key === "Escape" && onClose()}
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
