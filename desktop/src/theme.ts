export type Theme = "paper" | "notepad";

const KEY = "theme";

// Storage can be unavailable or cleared; the theme is only a display preference, so fall back quietly.
export function storedTheme(): Theme {
  try {
    return localStorage.getItem(KEY) === "notepad" ? "notepad" : "paper";
  } catch {
    return "paper";
  }
}

export function applyTheme(theme: Theme) {
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem(KEY, theme);
  } catch {}
}
