import { fireEvent, render, screen, cleanup } from "@testing-library/react";
import { afterEach, expect, vi } from "vitest";
import { mockIPC, clearMocks } from "@tauri-apps/api/mocks";
import Settings from "./Settings";
import { behaviourTest } from "./behaviour-test";

afterEach(() => { cleanup(); clearMocks(); });

behaviourTest("failure.server_url_components", async expected => {
  const onSaved = vi.fn();
  mockIPC((command) => {
    if (command === "save_settings") throw "The Server URL can't include a user name, query or fragment";
  });
  render(<Settings initial={{ server_url: null, has_secret: false, quick_capture: { on: true, shortcut: "shift+super+Space" } }}
    theme="paper" onThemeChange={() => {}} onSaved={onSaved} update={null} onCheckForUpdates={() => {}} onRestart={() => {}} />);
  for (const url of ["https://user:pw@example.com", "https://example.com/?key=secret", "https://example.com/#fragment"]) {
    fireEvent.change(screen.getByPlaceholderText("https://notes.example.com"), { target: { value: url } });
    fireEvent.change(screen.getByLabelText("Secret"), { target: { value: "secret" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(expected.message!);
    expect(onSaved).not.toHaveBeenCalled();
    expect(screen.getByLabelText("Secret")).toHaveValue("secret");
  }
});
