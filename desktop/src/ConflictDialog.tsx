import Dialog from "./Dialog";
import type { FeedItem } from "./api";

type Part = { text: string; changed: boolean };

export function diffWords(theirs: string, mine: string): Part[][] {
  const a = theirs.split(/(\s+)/).filter(Boolean);
  const b = mine.split(/(\s+)/).filter(Boolean);
  if (a.length * b.length > 4_000_000) return [[{ text: theirs, changed: false }], [{ text: mine, changed: false }]];
  const isWord = (t: string) => !/^\s/.test(t);
  const lcs = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--)
    for (let j = b.length - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const [pa, pb]: Part[][] = [[], []];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      pa.push({ text: a[i++], changed: false });
      pb.push({ text: b[j++], changed: false });
    } else if (j >= b.length || (i < a.length && lcs[i + 1][j] >= lcs[i][j + 1])) {
      pa.push({ text: a[i], changed: isWord(a[i]) });
      i++;
    } else {
      pb.push({ text: b[j], changed: isWord(b[j]) });
      j++;
    }
  }
  return [pa, pb];
}

type Props = {
  item: FeedItem;
  onClose: () => void;
  onResolve: (keep: "theirs" | "mine") => void;
  onEdit: (mineText: string | null) => void;
};

export default function ConflictDialog({ item, onClose, onResolve, onEdit }: Props) {
  const { mine } = item.conflict!;
  const [theirsText, mineText] = mine ? [item.text, item.conflict!.text] : [item.conflict!.text, item.text];
  const [theirsParts, mineParts] = theirsText !== null && mineText !== null ? diffWords(theirsText, mineText) : [null, null];
  const panes = [
    { name: "Theirs", sub: "another Device", text: theirsText, parts: theirsParts, onServer: mine, tint: "is-theirs" },
    { name: "Mine", sub: "this Device", text: mineText, parts: mineParts, onServer: !mine, tint: "is-mine" },
  ];
  return (
    <Dialog
      wide
      className="nb-conflict"
      title="This Item was edited on two Devices"
      hint="Both edits started from the same text. Choose which one to keep. The other is discarded."
      onClose={onClose}
      actions={
        <>
          <button type="button" className="nb-btn nb-btn-quiet" onClick={() => onEdit(mineText)}>
            Edit…
          </button>
          <span className="nb-spacer" />
          <button type="button" className="nb-btn nb-btn-secondary" onClick={() => onResolve("theirs")}>
            Keep theirs
          </button>
          <button type="button" className="nb-btn nb-btn-primary" onClick={() => onResolve("mine")}>
            Use mine
          </button>
        </>
      }
    >
      <div className="nb-versions">
        {panes.map((p) => (
          <section key={p.name} className="nb-version" role="group" aria-label={p.name}>
            <header className="nb-version-head">
              <span className="nb-version-name">{p.name}</span>
              <span className="nb-version-sub">{p.sub}</span>
            </header>
            <div className="nb-version-body">
              {p.text === null ? (
                <span className="nb-version-empty">(no text)</span>
              ) : (
                (p.parts ?? [{ text: p.text, changed: false }]).map((part, k) =>
                  part.changed ? (
                    <span key={k} className={p.tint}>
                      {part.text}
                    </span>
                  ) : (
                    part.text
                  ),
                )
              )}
            </div>
            <footer className={p.onServer ? "nb-version-foot is-server" : "nb-version-foot"}>{p.onServer ? "● Showing on all Devices" : "Only on this Device"}</footer>
          </section>
        ))}
      </div>
    </Dialog>
  );
}
