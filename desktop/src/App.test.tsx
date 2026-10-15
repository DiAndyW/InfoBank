import { act, fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { emit } from "@tauri-apps/api/event";
import { mockIPC } from "@tauri-apps/api/mocks";
import { expect, test, vi } from "vitest";
import App from "./App";
import type { FeedItem, Settings, SyncStatus, Topic } from "./api";

type Options = {
  topics?: Topic[];
  saveError?: string;
  captureError?: string;
  items?: (args: any) => FeedItem[] | Promise<FeedItem[]>;
  status?: SyncStatus;
};

function backend(settings: Settings, opts: Options = {}) {
  const calls: { cmd: string; args: any }[] = [];
  mockIPC(
    (cmd, args) => {
      calls.push({ cmd, args });
      if (cmd === "get_settings") return settings;
      if (cmd === "list_topics") return opts.topics ?? [];
      if (cmd === "sync_status") return opts.status ?? "synced";
      if (cmd === "list_items") return opts.items ? opts.items(args) : [];
      if (cmd === "save_settings") {
        if (opts.saveError) throw opts.saveError;
        return null;
      }
      if (cmd === "capture") {
        if (opts.captureError) throw opts.captureError;
        return null;
      }
      if (cmd === "plugin:opener|open_url") return null;
    },
    { shouldMockEvents: true },
  );
  return calls;
}

const at = (y: number, mo: number, d: number, h: number, mi: number) => new Date(y, mo - 1, d, h, mi).getTime() * 1000;
const feedItem = (id: string, text: string, capture_time_us: number, pending = false): FeedItem => ({
  id,
  text,
  capture_time_us,
  topic_id: null,
  pending,
});

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
  backend({ server_url: null, has_secret: false }, { saveError: "The Server URL must start with https://" });
  render(<App />);
  await userEvent.type(await screen.findByLabelText("Server URL"), "http://notes.example.com");
  await userEvent.type(screen.getByLabelText("Secret"), "s3cret");
  await userEvent.click(screen.getByRole("button", { name: "Save" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("must start with https://");
  expect(screen.getByRole("heading", { name: "Settings" })).toBeInTheDocument();
});

test("a load failure is shown and can be retried", async () => {
  let failing = true;
  mockIPC(
    (cmd) => {
      if (cmd === "get_settings") {
        if (failing) throw "Couldn't read the keychain: locked";
        return configured;
      }
      if (cmd === "list_topics") return [];
      if (cmd === "sync_status") return "synced";
      if (cmd === "list_items") return [];
    },
    { shouldMockEvents: true },
  );
  render(<App />);
  expect(await screen.findByRole("alert")).toHaveTextContent("Couldn't read the keychain");
  failing = false;
  await userEvent.click(screen.getByRole("button", { name: "Try again" }));
  expect(await screen.findByText("Nothing here yet.")).toBeInTheDocument();
});

test("the sidebar lists Topics", async () => {
  backend(configured, {
    topics: [
      { id: "1", name: "CS 111" },
      { id: "2", name: "Mosaic" },
    ],
  });
  render(<App />);
  expect(await screen.findByRole("button", { name: "CS 111" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Mosaic" })).toBeInTheDocument();
  expect(screen.getByText("Nothing here yet.")).toBeInTheDocument();
});

test("Enter captures and Shift+Enter adds a line", async () => {
  const calls = backend(configured);
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  await userEvent.type(box, "a{Shift>}{Enter}{/Shift}b");
  expect(box).toHaveValue("a\nb");
  expect(calls.some((c) => c.cmd === "capture")).toBe(false);
  await userEvent.type(box, "{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "a\nb" } });
  expect(box).toHaveValue("");
});

test("Send is disabled for blank text", async () => {
  backend(configured);
  render(<App />);
  await userEvent.type(await screen.findByLabelText("New Item"), "   ");
  expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
});

test("a failed capture keeps the text", async () => {
  backend(configured, { captureError: "That's too long to save (1 MB max)" });
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  await userEvent.type(box, "keep me{Enter}");
  expect(await screen.findByRole("alert")).toHaveTextContent("too long");
  expect(box).toHaveValue("keep me");
});

test("Items show oldest at the top, with day dividers and a pending marker", async () => {
  backend(configured, {
    items: () => [
      feedItem("2", "today's thought", at(2026, 10, 15, 8, 2), true),
      feedItem("1", "yesterday's thought", at(2026, 10, 14, 9, 41)),
    ],
  });
  render(<App />);
  const articles = await screen.findAllByRole("article");
  expect(articles.map((a) => a.textContent)).toEqual([
    expect.stringContaining("yesterday's thought"),
    expect.stringContaining("today's thought"),
  ]);
  expect(screen.getAllByRole("separator")).toHaveLength(2);
  expect(within(articles[1]).getByLabelText("Not synced yet")).toBeInTheDocument();
  expect(within(articles[0]).queryByLabelText("Not synced yet")).not.toBeInTheDocument();
});

test("a link opens in the browser", async () => {
  const calls = backend(configured, {
    items: () => [feedItem("1", "read https://example.com/x.", at(2026, 10, 14, 9, 41))],
  });
  render(<App />);
  await userEvent.click(await screen.findByRole("link", { name: "https://example.com/x" }));
  expect(calls).toContainEqual({
    cmd: "plugin:opener|open_url",
    args: expect.objectContaining({ url: "https://example.com/x" }),
  });
});

test("the Feed refetches when items change", async () => {
  let items: FeedItem[] = [];
  backend(configured, { items: () => items });
  render(<App />);
  expect(await screen.findByText("Nothing here yet.")).toBeInTheDocument();
  items = [feedItem("1", "from my phone", at(2026, 10, 14, 9, 41))];
  await act(() => emit("items-changed"));
  expect(await screen.findByText("from my phone")).toBeInTheDocument();
});

test("scrolling to the top loads older Items", async () => {
  const calls = backend(configured, {
    items: (args) => (args.before ? [] : [feedItem("1", "newest page", at(2026, 10, 14, 9, 41))]),
  });
  render(<App />);
  await screen.findByText("newest page");
  fireEvent.scroll(screen.getByTestId("feed-items"));
  await vi.waitFor(() =>
    expect(calls).toContainEqual({
      cmd: "list_items",
      args: { view: { kind: "all" }, before: { capture_time_us: at(2026, 10, 14, 9, 41), id: "1" } },
    }),
  );
});

test("a rejected secret shows in the sidebar and opens Settings", async () => {
  backend(configured, { status: "unauthorized" });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "⚠ Secret rejected" }));
  expect(screen.getByRole("heading", { name: "Settings" })).toBeInTheDocument();
});

test("the status line follows sync-status events", async () => {
  backend(configured);
  render(<App />);
  expect(await screen.findByText("● Synced")).toBeInTheDocument();
  await act(() => emit("sync-status", "offline"));
  expect(await screen.findByText("○ Offline, retrying")).toBeInTheDocument();
});

test("a slow load for the previous view doesn't replace the current one", async () => {
  let release!: () => void;
  const slowAll = new Promise<void>((resolve) => (release = resolve));
  backend(configured, {
    items: async (args) => {
      if (args.view.kind === "inbox") return [feedItem("2", "inbox item", at(2026, 10, 14, 9, 41))];
      await slowAll;
      return [feedItem("1", "all items item", at(2026, 10, 14, 9, 40))];
    },
  });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Inbox" }));
  expect(await screen.findByText("inbox item")).toBeInTheDocument();
  await act(async () => release());
  expect(screen.queryByText("all items item")).not.toBeInTheDocument();
  expect(screen.getByText("inbox item")).toBeInTheDocument();
});

test("a Keychain problem shows in the sidebar", async () => {
  backend(configured, { status: "keychain" });
  render(<App />);
  expect(await screen.findByText("⚠ Keychain access needed")).toBeInTheDocument();
});

test("the theme is Warm paper until another is chosen", async () => {
  backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  expect(screen.getByLabelText("Theme")).toHaveValue("paper");
  expect(document.documentElement.dataset.theme).toBe("paper");
});

test("a theme chosen in Settings applies at once and is remembered", async () => {
  backend(configured);
  const { unmount } = render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.selectOptions(screen.getByLabelText("Theme"), "Notepad");
  expect(document.documentElement.dataset.theme).toBe("notepad");

  unmount();
  delete document.documentElement.dataset.theme;
  render(<App />);
  await screen.findByText("Nothing here yet.");
  expect(document.documentElement.dataset.theme).toBe("notepad");
});

test("dark is a theme of its own, not the system's setting", async () => {
  backend(configured);
  const { unmount } = render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.selectOptions(screen.getByLabelText("Theme"), "Warm paper, dark");
  expect(document.documentElement.dataset.theme).toBe("dark");

  unmount();
  render(<App />);
  await screen.findByText("Nothing here yet.");
  expect(document.documentElement.dataset.theme).toBe("dark");
});
