import { useId, useState, type FormEvent } from "react";
import { saveSettings, type Settings as SettingsData } from "./api";
import { Icon } from "./icons";
import { THEMES, type Theme } from "./theme";

type Props = {
  initial: SettingsData;
  theme: Theme;
  onThemeChange: (theme: Theme) => void;
  onSaved: () => void;
  onCancel?: () => void;
};

export default function Settings({ initial, theme, onThemeChange, onSaved, onCancel }: Props) {
  const [url, setUrl] = useState(initial.server_url ?? "");
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const secretId = useId();

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
    <div className="nb-settings-page">
      <form className="nb-dialog nb-settings" onSubmit={submit}>
        <h1>Settings</h1>
        <div className="nb-settings-fields">
          <label className="nb-field">
            <span className="nb-field-label">Server URL</span>
            <input className="nb-input" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://notes.example.com" />
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
        </div>
        {error && (
          <div role="alert" className="nb-send-error">
            <Icon name="alert" />
            {error}
          </div>
        )}
        <div className="nb-dialog-actions">
          {onCancel && (
            <button type="button" className="nb-btn nb-btn-secondary" onClick={onCancel}>
              Cancel
            </button>
          )}
          <button type="submit" className="nb-btn nb-btn-primary">
            Save
          </button>
        </div>
      </form>
    </div>
  );
}
