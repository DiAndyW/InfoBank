import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { Icon } from "./icons";

export type MenuEntry =
  | { label: string; onSelect?: () => void; checked?: boolean; submenu?: MenuEntry[]; danger?: boolean }
  | { separator: true };

type Props = { label: string; entries: MenuEntry[]; open: boolean; onOpenChange: (open: boolean) => void };

// Room the popup needs below its trigger before it opens above instead.
const ROOM_BELOW_PX = 240;

export default function Menu({ label, entries, open, onOpenChange }: Props) {
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const [submenu, setSubmenu] = useState<number | null>(null);
  const [place, setPlace] = useState<{ style: CSSProperties; above: boolean }>({ style: {}, above: false });

  useLayoutEffect(() => {
    if (!open) return;
    const r = trigger.current!.getBoundingClientRect();
    const right = window.innerWidth - r.right;
    const above = window.innerHeight - r.bottom < ROOM_BELOW_PX;
    setPlace({ style: above ? { bottom: window.innerHeight - r.top, right } : { top: r.bottom, right }, above });
  }, [open]);

  useEffect(() => {
    if (!open) {
      setSubmenu(null);
      return;
    }
    root.current?.querySelector<HTMLElement>("[role^=menuitem]")?.focus();
    const away = (e: Event) => {
      if (!root.current?.contains(e.target as Node)) onOpenChange(false);
    };
    document.addEventListener("mousedown", away);
    window.addEventListener("scroll", away, true);
    return () => {
      document.removeEventListener("mousedown", away);
      window.removeEventListener("scroll", away, true);
    };
  }, [open]);

  function close() {
    onOpenChange(false);
    trigger.current?.focus();
  }

  const list = (items: MenuEntry[], name: string, top = false) => (
    <div role="menu" aria-label={name} className={top ? `nb-menu nb-menu-popup${place.above ? " above" : ""}` : "nb-menu nb-submenu"} style={top ? place.style : undefined}>
      {items.map((entry, i) => {
        if ("separator" in entry) return <div key={i} className="nb-menu-sep" role="separator" />;
        const className = entry.danger ? "nb-menu-item is-danger" : "nb-menu-item";
        const check = <span className="nb-menu-check">{entry.checked && <Icon name="check" />}</span>;
        return entry.submenu ? (
          <div key={i} className="nb-menu-wrap" onMouseEnter={() => setSubmenu(i)}>
            <button
              role="menuitem"
              aria-haspopup="menu"
              aria-expanded={submenu === i}
              className={submenu === i ? `${className} is-active` : className}
              onClick={() => setSubmenu(i)}
            >
              {check}
              <span className="nb-menu-label">{entry.label}</span>
              <Icon name="chevron-left" className="nb-menu-sub" />
            </button>
            {submenu === i && list(entry.submenu, entry.label)}
          </div>
        ) : (
          <button
            key={i}
            role={entry.checked === undefined ? "menuitem" : "menuitemradio"}
            aria-checked={entry.checked}
            className={className}
            onClick={() => {
              close();
              entry.onSelect?.();
            }}
          >
            {check}
            <span className="nb-menu-label">{entry.label}</span>
          </button>
        );
      })}
    </div>
  );

  return (
    <div
      className="nb-menu-root"
      ref={root}
      onKeyDown={(e) => {
        if (e.key === "Escape" && open) {
          e.stopPropagation();
          close();
        }
      }}
    >
      <button
        ref={trigger}
        className={open ? "nb-iconbtn nb-reveal is-active" : "nb-iconbtn nb-reveal"}
        aria-label={label}
        title={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => onOpenChange(!open)}
      >
        <Icon name="more" />
      </button>
      {open && list(entries, label, true)}
    </div>
  );
}
