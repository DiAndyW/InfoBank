import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { clearMocks } from "@tauri-apps/api/mocks";
import { afterEach } from "vitest";

globalThis.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
} as unknown as typeof ResizeObserver;

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

if (!Element.prototype.animate) {
  Element.prototype.animate = (() => ({
    finished: Promise.resolve(),
    cancel() {},
    onfinish: null,
  })) as unknown as Element["animate"];
}

if (!window.matchMedia) {
  window.matchMedia = (() => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
  })) as unknown as Window["matchMedia"];
}
