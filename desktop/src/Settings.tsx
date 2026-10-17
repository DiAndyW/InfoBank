import { useId, useRef, useState, type FormEvent } from "react";
import { saveSettings, type Settings as SettingsData } from "./api";
import { useShownAfterDelay } from "./delay";
import Dialog from "./Dialog";
import { Icon } from "./icons";
import { THEMES, type Theme } from "./theme";

type Props = {
  initial: SettingsData;
  theme: Theme;
  onThemeChange: (theme: Theme) => void;
  onSaved: () => void;
  // Given once the app is set up: Settings is then a panel over the window, not the first-launch page.
  onCancel?: () => void;
};

export default function Settings({ initial, theme, onThemeChange, onSaved, onCancel }: Props) {
  const [url, setUrl] = useState(initial.server_url ?? "");
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const busy = useRef(false);
  const showSaving = useShownAfterDelay(saving);
  const formId = useId();
  const secretId = useId();
  const incomplete = !onCancel && (url.trim() === "" || (secret === "" && !initial.has_secret));

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy.current) return;
    busy.current = true;
    setSaving(true);
    try {
      await saveSettings(url, secret === "" ? null : secret);
      setSecret("");
      onSaved();
    } catch (err) {
      setError(String(err));
    } finally {
      busy.current = false;
      setSaving(false);
    }
  }

  const form = (
    <form id={formId} className="nb-settings-fields" onSubmit={submit}>
      <label className="nb-field">
        <span className="nb-field-label">Server URL</span>
        <input className="nb-input" autoFocus value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://notes.example.com" />
      </label>
      <div className="nb-field">
        <span className="nb-field-label">
          <label htmlFor={secretId}>Secret</label>
          {initial.has_secret && secret === "" && url === initial.server_url && <span className="nb-field-note">saved</span>}
        </span>
        <input id={secretId} className="nb-input" type="password" value={secret} onChange={(e) => setSecret(e.target.value)} autoComplete="off" />
      </div>
      <label className="nb-field">
        <span className="nb-field-label">Theme</span>
        <span className="nb-select">
          <select className="nb-input" value={theme} onChange={(e) => onThemeChange(e.target.value as Theme)}>
            {Object.entries(THEMES).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
          <Icon name="chevron-down" />
        </span>
      </label>
      {error && (
        <div role="alert" className="nb-send-error">
          <Icon name="alert" />
          {error}
        </div>
      )}
    </form>
  );
  const actions = (
    <>
      {onCancel && (
        <button type="button" className="nb-btn nb-btn-secondary" disabled={saving} onClick={onCancel}>
          Cancel
        </button>
      )}
      <button type="submit" form={formId} className="nb-btn nb-btn-primary" disabled={saving || incomplete}>
        {showSaving ? "Saving…" : "Save"}
      </button>
    </>
  );

  if (onCancel) {
    return (
      <Dialog title="Settings" className="nb-settings" onClose={() => saving || onCancel()} actions={actions}>
        {form}
      </Dialog>
    );
  }
  return (
    <div className="nb-settings-page">
      <div className="nb-dialog nb-settings">
        <h1 className="nb-dialog-title">Settings</h1>
        {form}
        <div className="nb-dialog-actions">{actions}</div>
      </div>
    </div>
  );
}
