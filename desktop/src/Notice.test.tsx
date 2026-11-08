import { act, fireEvent, render } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import Notice from "./Notice";

for (const [label, duration] of [[undefined, 4000], ["Show", 4000], ["Undo", 4000]] as const) {
  test(`${label ?? "informational"} notice expires after ${duration}ms of active display`, async () => {
    vi.useFakeTimers();
    const focus = vi.spyOn(document, "hasFocus").mockReturnValue(true);
    const close = vi.fn();
    try {
      render(<Notice message="Saved" action={label ? { label, onAction: () => {} } : undefined} onClose={close} />);
      await act(async () => vi.advanceTimersByTime(duration - 1));
      expect(close).not.toHaveBeenCalled();
      await act(async () => vi.advanceTimersByTime(1));
      expect(close).toHaveBeenCalledOnce();
    } finally { focus.mockRestore(); vi.useRealTimers(); }
  });
}

test("Undo stays available while hovered and restarts its window on release", async () => {
  vi.useFakeTimers();
  const focus = vi.spyOn(document, "hasFocus").mockReturnValue(true);
  const close = vi.fn();
  try {
    const { getByRole } = render(<Notice message="Trashed" action={{ label: "Undo", onAction: () => {} }} onClose={close} />);
    fireEvent.mouseEnter(getByRole("status"));
    await act(async () => vi.advanceTimersByTime(10000));
    expect(close).not.toHaveBeenCalled();
    fireEvent.mouseLeave(getByRole("status"));
    await act(async () => vi.advanceTimersByTime(3999));
    expect(close).not.toHaveBeenCalled();
    await act(async () => vi.advanceTimersByTime(1));
    expect(close).toHaveBeenCalledOnce();
  } finally { focus.mockRestore(); vi.useRealTimers(); }
});
