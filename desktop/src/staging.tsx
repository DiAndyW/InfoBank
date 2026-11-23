import { useEffect, useRef, useState, type Dispatch, type SetStateAction, type ClipboardEvent, type RefObject } from "react";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { MAX_ATTACHMENT_BYTES, pickFiles, stageBytes, unstage, stagedThumbnail, thumbnail, openAttachment, openStagedAttachment, type Staged, type StagedFiles } from "./api";
import { appDataDir, join } from "@tauri-apps/api/path";
import { convertFileSrc } from "@tauri-apps/api/core";
import ImageViewer, { type ViewerImage } from "./ImageViewer";
import { formatSize } from "./attachments";
import { failure } from "./failure";
import { Icon } from "./icons";

type DropTarget = { accepts: boolean; frozen?: RefObject<boolean>; start: () => (() => void) & { add: (result: StagedFiles) => Promise<void> }; setDragging: (value: boolean) => void };
const dropTargets = new Set<RefObject<DropTarget>>();
const drops = new Map<string, { target: RefObject<DropTarget> | undefined; add: ((result: StagedFiles) => Promise<void>) | null; finish: () => void }>();
let dropListeners: Promise<() => void>[] = [];

export function useStaging({ acceptsDrops, state, frozen, scope = "" }: {
  acceptsDrops: boolean;
  scope?: string;
  state?: { staged: Staged[]; setStaged: Dispatch<SetStateAction<Staged[]>>; update?: (next: (files: Staged[]) => Staged[]) => Promise<void> };
  frozen?: RefObject<boolean>;
}) {
  const [localStaged, setLocalStaged] = useState<Staged[]>([]);
  const { staged, setStaged } = state ?? { staged: localStaged, setStaged: setLocalStaged };
  const latest = useRef(staged);
  latest.current = staged;
  const [scopedErrors, setErrors] = useState<{ scope: string; message: string }[]>([]);
  const errors = scopedErrors.filter(e => e.scope === scope).map(e => e.message);
  // Bumped by discard, so a paste still staging then is unstaged instead of reappearing.
  const generation = useRef(0);

  const pending = useRef(new Set<Promise<void>>());
  const [isImporting, setImporting] = useState(false);
  const importTails = useRef(new Map<string, Promise<void>>());
  const operations = useRef(new Map<Promise<void>, { scope: string; retired: boolean }>());
  const [, redraw] = useState(0);
  const pendingImportCount = [...operations.current.values()].filter(op => op.scope === scope && !op.retired).length;
  function retire() {
    for (const op of operations.current.values()) if (op.scope === scope) op.retired = true;
    importTails.current.delete(scope);
    setErrors(all => all.filter(e => e.scope !== scope));
    redraw(n => n + 1);
  }
  function start() {
    const previous = importTails.current.get(scope) ?? Promise.resolve();
    let release!: () => void;
    importTails.current.set(scope, new Promise<void>(resolve => { release = resolve; }).then(() => previous));
    const at = generation.current;
    setErrors(all => all.filter(e => e.scope !== scope));
    let finish!: () => void;
    const task = new Promise<void>(resolve => { finish = resolve; });
    const operation = { scope, retired: false };
    operations.current.set(task, operation);
    pending.current.add(task);
    setImporting(true);
    const done = () => { operations.current.delete(task); redraw(n => n + 1); pending.current.delete(task); setImporting(pending.current.size > 0); finish(); release(); };
    done.valid = () => at === generation.current && !operation.retired;
    done.add = async (result: StagedFiles) => {
      await previous;
      if (done.valid()) await addAll(result, done.valid);
      else for (const file of result.staged) unstage(file.id).catch(() => {});
    };
    return done;
  }
  async function wait() {
    while (pending.current.size > 0) await Promise.all([...pending.current]);
  }

  function failed(more: string[]) {
    if (more.length > 0) setErrors((all) => [...all, ...more.map(message => ({ scope, message }))]);
  }

  async function change(next: (files: Staged[]) => Staged[]) {
    if (state?.update) await state.update(next);
    else setStaged(next);
  }
  async function addAll(result: StagedFiles, valid: () => boolean) {
    try { await change(all => [...all, ...result.staged]); }
    catch (err) { if (valid()) failed([failure("Draft failed to save.", err)]); }
    if (valid()) failed(result.errors);
  }

  const [dragging, setDragging] = useState(false);
  const [viewing, setViewing] = useState(false);
  const target = useRef<DropTarget>({ accepts: false, start, setDragging });
  target.current = { accepts: acceptsDrops && !viewing, frozen, start, setDragging };
  useEffect(() => {
    dropTargets.add(target);
    if (dropTargets.size === 1) {
      // One receiver owns each drop; inactive boxes must not unstage its files.
      const receiver = () => [...dropTargets].find(t => t.current.accepts && !t.current.frozen?.current);
      dropListeners = [
        getCurrentWebviewWindow().listen<string>("attachments-staging", e => {
          const to = receiver();
          const operation = to?.current.start();
          drops.set(e.payload, { target: to, add: operation?.add ?? null, finish: operation ?? (() => {}) });
        }),
        getCurrentWebviewWindow().listen<StagedFiles & { drop_id?: string }>("attachments-staged", e => {
          const drop = e.payload.drop_id === undefined ? undefined : drops.get(e.payload.drop_id);
          const to = e.payload.drop_id === undefined ? receiver() : undefined;
          const operation = to?.current.start();
          const add = e.payload.drop_id === undefined ? operation?.add : drop?.add;
          if (e.payload.drop_id !== undefined) drops.delete(e.payload.drop_id);
          const finish = operation;
          if (add) void add(e.payload).finally(() => { finish?.(); drop?.finish(); });
          else { for (const s of e.payload.staged) unstage(s.id).catch(() => {}); finish?.(); drop?.finish(); }
        }),
        getCurrentWebview().onDragDropEvent(e => {
          const to = receiver();
          for (const t of dropTargets) t.current.setDragging(t === to && (e.payload.type === "enter" || e.payload.type === "over"));
        }),
      ];
    }
    return () => {
      generation.current++;
      dropTargets.delete(target);
      for (const drop of drops.values()) {
        if (drop.target === target) { drop.add = null; drop.finish(); }
      }
      if (dropTargets.size === 0) {
        for (const stop of dropListeners) stop.then(unlisten => unlisten());
        dropListeners = [];
        drops.clear();
      }
    };
  }, []);

  async function onPaste(e: ClipboardEvent<HTMLTextAreaElement>) {
    const pasted = Array.from(e.clipboardData.files);
    if (pasted.length === 0) return;
    if (!e.clipboardData.getData("text/plain")) e.preventDefault();
    const finish = start();
    try {
      const results = await Promise.all(pasted.map(async file => {
        const name = file.name || "Pasted image.png";
        if (file.size > MAX_ATTACHMENT_BYTES) { if (finish.valid()) failed([`${name} is over 100 MB`]); return null; }
        try {
          const s = await stageBytes(name, new Uint8Array(await file.arrayBuffer().catch((error: unknown) => {
            console.error("Pasted file read failed", error instanceof DOMException ? error.name : "unknown");
            throw "Something went wrong. Try again.";
          })));
          if (!finish.valid()) {
            unstage(s.id).catch(() => {});
            return null;
          }
          return s;
        } catch (err) {
          if (finish.valid()) failed([typeof err === "string" && err !== "Something went wrong. Try again." && err.includes(name) ? err : failure(`${name} failed to attach.`, err)]);
          return null;
        }
      }));
      await finish.add({ staged: results.filter((file): file is Staged => file !== null && typeof file !== "string"), errors: [] });
    } finally {
      finish();
    }
  }

  async function remove(id: string) {
    try { await change(all => all.filter(s => s.id !== id)); await unstage(id); }
    catch (err) { failed([failure("File failed to remove.", err)]); }
  }

  async function pick() {
    const finish = start();
    try {
      const result = await pickFiles();
      if (finish.valid()) await finish.add(result);
      else for (const s of result.staged) unstage(s.id).catch(() => {});
    }
    catch (err) { if (finish.valid()) failed([failure("File failed to attach.", err)]); }
    finally { finish(); }
  }

  // Reads the latest list: a caller may still hold one from before a paste landed.
  function discard(keep: string[] = []) {
    generation.current++;
    for (const op of operations.current.values()) op.retired = true;
    importTails.current.clear();
    setErrors([]);
    for (const s of latest.current) if (!keep.includes(s.id)) unstage(s.id).catch(() => {});
    setStaged([]);
  }

  const dropTarget = dragging && acceptsDrops && !viewing && (
    <div className="nb-drop">
      <div className="nb-drop-target">
        <Icon name="paperclip" size={24} />
        <span>Drop to attach</span>
      </div>
    </div>
  );
  return { dropTarget, setDragging, setViewing, wait, isImporting, pendingImportCount, retire, staged, onPaste, remove, pick, discard, errors, clearErrors: () => setErrors(all => all.filter(e => e.scope !== scope)) };
}

const browserImages = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/avif", "image/svg+xml"];

type Chip = { id: string; filename: string; mime_type: string; size_bytes: number; has_thumbnail?: boolean };

async function stagedSource(file: Pick<Chip, "id" | "filename">) {
  return convertFileSrc(await join(await appDataDir(), "files", file.id, file.filename));
}

function PreviewTile({ file, kept, onOpen, onRemove }: { file: Chip; kept: boolean; onOpen: () => void; onRemove: () => void }) {
  const image = file.mime_type.startsWith("image/");
  const generated = !kept && (file.mime_type.startsWith("video/") || (image && !browserImages.includes(file.mime_type)));
  const [src, setSrc] = useState<string | null>(null);
  const [loading, setLoading] = useState(generated || image || (kept && !!file.has_thumbnail));
  useEffect(() => {
    let live = true;
    setSrc(null);
    setLoading(generated || image || (kept && !!file.has_thumbnail));
    if (generated || image || (kept && file.has_thumbnail)) {
      const source = kept ? thumbnail(file.id).then(convertFileSrc) : generated ? stagedThumbnail(file.id).then(convertFileSrc) : stagedSource(file);
      source.then(value => { if (live) setSrc(value); }, () => { if (live) setLoading(false); });
    }
    return () => { live = false; };
  }, [file.id, file.filename, file.has_thumbnail, kept, image, generated]);
  const content = <>{!loading && <Icon name={image ? "image" : "play"} />}{src && <img src={src} alt="" style={{ visibility: loading ? "hidden" : "visible" }} onLoad={event => {
      const image = event.currentTarget;
      if (image.decode) void image.decode().then(() => setLoading(false), () => { setSrc(null); setLoading(false); });
      else setLoading(false);
    }} onError={() => { setSrc(null); setLoading(false); }} />}{loading && <span role="progressbar" aria-label="Loading preview" className="nb-import-spinner" />}{!image && <span className="nb-thumb-play"><Icon name="play" /></span>}</>;
  return <li className="nb-preview-tile">
    <button type="button" className="nb-tile-open" data-attachment-id={file.id} aria-label={image ? file.filename : `Play ${file.filename}`} onClick={onOpen}>{content}</button>
    <button type="button" className="nb-iconbtn nb-tile-remove" aria-label={`Remove ${file.filename}`} onClick={onRemove}><Icon name="x" /></button>
  </li>;
}

export function Chips({ label, list, onRemove, pendingImportCount = 0, keptIds = [], onViewing }: { onViewing?: (value: boolean) => void; pendingImportCount?: number; label: string; list: Chip[]; onRemove: (id: string) => void; keptIds?: string[] }) {
  const [openError, setOpenError] = useState<string | null>(null);
  const opening = useRef(false);
  async function open(file: Chip) {
    if (file.mime_type.startsWith("image/")) { setSelected(file.id); return; }
    if (opening.current) return;
    opening.current = true;
    setOpenError(null);
    try { await (keptIds.includes(file.id) ? openAttachment : openStagedAttachment)(file.id); }
    catch (err) { setOpenError(failure(`${file.filename} failed to open.`, err)); }
    finally { opening.current = false; }
  }
  const [selected, setSelected] = useState<string | null>(null);
  const viewing = selected !== null;
  useEffect(() => {
    onViewing?.(viewing);
    return () => onViewing?.(false);
  }, [viewing, onViewing]);
  const images: ViewerImage[] = list.filter(s => s.mime_type.startsWith("image/")).map(s => ({
    id: s.id, filename: s.filename, ...(!keptIds.includes(s.id) && { localSource: () => stagedSource(s) }),
  }));
  return <>
    {(list.length > 0 || pendingImportCount > 0) && <ul className="nb-staged" aria-label={label}>
      {list.map(s => s.mime_type.startsWith("image/") || s.mime_type.startsWith("video/") ?
        <PreviewTile key={s.id} file={s} kept={keptIds.includes(s.id)} onOpen={() => { void open(s); }} onRemove={() => onRemove(s.id)} /> :
        <li key={s.id} className="nb-file is-staged">
          <Icon name="file" />
          <span className="nb-file-text"><span className="nb-file-name">{s.filename}</span><span className="nb-file-meta">{formatSize(s.size_bytes)}</span></span>
          <button type="button" className="nb-iconbtn" aria-label={`Remove ${s.filename}`} title={`Remove ${s.filename}`} onClick={() => onRemove(s.id)}><Icon name="x" /></button>
        </li>)}
      {pendingImportCount > 0 && <li className="nb-import-pending" role="status" aria-label={pendingImportCount === 1 ? "1 import pending" : `${pendingImportCount} imports pending`}><span className="nb-import-spinner" />{pendingImportCount === 1 ? "1 import pending" : `${pendingImportCount} imports pending`}</li>}
    </ul>}
    {openError && <div className="nb-send-error" role="alert"><Icon name="alert" />{openError}</div>}
    {selected && images.some(s => s.id === selected) && <ImageViewer images={images} selected={selected} onSelect={setSelected} onClose={() => setSelected(null)} />}
  </>;
}
