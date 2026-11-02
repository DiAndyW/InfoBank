import { useRef, useState } from "react";
import { pickerTopic, type Topic } from "./api";
import Dialog from "./Dialog";

export default function NewTopicDialog({ onClose, onCreated }: { onClose: () => void; onCreated: (topic: Topic) => void }) {
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const busy = useRef(false);

  async function create() {
    if (busy.current) return;
    busy.current = true;
    try {
      onCreated(await pickerTopic(draft));
    } catch (err) {
      setError(String(err));
    } finally {
      busy.current = false;
    }
  }

  return (
    <Dialog title="New Topic" onClose={onClose}
      actions={<>
        <button type="button" className="nb-btn nb-btn-secondary" onClick={onClose}>Cancel</button>
        <button type="button" className="nb-btn nb-btn-primary" onClick={create}>Create</button>
      </>}>
      <div className={error ? "nb-field has-error" : "nb-field"}>
        <input
          className="nb-input"
          aria-invalid={error ? true : undefined}
          aria-label="Topic name"
          placeholder="Topic name"
          autoFocus
          value={draft}
          onChange={(e) => {
            setDraft(e.target.value);
            setError(null);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing && e.keyCode !== 229) {
              e.preventDefault();
              create();
            }
          }}
        />
        {error && (
          <div className="nb-field-error" role="alert">
            {error}
          </div>
        )}
      </div>
    </Dialog>
  );
}
