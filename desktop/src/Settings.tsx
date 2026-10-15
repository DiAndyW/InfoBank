import { useState, type FormEvent } from "react";
import { saveSettings, type Settings as SettingsData } from "./api";

type Props = {
  initial: SettingsData;
  onSaved: () => void;
  onCancel?: () => void;
};

export default function Settings({ initial, onSaved, onCancel }: Props) {
  const [url, setUrl] = useState(initial.server_url ?? "");
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    try {
      await saveSettings(url, secret === "" ? null : secret);
      setSecret("");
      onSaved();
    } catch (err) {
      setError(String(err));
    }
  }

  return (
    <form className="settings" onSubmit={submit}>
      <h1>Settings</h1>
      <label>
        Server URL
        <input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://notes.example.com" />
      </label>
      <label>
        Secret
        <input type="password" value={secret} onChange={(e) => setSecret(e.target.value)} autoComplete="off" />
      </label>
      {initial.has_secret && secret === "" && <span className="hint">saved</span>}
      {error && <p role="alert">{error}</p>}
      <div className="actions">
        {onCancel && (
          <button type="button" onClick={onCancel}>
            Cancel
          </button>
        )}
        <button type="submit">Save</button>
      </div>
    </form>
  );
}
