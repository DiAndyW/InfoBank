import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { clearMocks } from "@tauri-apps/api/mocks";
import { afterEach } from "vitest";

Object.defineProperties(HTMLElement.prototype, {
  setPointerCapture: { configurable: true, value: () => {} },
  releasePointerCapture: { configurable: true, value: () => {} },
});

afterEach(async () => {
  cleanup();
  // Unmounting stops event listeners asynchronously, and they need the mocks.
  await new Promise((resolve) => setTimeout(resolve));
  clearMocks();
  localStorage.clear();
  delete document.documentElement.dataset.theme;
});
