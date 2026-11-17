import { expect, test, vi } from "vitest";
import { failure } from "./failure";

test("failure hides technical errors and logs only the type", () => {
  const log = vi.spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(failure("Item failed to send.", new TypeError("secret URL"))).toBe("Item failed to send.");
    expect(log.mock.calls.flat().join(" ")).toBe("Failure type: TypeError");
    expect(failure("Item failed to send.", "Something went wrong. Try again.")).toBe("Item failed to send.");
    expect(failure("Item failed to send.", "")).toBe("Item failed to send.");
  } finally { log.mockRestore(); }
});
