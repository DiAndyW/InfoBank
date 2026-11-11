import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { listen } from "@tauri-apps/api/event";
import { trashAfterCopy, setTrashAfterCopy, autostartOn, saveSettings, setAutostart, setQuickCaptureOn, setQuickCaptureShortcut, type UpdateInfo, type Hotkey, type Stranded, type Settings as SettingsData } from "./api";
import { useShownAfterDelay } from "./delay";
import Dialog from "./Dialog";
import Menu from "./Menu";
import { Icon } from "./icons";
import { THEMES, type Theme } from "./theme";

const MODIFIERS = [
  ["control", "⌃", "Ctrl"],
  ["alt", "⌥", "Alt"],
  ["shift", "⇧", "Shift"],
  ["super", "⌘", "Win"],
] as const;

function formatShortcut(stored: string) {
  const parts = stored.toLowerCase().split("+");
  const key = stored.slice(stored.lastIndexOf("+") + 1).replace(/^(Key|Digit)/, "");
  const mac = navigator.userAgent.includes("Mac");
  const mods = MODIFIERS.filter(([name]) => parts.includes(name)).map(([, symbol, text]) => (mac ? symbol : text));
  return mac ? mods.join("") + key : [...mods, key].join("+");
}

type Props = {
  initial: SettingsData;
  theme: Theme;
  onThemeChange: (theme: Theme) => void;
  onSaved: () => void;
  update: UpdateInfo | null;
  onCheckForUpdates: () => void;
  onRestart: () => void;
  // Given once the app is set up: Settings is then a panel over the window, not the first-launch page.
  onCancel?: () => void;
};

export default function Settings({ initial, theme, onThemeChange, onSaved, onCancel, update, onCheckForUpdates, onRestart }: Props) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(timer);
  }, []);
  const status = update?.status;
  let updateLine = "";
  if (status?.state === "checking") updateLine = "Checking…";
  else if (status?.state === "downloading") updateLine = `Downloading version ${status.version}…`;
  else if (status?.state === "ready") updateLine = `Version ${status.version} is ready`;
  else if (status?.state === "offline") updateLine = "No connection, try again later";
  else if (status?.state === "failed") updateLine = "Couldn't update, try again later";
  else if (status?.state === "up_to_date") {
    const minutes = Math.max(0, Math.floor((now - Date.parse(status.checked_at)) / 60_000));
    const relative = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
    const checked = minutes < 1 ? "just now" : minutes < 60 ? relative.format(-minutes, "minute")
      : minutes < 1440 ? relative.format(-Math.floor(minutes / 60), "hour") : relative.format(-Math.floor(minutes / 1440), "day");
    updateLine = `Up to date, ${checked}`;
  }
  const [themeOpen, setThemeOpen] = useState(false);
  const [url, setUrl] = useState(initial.server_url ?? "");
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [stranded, setStranded] = useState<(Stranded & { message: string }) | null>(null);
  const busy = useRef(false);
  const showSaving = useShownAfterDelay(saving);
  const formId = useId();
  const secretId = useId();
  const [hotkey, setHotkey] = useState(initial.quick_capture);
  const [recording, setRecording] = useState(false);
  const [shortcutError, setShortcutError] = useState<string | null>(null);
  const [openAtLogin, setOpenAtLogin] = useState<boolean | null>(null);
  const [trashCopied, setTrashCopied] = useState<boolean | null>(null);
  const [trashError, setTrashError] = useState<string | null>(null);
  const changingTrash = useRef(false);
  const [loginError, setLoginError] = useState<string | null>(null);

  useEffect(() => {
    if (onCancel) autostartOn().then(setOpenAtLogin, (err) => setLoginError(String(err)));
  }, []);

  useEffect(() => {
    if (!onCancel) return;
    let active = true;
    let latest = 0;
    const load = async () => {
      const request = ++latest;
      try {
        const value = await trashAfterCopy();
        if (active && request === latest && !changingTrash.current) {
          setTrashCopied(value ?? false);
          setTrashError(null);
        }
      } catch (err) {
        if (active && request === latest) setTrashError(String(err));
      }
    };
    load();
    const stop = listen("items-changed", load);
    return () => { active = false; stop.then((s) => s()); };
  }, []);

  async function changeTrashAfterCopy(on: boolean) {
    changingTrash.current = true;
    try {
      await setTrashAfterCopy(on);
      setTrashCopied(on);
      setTrashError(null);
    } catch (err) {
      setTrashError(String(err));
    } finally {
      changingTrash.current = false;
    }
  }

  async function changeOpenAtLogin(on: boolean) {
    try {
      setOpenAtLogin(await setAutostart(on));
      setLoginError(null);
    } catch (err) {
      setLoginError(String(err));
      autostartOn().then(setOpenAtLogin, () => {});
    }
  }
  const incomplete = !onCancel && (url.trim() === "" || (secret === "" && !initial.has_secret));

  async function submit(confirmed?: Stranded) {
    if (busy.current) return;
    busy.current = true;
    setSaving(true);
    setError(null);
    try {
      await saveSettings(url, secret === "" ? null : secret, confirmed);
      setSecret("");
      onSaved();
    } catch (err) {
      if (typeof err === "object" && err !== null && "changes" in err) setStranded(err as Stranded & { message: string });
      else setError(String(err));
    } finally {
      busy.current = false;
      setSaving(false);
    }
  }

  async function applyHotkey(change: Promise<Hotkey>) {
    try {
      setHotkey(await change);
      setShortcutError(null);
    } catch (err) {
      setShortcutError(String(err));
    }
  }

  function onRecordKey(e: KeyboardEvent<HTMLButtonElement>) {
    if (!recording || e.nativeEvent.isComposing || e.keyCode === 229) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.key === "Escape") return setRecording(false);
    if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
    const mods = [e.ctrlKey && "Control", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "Super"].filter(Boolean);
    if (mods.length === 0) return;
    setRecording(false);
    applyHotkey(setQuickCaptureShortcut([...mods, e.code].join("+")));
  }

  const shown = recording ? "Press a shortcut… (Esc cancels)" : formatShortcut(hotkey.shortcut);

  const form = (
    <form id={formId} className="nb-settings-fields" onSubmit={(e) => { e.preventDefault(); submit(); }}>
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
      <div className="nb-field">
        <span className="nb-field-label">Theme</span>
        <Menu label="Theme" trigger={THEMES[theme]} open={themeOpen} onOpenChange={setThemeOpen}
          entries={Object.entries(THEMES).map(([value, label]) => ({ label, checked: value === theme, onSelect: () => onThemeChange(value as Theme) }))} />
      </div>
      <div className="nb-field">
        <span className="nb-field-label">Quick capture</span>
        <span className="nb-shortcut-row">
          <button
            type="button"
            className={hotkey.on ? "nb-input nb-shortcut" : "nb-input nb-shortcut is-off"}
            aria-label={`Quick capture shortcut: ${shown}`}
            aria-pressed={recording}
            onClick={(e) => {
              e.currentTarget.focus();
              setRecording(true);
            }}
            onBlur={() => setRecording(false)}
            onKeyDown={onRecordKey}
          >
            {shown}
          </button>
          <label className="nb-switch">
            <input
              type="checkbox"
              role="switch"
              aria-label="Quick capture on"
              checked={hotkey.on}
              onChange={(e) => applyHotkey(setQuickCaptureOn(e.target.checked))}
            />
            {hotkey.on ? "On" : "Off"}
          </label>
        </span>
        {shortcutError && (
          <span role="alert" className="nb-field-error">
            {shortcutError}
          </span>
        )}
      </div>
      {onCancel && (
        <div className="nb-field">
          <label className="nb-switch">
            <input
              type="checkbox"
              role="switch"
              checked={trashCopied ?? false}
              disabled={trashCopied === null}
              onChange={(e) => changeTrashAfterCopy(e.target.checked)}
            />
            Trash Tunnel notes after copying
          </label>
          {trashError && <span role="alert" className="nb-field-error">{trashError}</span>}
        </div>
      )}
      {onCancel && (
        <div className="nb-field">
          <span className="nb-field-label">Open at login</span>
          <label className="nb-switch">
            <input
              type="checkbox"
              role="switch"
              aria-label="Open at login"
              checked={openAtLogin ?? false}
              disabled={openAtLogin === null}
              onChange={(e) => changeOpenAtLogin(e.target.checked)}
            />
            {openAtLogin ? "On" : "Off"}
          </label>
          {loginError && (
            <span role="alert" className="nb-field-error">
              {loginError}
            </span>
          )}
        </div>
      )}
      {update && (
        <div className="nb-field">
          <span className="nb-field-label">Version</span>
          <div className="nb-update-row">
            <span>{update.current_version}</span>
            {updateLine && <span className="nb-update-status" role="status">{updateLine}</span>}
            {status?.state !== "off" && (
              status?.state === "ready" ? (
                <button type="button" className="nb-btn nb-btn-primary" onClick={onRestart}>Restart to update</button>
              ) : (
                <button type="button" className="nb-btn nb-btn-secondary" disabled={status?.state === "checking" || status?.state === "downloading"} onClick={onCheckForUpdates}>Check for updates</button>
              )
            )}
          </div>
        </div>
      )}
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

  const discard = stranded && (
    <Dialog
      alert
      title="Discard unsent work?"
      onClose={() => setStranded(null)}
      actions={
        <>
          <button type="button" className="nb-btn nb-btn-secondary" onClick={() => setStranded(null)}>
            Cancel
          </button>
          <button
            type="button"
            className="nb-btn nb-btn-danger"
            onClick={() => {
              setStranded(null);
              submit({ changes: stranded.changes, files: stranded.files });
            }}
          >
            Switch anyway
          </button>
        </>
      }
    >
      <p>{stranded.message}</p>
      <p className="nb-dialog-hint">To keep it, reconnect to the current Server and let it sync first.</p>
    </Dialog>
  );

  if (onCancel) {
    return (
      <>
        <Dialog title="Settings" className="nb-settings" onClose={() => saving || onCancel()} actions={actions}>
          {form}
        </Dialog>
        {discard}
      </>
    );
  }
  return (
    <div className="nb-settings-page">
      <div className="nb-dialog nb-settings">
        <h1 className="nb-dialog-title">Settings</h1>
        {form}
        <div className="nb-dialog-actions">{actions}</div>
      </div>
      {discard}
    </div>
  );
}
