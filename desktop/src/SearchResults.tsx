import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { searchItems, type SearchItem, type SearchQuery, type Topic } from "./api";
import { Icon } from "./icons";
import Menu from "./Menu";

const WAIT_MS = 150;

type Range = "any" | "week" | "month" | "year" | "custom";
const RANGES: [Range, string][] = [
  ["any", "Any time"],
  ["week", "Past week"],
  ["month", "Past month"],
  ["year", "Past year"],
  ["custom", "Custom…"],
];

// A local day's midnight; the day after a To date ends it, so a clock-change day keeps its real length.
const midnight = (day: string, plusDays = 0) => {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(y, m - 1, d + plusDays).getTime() * 1000;
};

// Matches arrive wrapped in U+E000 … U+E001.
const marks = (s: string) =>
  s.split(/([^]*)/).map((part, i) => (part.startsWith("") ? <mark key={i}>{part.slice(1, -1)}</mark> : part));

type Props = { text: string; topics: Topic[]; hidden: boolean; onOpen: (it: SearchItem) => void };

export default function SearchResults({ text, topics, hidden, onOpen }: Props) {
  const [items, setItems] = useState<SearchItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [exhausted, setExhausted] = useState(false);
  const pages = useRef(1);
  const loading = useRef(false);
  // Answers can arrive out of order; only the latest request may render.
  const latest = useRef(0);
  const [place, setPlace] = useState("all"); // "all", "inbox", "tunnel", or a Topic id
  const [range, setRange] = useState<Range>("any");
  // Set when a preset is picked, not on every render, so the query stays the same between renders.
  const [presetFrom, setPresetFrom] = useState<number | null>(null);
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [hasFiles, setHasFiles] = useState(false);
  const [menu, setMenu] = useState<"place" | "date" | null>(null);
  const filtered = place !== "all" || range !== "any" || hasFiles;
  const query: SearchQuery = {
    text,
    place: place === "all" || place === "inbox" || place === "tunnel" ? { kind: place } : { kind: "topic", id: place },
    from_us: range === "custom" ? (from ? midnight(from) : null) : presetFrom,
    to_us: range === "custom" && to ? midnight(to, 1) : null,
    has_files: hasFiles,
  };
  const queryKey = JSON.stringify(query);

  useEffect(() => {
    if (place !== "all" && place !== "inbox" && place !== "tunnel" && !topics.some((t) => t.id === place)) setPlace("all");
  }, [topics]);

  function pickRange(r: Range) {
    setRange(r);
    if (r === "any" || r === "custom") return setPresetFrom(null);
    const d = new Date();
    if (r === "week") d.setDate(d.getDate() - 7);
    else {
      // Mar 31 back a month is Feb 28/29, not Mar 3.
      const day = d.getDate();
      d.setDate(1);
      d.setMonth(d.getMonth() - (r === "month" ? 1 : 12));
      d.setDate(Math.min(day, new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()));
    }
    setPresetFrom(d.getTime() * 1000);
  }

  async function load(pageCount: number) {
    const id = ++latest.current;
    loading.current = true;
    let all: SearchItem[] = [];
    let page: SearchItem[] = [];
    try {
      for (let i = 0; i < pageCount; i++) {
        const last = all[all.length - 1];
        page = await searchItems(query, last ? { capture_time_us: last.capture_time_us, id: last.id } : null);
        all = all.concat(page);
        if (page.length === 0) break;
      }
    } catch (e) {
      if (id !== latest.current) return;
      loading.current = false;
      setError(String(e));
      return;
    }
    if (id !== latest.current) return;
    loading.current = false;
    pages.current = pageCount;
    setItems(all);
    setError(null);
    setExhausted(page.length === 0);
  }

  // While hidden, a change only marks the results stale; they reload once shown.
  const hiddenNow = useRef(hidden);
  hiddenNow.current = hidden;
  const stale = useRef(false);
  useEffect(() => {
    if (!hidden && stale.current) {
      stale.current = false;
      load(pages.current);
    }
  }, [hidden]);

  useEffect(() => {
    const timer = setTimeout(() => load(1), WAIT_MS);
    const unlisten = listen("items-changed", () => {
      if (hiddenNow.current) stale.current = true;
      else load(pages.current);
    });
    return () => {
      clearTimeout(timer);
      unlisten.then((stop) => stop());
    };
  }, [queryKey]);

  return (
    <main className="nb-results" hidden={hidden}>
      <header className="nb-results-head">
        <h2 className="nb-results-title">Results for "{text.trim()}"</h2>
        <div className="nb-filters">
          <Menu
            label="Place"
            open={menu === "place"}
            onOpenChange={(o) => setMenu(o ? "place" : null)}
            trigger={
              <>
                <Icon name={place === "all" ? "all" : place === "inbox" ? "inbox" : place === "tunnel" ? "send" : "topic"} />
                {place === "all" ? "Anywhere" : place === "inbox" ? "Inbox" : place === "tunnel" ? "Tunnel" : topics.find((t) => t.id === place)?.name}
              </>
            }
            entries={[
              { label: "Anywhere", checked: place === "all", onSelect: () => setPlace("all") },
              { label: "Inbox", checked: place === "inbox", onSelect: () => setPlace("inbox") },
              { label: "Tunnel", checked: place === "tunnel", onSelect: () => setPlace("tunnel") },
              ...topics.filter((t) => !t.archived).map((t) => ({ label: t.name, checked: place === t.id, onSelect: () => setPlace(t.id) })),
              ...(topics.some((t) => t.archived)
                ? [
                    { separator: true as const },
                    { heading: "Archived" },
                    ...topics.filter((t) => t.archived).map((t) => ({ label: t.name, checked: place === t.id, onSelect: () => setPlace(t.id) })),
                  ]
                : []),
            ]}
          />
          <Menu
            label="Date"
            open={menu === "date"}
            onOpenChange={(o) => setMenu(o ? "date" : null)}
            trigger={
              <>
                <Icon name="calendar" />
                {RANGES.find(([value]) => value === range)![1]}
              </>
            }
            entries={RANGES.map(([value, label]) => ({ label, checked: range === value, onSelect: () => pickRange(value) }))}
          />
          {range === "custom" && (
            <>
              <input type="date" className="nb-input" aria-label="From" value={from} onChange={(e) => setFrom(e.target.value)} />
              <input type="date" className="nb-input" aria-label="To" value={to} onChange={(e) => setTo(e.target.value)} />
            </>
          )}
          <button className={hasFiles ? "nb-pill is-on" : "nb-pill"} aria-pressed={hasFiles} onClick={() => setHasFiles(!hasFiles)}>
            <Icon name="paperclip" />
            Has files
          </button>
        </div>
      </header>
      {error && (
        <div role="alert" className="nb-send-error">
          <Icon name="alert" />
          Couldn't search. {error}
        </div>
      )}
      <div
        className="nb-feed-scroll"
        data-testid="results"
        onScroll={(e) => {
          const el = e.currentTarget;
          if (!exhausted && !loading.current && el.scrollHeight - el.scrollTop - el.clientHeight < 40) load(pages.current + 1);
        }}
      >
        <div className="nb-feed-col">
          {items?.length === 0 ? (
            <div className="nb-empty">
              <p className="nb-empty-title">No Items match.</p>
              {filtered && (
                <button
                  className="nb-btn nb-btn-secondary"
                  onClick={() => {
                    setPlace("all");
                    pickRange("any");
                    setFrom("");
                    setTo("");
                    setHasFiles(false);
                  }}
                >
                  Clear filters
                </button>
              )}
            </div>
          ) : (
            items?.map((it) => {
              const time = new Date(it.capture_time_us / 1000);
              const topic = topics.find((t) => t.id === it.topic_id);
              return (
                <button key={it.id} className="nb-item nb-result" onClick={() => onOpen(it)}>
                  <span className="nb-item-body">
                    {it.marked_text !== null && <span className="nb-item-text">{marks(it.marked_text)}</span>}
                    {it.marked_filenames.length > 0 && (
                      <span className="nb-result-files">
                        {it.marked_filenames.map((name, i) => (
                          <span key={it.attachments[i].id} className="nb-topic-chip">
                            <Icon name="file" size={12} />
                            <span className="nb-chip-label">{marks(name)}</span>
                          </span>
                        ))}
                      </span>
                    )}
                  </span>
                  <span className="nb-item-meta">
                    <span className="nb-topic-chip" title={`In ${it.in_tunnel ? "Tunnel" : topic?.name ?? "Inbox"}`}>
                      <Icon name={it.in_tunnel ? "send" : topic ? "topic" : "inbox"} size={12} />
                      <span className="nb-chip-label">{it.in_tunnel ? "Tunnel" : topic?.name ?? "Inbox"}</span>
                    </span>
                    <time className="nb-item-time">
                      {time.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}{" "}
                      {time.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}
                    </time>
                  </span>
                </button>
              );
            })
          )}
        </div>
      </div>
    </main>
  );
}
