import { useRef, useState, type ClipboardEvent } from "react";
import { MAX_ATTACHMENT_BYTES, pickFiles, stageBytes, unstage, type Staged, type StagedFiles } from "./api";
import { formatSize } from "./attachments";
import Dialog from "./Dialog";
import { Icon } from "./icons";

export function useStaging() {
  const [staged, setStaged] = useState<Staged[]>([]);
  const latest = useRef(staged);
  latest.current = staged;
  const [errors, setErrors] = useState<string[]>([]);
  // Bumped by discard, so a paste still staging then is unstaged instead of reappearing.
  const generation = useRef(0);

  function failed(more: string[]) {
    if (more.length > 0) setErrors((all) => [...all, ...more]);
  }

  async function add(stage: () => Promise<Staged>) {
    const at = generation.current;
    try {
      const s = await stage();
      if (at !== generation.current) return void unstage(s.id).catch(() => {});
      setStaged((all) => [...all, s]);
    } catch (err) {
      failed([String(err)]);
    }
  }

  function addAll(result: StagedFiles) {
    setStaged((all) => [...all, ...result.staged]);
    failed(result.errors);
  }

  function onPaste(e: ClipboardEvent<HTMLTextAreaElement>) {
    const pasted = Array.from(e.clipboardData.files);
    if (pasted.length === 0) return;
    e.preventDefault();
    for (const file of pasted) {
      const name = file.name || "Pasted image.png";
      if (file.size > MAX_ATTACHMENT_BYTES) {
        failed([`${name} is over 100 MB`]);
        continue;
      }
      add(async () => stageBytes(name, new Uint8Array(await file.arrayBuffer())));
    }
  }

  function remove(id: string) {
    setStaged((all) => all.filter((s) => s.id !== id));
    unstage(id).catch(() => {});
  }

  const pick = () => pickFiles().then(addAll, (err) => failed([String(err)]));

  const dialog = errors.length > 0 && (
    <Dialog
      alert
      title={errors.length === 1 ? "Couldn't attach a file" : `Couldn't attach ${errors.length} files`}
      onClose={() => setErrors([])}
      actions={
        <button type="button" className="nb-btn nb-btn-primary" autoFocus onClick={() => setErrors([])}>
          OK
        </button>
      }
    >
      <ul>
        {errors.map((e, i) => (
          <li key={i}>{e}</li>
        ))}
      </ul>
    </Dialog>
  );

  // Reads the latest list: a caller may still hold one from before a paste landed.
  function discard(keep: string[] = []) {
    generation.current++;
    for (const s of latest.current) if (!keep.includes(s.id)) unstage(s.id).catch(() => {});
    setStaged([]);
  }

  return { staged, setStaged, addAll, onPaste, remove, pick, discard, dialog };
}

type Chip = { id: string; filename: string; mime_type: string; size_bytes: number };

export function Chips({ label, list, onRemove }: { label: string; list: Chip[]; onRemove: (id: string) => void }) {
  return (
    <ul className="nb-staged" aria-label={label}>
      {list.map((s) => (
        <li key={s.id} className="nb-file is-staged">
          <Icon name={s.mime_type.startsWith("image/") ? "image" : "file"} />
          <span className="nb-file-text">
            <span className="nb-file-name">{s.filename}</span>
            <span className="nb-file-meta">{formatSize(s.size_bytes)}</span>
          </span>
          <button type="button" className="nb-iconbtn" aria-label={`Remove ${s.filename}`} title={`Remove ${s.filename}`} onClick={() => onRemove(s.id)}>
            <Icon name="x" />
          </button>
        </li>
      ))}
    </ul>
  );
}
