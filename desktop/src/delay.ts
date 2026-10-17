import { useEffect, useState } from "react";

// Busy states show only once work has run this long, so instant local actions never flash them.
const SHOW_AFTER_MS = 500;

export function useShownAfterDelay(busy: boolean) {
  const [shown, setShown] = useState(false);
  useEffect(() => {
    if (!busy) {
      setShown(false);
      return;
    }
    const timer = setTimeout(() => setShown(true), SHOW_AFTER_MS);
    return () => clearTimeout(timer);
  }, [busy]);
  return shown;
}
