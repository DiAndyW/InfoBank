import { Fragment, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { Icon } from "./icons";

type Choice = { label: string; onSelect: () => void; checked?: boolean };
// `onCreate` resolves to an error to show, or null once it has picked the new choice.
type Create = { label: string; onNew: (from: HTMLElement) => void; onCreate: (name: string, from: HTMLElement) => Promise<string | null> };

export type MenuEntry =
  | { label: string; onSelect?: () => void; checked?: boolean; submenu?: MenuEntry[]; danger?: boolean; keepOpen?: boolean }
  | { separator: true }
  | { heading: string }
  | { choices: Choice[]; filter: string; create?: Create }
  | { node: ReactNode };

// Without `trigger` the menu opens from a ⋯ button; with it, from a pill showing `trigger`.
type Props = { label: string; entries: MenuEntry[]; open: boolean; onOpenChange: (open: boolean) => void; trigger?: ReactNode };

// Room the popup needs below its trigger before it opens above instead.
const ROOM_BELOW_PX = 240;
// How long a pointer heading for a submenu may pause before it closes.
const AIM_MS = 400;

export default function Menu({ label, entries, open, onOpenChange, trigger: shown }: Props) {
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const [submenu, setSubmenu] = useState<number | null>(null);
  const [query, setQuery] = useState("");
  const [createError, setCreateError] = useState<string | null>(null);
  const creating = useRef(false);
  const [upFor, setUpFor] = useState<number | null>(null);
  // Set when the keyboard (or a click) opens the submenu, so focus follows; hovering opens it without moving focus.
  const focusSubmenu = useRef(false);
  const [place, setPlace] = useState<{ style: CSSProperties; above: boolean }>({ style: {}, above: false });

  useLayoutEffect(() => {
    if (!open) return;
    const r = trigger.current!.getBoundingClientRect();
    const side = shown === undefined ? { right: window.innerWidth - r.right } : { left: r.left };
    const above = window.innerHeight - r.bottom < ROOM_BELOW_PX;
    setPlace({ style: above ? { bottom: window.innerHeight - r.top, ...side } : { top: r.bottom, ...side }, above });
  }, [open]);

  useEffect(() => {
    setQuery("");
    setCreateError(null);
    if (!open) {
      setSubmenu(null);
      setUpFor(null);
      return;
    }
    root.current?.querySelector<HTMLElement>(".nb-menu-filter input, [role^=menuitem]")?.focus();
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

  useLayoutEffect(() => {
    if (submenu === null || upFor === submenu) return;
    const r = root.current?.querySelector(".nb-submenu")?.getBoundingClientRect();
    if (r && r.bottom > window.innerHeight) setUpFor(submenu);
  }, [submenu]);

  useEffect(() => {
    setQuery("");
    if (submenu === null || !focusSubmenu.current) return;
    focusSubmenu.current = false;
    root.current?.querySelector<HTMLElement>(".nb-submenu :is(.nb-menu-filter input, [role^=menuitem])")?.focus();
  }, [submenu]);

  // After the pointer leaves a submenu's row, the submenu stays while the pointer keeps getting closer to it,
  // even across other rows, and closes once it backs off past where it left.
  const stopAiming = useRef<(() => void) | null>(null);
  useEffect(() => () => stopAiming.current?.(), []);

  function aim(fromX: number, sub: HTMLElement | null) {
    stopAiming.current?.();
    if (!sub) return setSubmenu(null);
    const r = sub.getBoundingClientRect();
    const edge = fromX >= r.right ? r.right : r.left;
    const start = Math.abs(fromX - edge);
    let gap = start;
    let timer = setTimeout(close, AIM_MS);
    const onMove = (e: MouseEvent) => {
      const next = Math.abs(e.clientX - edge);
      if (next > start) return close();
      if (next < gap) {
        clearTimeout(timer);
        timer = setTimeout(close, AIM_MS);
      }
      gap = next;
    };
    function stop() {
      clearTimeout(timer);
      document.removeEventListener("mousemove", onMove);
      stopAiming.current = null;
    }
    function close() {
      stop();
      setSubmenu(null);
    }
    document.addEventListener("mousemove", onMove);
    stopAiming.current = stop;
  }

  async function create({ onCreate }: Create, name: string, from: HTMLElement) {
    if (creating.current) return;
    creating.current = true;
    try {
      const error = await onCreate(name, from);
      if (error) setCreateError(error);
      else onOpenChange(false);
    } finally {
      creating.current = false;
    }
  }

  function openSubmenu(i: number) {
    focusSubmenu.current = true;
    setSubmenu(i);
  }

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === "Escape" && open) {
      e.stopPropagation();
      close();
      return;
    }
    const item = (e.target as HTMLElement).closest<HTMLElement>("[role^=menuitem]");
    const menu = item?.closest<HTMLElement>("[role=menu]");
    if (!item || !menu) return;
    const items = Array.from(menu.querySelectorAll<HTMLElement>("[role^=menuitem]")).filter((el) => el.closest("[role=menu]") === menu);
    const at = items.indexOf(item);
    const go = { ArrowDown: at + 1, ArrowUp: at - 1, Home: 0, End: items.length - 1 }[e.key];
    if (go !== undefined) {
      e.preventDefault();
      items[(go + items.length) % items.length].focus();
    } else if (e.key === "ArrowRight" && item.getAttribute("aria-haspopup")) {
      e.preventDefault();
      item.click();
    } else if (e.key === "ArrowLeft" && menu.classList.contains("nb-submenu")) {
      e.preventDefault();
      setSubmenu(null);
      menu.parentElement!.querySelector<HTMLElement>("[aria-haspopup]")!.focus();
    }
  }

  function close() {
    onOpenChange(false);
    trigger.current?.focus();
  }

  const check = (checked?: boolean) => <span className="nb-menu-check">{checked && <Icon name="check" />}</span>;

  const button = (entry: { label: string; onSelect?: () => void; checked?: boolean; danger?: boolean; keepOpen?: boolean }, key: number) => (
    <button
      type="button"
      key={key}
      role={entry.checked === undefined ? "menuitem" : "menuitemradio"}
      aria-checked={entry.checked}
      className={entry.danger ? "nb-menu-item is-danger" : "nb-menu-item"}
      onClick={() => {
        if (!entry.keepOpen) close();
        entry.onSelect?.();
      }}
    >
      {check(entry.checked)}
      <span className="nb-menu-label">{entry.label}</span>
    </button>
  );

  const list = (items: MenuEntry[], name: string, top = false) => (
    <div role="menu" aria-label={name} className={top ? `nb-menu nb-menu-popup${place.above ? " above" : ""}` : `nb-menu nb-submenu${upFor === submenu ? " up" : ""}`} style={top ? place.style : undefined}>
      {items.map((entry, i) => {
        if ("separator" in entry) return <div key={i} className="nb-menu-sep" role="separator" />;
        if ("heading" in entry)
          return (
            <div key={i} className="nb-menu-heading" role="presentation">
              {entry.heading}
            </div>
          );
        if ("node" in entry) return <Fragment key={i}>{entry.node}</Fragment>;
        if ("choices" in entry) {
          const name = query.trim();
          const shown = entry.choices.filter((c) => c.label.toLocaleLowerCase().includes(name.toLocaleLowerCase()));
          const offerCreate = entry.create && name !== "" && !entry.choices.some((c) => c.label.toLocaleLowerCase() === name.toLocaleLowerCase());
          return (
            <Fragment key={i}>
              <div className="nb-search nb-menu-filter">
                <Icon name="search" />
                <input
                  type="search"
                  aria-label={entry.filter}
                  placeholder={entry.filter}
                  value={query}
                  onChange={(e) => {
                    setQuery(e.target.value);
                    setCreateError(null);
                  }}
                  onKeyDown={(e) => {
                    const composing = e.nativeEvent.isComposing || e.keyCode === 229;
                    if (e.key === "ArrowDown") {
                      e.preventDefault();
                      e.currentTarget.closest("[role=menu]")?.querySelector<HTMLElement>("[role^=menuitem]")?.focus();
                    } else if (e.key === "Enter") {
                      e.preventDefault();
                      if (composing) return;
                      if (shown[0]) {
                        close();
                        shown[0].onSelect();
                      } else if (offerCreate) create(entry.create!, name, e.currentTarget);
                    } else if (e.key === "Escape" && query && !composing) {
                      e.stopPropagation();
                      setQuery("");
                      setCreateError(null);
                    }
                  }}
                />
              </div>
              <div className="nb-menu-scroll">{shown.map(button)}</div>
              {entry.create && (name === "" || offerCreate) && (
                <>
                  <div className="nb-menu-sep" role="separator" />
                  {name === "" ? (
                    <button
                      type="button"
                      role="menuitem"
                      className="nb-menu-item"
                      onClick={(e) => {
                        entry.create!.onNew(e.currentTarget);
                        onOpenChange(false);
                      }}
                    >
                      {check()}
                      <span className="nb-menu-label">{entry.create.label}</span>
                    </button>
                  ) : (
                    <button type="button" role="menuitem" className="nb-menu-item" onClick={(e) => create(entry.create!, name, e.currentTarget)}>
                      <span className="nb-menu-check"><Icon name="plus" /></span>
                      <span className="nb-menu-label">Create “{name}”</span>
                    </button>
                  )}
                </>
              )}
              {createError && (
                <div className="nb-field-error" role="alert">
                  {createError}
                </div>
              )}
            </Fragment>
          );
        }
        const className = entry.danger ? "nb-menu-item is-danger" : "nb-menu-item";
        return entry.submenu ? (
          <div
            key={i}
            className="nb-menu-wrap"
            onMouseEnter={() => {
              stopAiming.current?.();
              setSubmenu(i);
            }}
            onMouseLeave={(e) => {
              // A pointer drifting off must not close a submenu the person is typing a filter into.
              if (e.currentTarget.querySelector(".nb-menu-filter input") === document.activeElement) return;
              aim(e.clientX, e.currentTarget.querySelector<HTMLElement>(".nb-submenu"));
            }}
          >
            <button
              type="button"
              role="menuitem"
              aria-haspopup="menu"
              aria-expanded={submenu === i}
              className={submenu === i ? `${className} is-active` : className}
              onClick={() => openSubmenu(i)}
            >
              {check(entry.checked)}
              <span className="nb-menu-label">{entry.label}</span>
              <Icon name="chevron-right" className="nb-menu-sub" />
            </button>
            {submenu === i && list(entry.submenu, entry.label)}
          </div>
        ) : (
          button(entry, i)
        );
      })}
    </div>
  );

  return (
    <div
      className="nb-menu-root"
      ref={root}
      onKeyDown={onKeyDown}
    >
      <button
        type="button"
        ref={trigger}
        className={[shown === undefined ? "nb-iconbtn nb-reveal" : "nb-pill", open && "is-active"].filter(Boolean).join(" ")}
        aria-label={label}
        title={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => onOpenChange(!open)}
      >
        {shown === undefined ? <Icon name="more" /> : <>{shown}<Icon name="chevron-down" /></>}
      </button>
      {open && list(entries, label, true)}
    </div>
  );
}
