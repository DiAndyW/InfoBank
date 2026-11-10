import { useEffect, useRef, useState, type MouseEvent } from "react";
import { discardCopyItems, finishCopyItems, prepareCopyItems, setItemsTrashed } from "./api";
import { Icon } from "./icons";
import type { NoticeData } from "./Notice";

type Item = { id: string; sync_error: string | null };
export type ShowNotice = (message: string, action?: NoticeData["action"]) => void;

export function useItemSelection({ items, scope, enabled, onNotice, onError }: {
  items: Item[]; scope: string; enabled: boolean; onNotice: ShowNotice; onError: (title: string, error: unknown) => void;
}) {
  const [ids, setIDs] = useState<Set<string>>(new Set());
  const [selecting, setSelecting] = useState(false);
  const [busy, setBusy] = useState(false);
  const anchor = useRef<string | null>(null);
  const generation = useRef(0);
  const running = useRef(false);
  const token = useRef<string | null>(null);
  const orderedIDs = items.filter(i => !i.sync_error).map(i => i.id);
  const availableKey = JSON.stringify(orderedIDs);

  function clear() {
    generation.current++;
    if (token.current) void discardCopyItems(token.current).catch(() => {});
    token.current = null;
    anchor.current = null;
    setIDs(new Set());
    setSelecting(false);
    setBusy(false);
    running.current = false;
  }

  useEffect(() => {
    clear();
    return () => {
      generation.current++;
      if (token.current) void discardCopyItems(token.current).catch(() => {});
      token.current = null;
    };
  }, [scope, enabled]);

  useEffect(() => {
    const next = new Set([...ids].filter(id => orderedIDs.includes(id)));
    if (next.size === ids.size) return;
    generation.current++;
    if (token.current) void discardCopyItems(token.current).catch(() => {});
    token.current = null;
    running.current = false;
    setBusy(false);
    setIDs(next);
    if (!next.size) setSelecting(false);
  }, [availableKey]);

  useEffect(() => {
    if (!selecting || !enabled) return;
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || document.querySelector('[aria-modal="true"]') || (event.target as HTMLElement).closest("input, textarea, [contenteditable]")) return;
      event.preventDefault();
      clear();
    };
    window.addEventListener("keydown", escape);
    return () => window.removeEventListener("keydown", escape);
  }, [selecting, enabled]);

  function pick(id: string, event: Pick<MouseEvent, "metaKey" | "ctrlKey" | "shiftKey">) {
    if (!enabled || (!selecting && !event.metaKey && !event.ctrlKey)) return false;
    if (running.current || !orderedIDs.includes(id)) return true;
    const next = new Set(ids);
    if (event.shiftKey && anchor.current && orderedIDs.includes(anchor.current)) {
      const a = orderedIDs.indexOf(anchor.current), b = orderedIDs.indexOf(id);
      orderedIDs.slice(Math.min(a, b), Math.max(a, b) + 1).forEach(value => next.add(value));
    } else if (next.has(id)) next.delete(id);
    else next.add(id);
    anchor.current = id;
    setIDs(next);
    setSelecting(next.size > 0);
    return true;
  }

  async function run(action: "copy" | "trash" | "restore", tunnel = false) {
    if (running.current || !enabled || !ids.size) return;
    const selected = orderedIDs.filter(id => ids.has(id));
    const version = generation.current;
    const current = () => generation.current === version;
    const count = `${selected.length} ${selected.length === 1 ? "Item" : "Items"}`;
    running.current = true;
    setBusy(true);
    let copied = false;
    let prepared: string | undefined;
    try {
      if (action === "copy") {
        prepared = await prepareCopyItems(selected);
        if (!current()) return;
        token.current = prepared;
        await finishCopyItems(prepared);
        token.current = null;
        copied = true;
        if (!current()) return;
      }
      if (action !== "copy" || tunnel) await setItemsTrashed(selected, action !== "restore");
      const trashed = action === "trash" || (action === "copy" && tunnel);
      let undoing = false;
      onNotice(trashed ? `${count}${copied ? " copied · moved" : " moved"} to Trash` : `${count} ${copied ? "copied" : "restored"}`,
        trashed ? { label: "Undo", onAction: async () => {
          if (undoing) return false;
          undoing = true;
          try { await setItemsTrashed(selected, false); return true; }
          catch (error) { onError("Couldn't restore the Items", error); return false; }
          finally { undoing = false; }
        } } : undefined);
      if (current()) clear();
    } catch (error) {
      if (current()) onError(copied ? "Items copied, but couldn't move them to Trash" : "Couldn't finish the batch action", error);
    } finally {
      if (prepared) void discardCopyItems(prepared).catch(() => {});
      if (current()) { token.current = null; running.current = false; setBusy(false); }
    }
  }

  return { ids, selecting, busy, pick, clear, enter: () => setSelecting(true), run };
}

export function SelectionBar({ selection, trash = false, tunnel = false, trashAfterCopy = false }: {
  selection: ReturnType<typeof useItemSelection>; trash?: boolean; tunnel?: boolean; trashAfterCopy?: boolean | null;
}) {
  const copyTrashes = tunnel && trashAfterCopy === true;
  const disabled = selection.busy || !selection.ids.size;
  return <div className="nb-selection-bar" role="toolbar" aria-label="Selected Item actions">
    <span role="status">{selection.ids.size} {selection.ids.size === 1 ? "Item" : "Items"} selected</span>
    <div className="nb-selection-actions">
      {trash ? <button className="nb-btn nb-btn-primary" disabled={disabled} onClick={() => selection.run("restore")}><Icon name="restore" />Restore</button> : <>
        <button className={`nb-btn ${tunnel ? "nb-btn-primary" : "nb-btn-secondary"}`} disabled={disabled} onClick={() => selection.run("copy", copyTrashes)}><Icon name="copy" />{copyTrashes ? "Copy & Trash" : "Copy"}</button>
        <button className="nb-btn nb-btn-secondary nb-selection-trash" disabled={disabled} onClick={() => selection.run("trash")}><Icon name="trash" />Trash</button>
      </>}
    </div>
  </div>;
}
