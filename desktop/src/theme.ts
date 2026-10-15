export const THEMES = { paper: "Warm paper", dark: "Warm paper, dark", notepad: "Notepad" } as const;
export type Theme = keyof typeof THEMES;

const KEY = "theme";

// Storage can be unavailable or cleared; the theme is only a display preference, so fall back quietly.
export function storedTheme(): Theme {
  try {
    const stored = localStorage.getItem(KEY);
    return Object.keys(THEMES).find((t): t is Theme => t === stored) ?? "paper";
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
