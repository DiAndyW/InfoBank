import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { mockIPC } from "@tauri-apps/api/mocks";
import { expect, test } from "vitest";
import App from "./App";
import type { Settings, Topic } from "./api";

function backend(settings: Settings, topics: Topic[] = [], saveError?: string) {
  const calls: { cmd: string; args: unknown }[] = [];
  mockIPC((cmd, args) => {
    calls.push({ cmd, args });
    if (cmd === "get_settings") return settings;
    if (cmd === "list_topics") return topics;
    if (cmd === "save_settings") {
      if (saveError) throw saveError;
      return null;
    }
  });
  return calls;
}

const configured = { server_url: "https://notes.example.com", has_secret: true };

test("first launch opens Settings", async () => {
  backend({ server_url: null, has_secret: false });
  render(<App />);
  expect(await screen.findByRole("heading", { name: "Settings" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument();
});

test("a saved secret is never shown", async () => {
  backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  const secret = screen.getByLabelText("Secret");
  expect(secret).toHaveValue("");
  expect(screen.getByText("saved")).toBeInTheDocument();
});

test("editing the URL asks for the secret again", async () => {
  backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.type(screen.getByLabelText("Server URL"), "x");
  expect(screen.queryByText("saved")).not.toBeInTheDocument();
});

test("saving without retyping the secret keeps it", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.click(screen.getByRole("button", { name: "Save" }));
  expect(calls).toContainEqual({
    cmd: "save_settings",
    args: { serverUrl: "https://notes.example.com", secret: null },
  });
});

test("a save error is shown inline", async () => {
  backend({ server_url: null, has_secret: false }, [], "The Server URL must start with https://");
  render(<App />);
  await userEvent.type(await screen.findByLabelText("Server URL"), "http://notes.example.com");
  await userEvent.type(screen.getByLabelText("Secret"), "s3cret");
  await userEvent.click(screen.getByRole("button", { name: "Save" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("must start with https://");
  expect(screen.getByRole("heading", { name: "Settings" })).toBeInTheDocument();
});

test("a load failure is shown and can be retried", async () => {
  let failing = true;
  mockIPC((cmd) => {
    if (cmd === "get_settings") {
      if (failing) throw "Couldn't read the keychain: locked";
      return configured;
    }
    if (cmd === "list_topics") return [];
  });
  render(<App />);
  expect(await screen.findByRole("alert")).toHaveTextContent("Couldn't read the keychain");
  failing = false;
  await userEvent.click(screen.getByRole("button", { name: "Try again" }));
  expect(await screen.findByText("Nothing here yet.")).toBeInTheDocument();
});

test("the sidebar lists Topics", async () => {
  backend(configured, [
    { id: "1", name: "CS 111" },
    { id: "2", name: "Mosaic" },
  ]);
  render(<App />);
  expect(await screen.findByRole("button", { name: "CS 111" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Mosaic" })).toBeInTheDocument();
  expect(screen.getByText("Nothing here yet.")).toBeInTheDocument();
});
