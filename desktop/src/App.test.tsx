import { act, createEvent, fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { emit } from "@tauri-apps/api/event";
import { mockConvertFileSrc, mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { expect, test, vi } from "vitest";
import App from "./App";
import { MAX_ATTACHMENT_BYTES, type Counts, type FeedAttachment, type FeedItem, type SearchItem, type Settings, type Staged, type StagedFiles, type SyncStatus, type Topic } from "./api";

type Options = {
  topics?: Topic[];
  trashAfterCopy?: boolean | null;
  doubleClickIntervalMs?: number;
  pulledTrashAfterCopy?: () => boolean | null;
  // A function runs per save_settings call (0-based): it may throw or wait.
  saveError?: unknown;
  captureError?: string;
  items?: (args: any) => FeedItem[] | Promise<FeedItem[]>;
  status?: SyncStatus;
  picked?: StagedFiles;
  staged?: Staged[];
  thumbnail?: string;
  openError?: string;
  openHang?: boolean;
  failing?: Record<string, string>;
  counts?: () => Counts;
  edited?: { trashed: boolean };
  search?: (args: any) => SearchItem[] | Promise<SearchItem[]>;
  // A command waits for its gate, so a test can act while the call is in flight.
  gates?: Record<string, Promise<void>>;
  shortcutError?: string;
  autostart?: boolean;
  startup?: { message: string; data_dir: string | null };
};

function backend(given: Omit<Settings, "quick_capture"> & Partial<Settings>, opts: Options = {}) {
  localStorage.setItem("place", "all");
  const settings: Settings = { quick_capture: { shortcut: "shift+super+Space", on: true }, ...given };
  let hotkey = settings.quick_capture;
  let autostart = opts.autostart ?? false;
  let trashAfterCopy = opts.trashAfterCopy ?? null;
  const calls: { cmd: string; args: any }[] = [];
  mockWindows("main");
  mockConvertFileSrc("macos");
  mockIPC(
    async (cmd, args) => {
      calls.push({ cmd, args });
      await opts.gates?.[cmd];
      if (opts.failing?.[cmd]) throw opts.failing[cmd];
      if (cmd === "copy_item") return null;
      if (cmd === "startup_error") return opts.startup ?? null;
      if (["show_data_folder", "quit"].includes(cmd)) return null;
      if (cmd === "get_settings") return settings;
      if (cmd === "double_click_interval_ms") return opts.doubleClickIntervalMs ?? 500;
      if (cmd === "trash_after_copy") return opts.pulledTrashAfterCopy ? opts.pulledTrashAfterCopy() : trashAfterCopy;
      if (cmd === "set_trash_after_copy") { trashAfterCopy = (args as { on: boolean }).on; return null; }
      if (cmd === "list_topics") return opts.topics ?? [];
      if (cmd === "sync_status") return opts.status ?? "synced";
      if (cmd === "list_items") return opts.items ? opts.items(args) : [];
      if (cmd === "search_items") return opts.search ? opts.search(args) : [];
      if (cmd === "nav_counts") return opts.counts?.() ?? { inbox: 0, tunnel: 0, trash: 0 };
      if (cmd === "edit_item") return opts.edited ?? { trashed: false };
      if (["trash_item", "restore_item", "discard_item"].includes(cmd)) return null;
      if (cmd === "resolve_conflict") return { trashed: false };
      if (cmd === "save_settings") {
        const call = calls.filter((c) => c.cmd === "save_settings").length - 1;
        if (typeof opts.saveError === "function") await opts.saveError(call);
        else if (opts.saveError) throw opts.saveError;
        return null;
      }
      if (cmd === "capture") {
        if (opts.captureError) throw opts.captureError;
        return null;
      }
      if (cmd === "autostart_on") return autostart;
      if (cmd === "set_autostart") {
        autostart = (args as { on: boolean }).on;
        return autostart;
      }
      if (cmd === "set_quick_capture_shortcut" || cmd === "set_quick_capture_on") {
        if (opts.shortcutError) throw opts.shortcutError;
        const { on } = args as { on?: boolean };
        hotkey = cmd === "set_quick_capture_on" ? { ...hotkey, on: on! } : { ...hotkey, shortcut: "control+alt+KeyK" };
        return hotkey;
      }
      if (cmd === "pick_files") return opts.picked ?? { staged: [], errors: [] };
      if (cmd === "stage_attachment_bytes") {
        const s = opts.staged?.shift();
        if (!s) throw "nothing to stage";
        return s;
      }
      if (cmd === "unstage_attachment") return null;
      if (cmd === "thumbnail") {
        if (!opts.thumbnail) throw "Can't download while offline";
        return opts.thumbnail;
      }
      if (cmd === "reveal_attachment") return null;
      if (cmd === "open_attachment") {
        if (opts.openHang) return new Promise(() => {});
        if (opts.openError) throw opts.openError;
        return null;
      }
      if (cmd === "create_topic") return { id: "new", name: (args as { name: string }).name.trim(), archived: false, item_count: 0 };
      if (cmd === "picker_topic") {
        const name = (args as { name: string }).name.trim();
        const same = (opts.topics ?? []).find((t) => t.name.toLowerCase() === name.toLowerCase());
        if (same?.archived) throw "An archived Topic has that name";
        if (same) return same;
        const created = { id: "new", name, archived: false, item_count: 0 };
        opts.topics = [...(opts.topics ?? []), created];
        await emit("items-changed");
        return created;
      }
      if (["rename_topic", "archive_topic", "unarchive_topic", "delete_topic", "move_item"].includes(cmd)) return null;
      if (cmd === "plugin:opener|open_url") return null;
    },
    { shouldMockEvents: true },
  );
  return calls;
}

const at = (y: number, mo: number, d: number, h: number, mi: number) => new Date(y, mo - 1, d, h, mi).getTime() * 1000;
const feedItem = (
  id: string,
  text: string,
  capture_time_us: number,
  pending = false,
  attachments: FeedAttachment[] = [],
): FeedItem => ({
  id,
  text,
  capture_time_us,
  topic_id: null,
  in_tunnel: false,
  pending,
  attachments,
  purge_at_us: null,
  edit_base: 0,
  sync_error: null,
  conflict: null,
});

const topic = (id: string, name: string, extra: Partial<Topic> = {}): Topic => ({ id, name, archived: false, item_count: 0, ...extra });

const configured = { server_url: "https://notes.example.com", has_secret: true };

test("a failed launch says why, and offers the data folder and Quit", async () => {
  const calls = backend(configured, { startup: { message: "Couldn't open the database: file is not a database", data_dir: "/Users/me/data" } });
  render(<App />);
  expect(await screen.findByText("NoteBank couldn't start")).toBeInTheDocument();
  expect(screen.getByRole("alert")).toHaveTextContent("Couldn't open the database: file is not a database");
  expect(screen.getByText(/\/Users\/me\/data/)).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Show folder" }));
  await userEvent.click(screen.getByRole("button", { name: "Quit" }));
  expect(calls.map((c) => c.cmd)).toEqual(["startup_error", "show_data_folder", "quit"]);
});

test("a failed launch with no data folder offers only Quit", async () => {
  backend(configured, { startup: { message: "Couldn't find the data folder: no home", data_dir: null } });
  render(<App />);
  await screen.findByText("NoteBank couldn't start");
  expect(screen.queryByRole("button", { name: "Show folder" })).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Quit" })).toBeInTheDocument();
});

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
    args: { serverUrl: "https://notes.example.com", secret: null, confirmed: null },
  });
});

const stranded = {
  changes: 2,
  files: 1,
  message: "2 changes and 1 file haven't reached the current Server yet. Switching discards this work for good.",
};

async function switchServer() {
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.clear(screen.getByLabelText("Server URL"));
  await userEvent.type(screen.getByLabelText("Server URL"), "https://other.example.com");
  await userEvent.type(screen.getByLabelText("Secret"), "s3cret");
  await userEvent.click(screen.getByRole("button", { name: "Save" }));
}

test("a switch that would strand work asks first", async () => {
  backend(configured, { saveError: stranded });
  render(<App />);
  await switchServer();
  const dialog = await screen.findByRole("alertdialog", { name: "Discard unsent work?" });
  expect(dialog).toHaveTextContent(stranded.message);
  expect(dialog).toHaveTextContent("To keep it, reconnect to the current Server and let it sync first.");
  expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument();
});

test("Switch anyway resubmits with the confirmed counts", async () => {
  const calls = backend(configured, { saveError: stranded });
  render(<App />);
  await switchServer();
  await userEvent.click(await screen.findByRole("button", { name: "Switch anyway" }));
  const saves = calls.filter((c) => c.cmd === "save_settings");
  expect(saves).toHaveLength(2);
  expect(saves[1].args).toEqual({
    serverUrl: "https://other.example.com",
    secret: "s3cret",
    confirmed: { changes: 2, files: 1 },
  });
});

test("Switch anyway closes Settings once the confirmed save succeeds", async () => {
  backend(configured, { saveError: (call: number) => { if (call === 0) throw stranded; } });
  render(<App />);
  await switchServer();
  await userEvent.click(await screen.findByRole("button", { name: "Switch anyway" }));
  await vi.waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).not.toBeInTheDocument());
});

test("Cancel in the discard dialog keeps what was typed", async () => {
  const calls = backend(configured, { saveError: stranded });
  render(<App />);
  await switchServer();
  const dialog = await screen.findByRole("alertdialog");
  await userEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  expect(screen.getByLabelText("Server URL")).toHaveValue("https://other.example.com");
  expect(screen.getByLabelText("Secret")).toHaveValue("s3cret");
  expect(calls.filter((c) => c.cmd === "save_settings")).toHaveLength(1);
});

test("a check error shows in the red line", async () => {
  backend(configured, { saveError: "The Server rejected this secret." });
  render(<App />);
  await switchServer();
  expect(await screen.findByRole("alert")).toHaveTextContent("The Server rejected this secret.");
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
});

test("an error from an earlier attempt is gone when the discard dialog appears", async () => {
  backend(configured, {
    saveError: (call: number) => {
      throw call === 0 ? "Couldn't reach the Server." : stranded;
    },
  });
  render(<App />);
  await switchServer();
  expect(await screen.findByRole("alert")).toHaveTextContent("Couldn't reach the Server.");
  await userEvent.click(screen.getByRole("button", { name: "Save" }));
  await screen.findByRole("alertdialog");
  expect(screen.queryByText("Couldn't reach the Server.")).not.toBeInTheDocument();
});

test("a thrown Error shows in the red line, not the discard dialog", async () => {
  backend(configured, { saveError: new Error("boom") });
  render(<App />);
  await switchServer();
  expect(await screen.findByRole("alert")).toHaveTextContent("boom");
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
});

test("submitting again while Switch anyway is saving saves once more only", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  const calls = backend(configured, {
    saveError: async (call: number) => {
      if (call === 0) throw stranded;
      await gate;
    },
  });
  render(<App />);
  await switchServer();
  await userEvent.click(await screen.findByRole("button", { name: "Switch anyway" }));
  fireEvent.submit(screen.getByLabelText("Server URL").closest("form")!);
  await act(async () => release());
  await vi.waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).not.toBeInTheDocument());
  expect(calls.filter((c) => c.cmd === "save_settings")).toHaveLength(2);
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
  mockWindows("main");
  mockIPC(
    (cmd) => {
      if (cmd === "get_settings") {
        if (failing) throw "Couldn't read the keychain: locked";
        return configured;
      }
      if (cmd === "list_topics") return [];
      if (cmd === "sync_status") return "synced";
      if (cmd === "list_items") return [];
      if (cmd === "nav_counts") return { inbox: 0, tunnel: 0, trash: 0 };
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
    topics: [topic("1", "CS 111"), topic("2", "Mosaic")],
  });
  render(<App />);
  expect(await screen.findByRole("button", { name: "CS 111" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Mosaic" })).toBeInTheDocument();
  expect(screen.getByText("Nothing here yet.")).toBeInTheDocument();
});

test("Enter captures and Shift+Enter adds a line", async () => {
  const calls = backend(configured);
  localStorage.setItem("place", "inbox");
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  await userEvent.type(box, "a{Shift>}{Enter}{/Shift}b");
  expect(box).toHaveValue("a\nb");
  expect(calls.some((c) => c.cmd === "capture")).toBe(false);
  await userEvent.type(box, "{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "a\nb", attachmentIds: [], target: { kind: "inbox" } } });
  expect(box).toHaveValue("");
});

test("a file pasted while a Capture is saving stays for the next Item", async () => {
  let release!: () => void;
  const late: Staged = { id: "s1", filename: "late.png", size_bytes: 1, mime_type: "image/png" };
  backend(configured, { staged: [late], gates: { capture: new Promise((r) => (release = r)) } });
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  await userEvent.type(box, "milk{Enter}");
  fireEvent.paste(box, { clipboardData: { files: [new File(["x"], "late.png", { type: "image/png" })], getData: () => "" } });
  await screen.findByText("late.png");
  await act(async () => release());
  await vi.waitFor(() => expect(box).toHaveValue(""));
  expect(screen.getByText("late.png")).toBeInTheDocument();
});

test("the main composer keeps autocorrect and Escape leaves its draft alone", async () => {
  const calls = backend(configured);
  localStorage.setItem("place", "inbox");
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  expect(box).not.toHaveAttribute("autocorrect");
  await userEvent.type(box, "draft{Escape}");
  expect(box).toHaveValue("draft");
  expect(calls.some((c) => c.cmd === "dismiss_quick_capture")).toBe(false);
});

test("Send is disabled for blank text", async () => {
  backend(configured);
  localStorage.setItem("place", "inbox");
  render(<App />);
  await userEvent.type(await screen.findByLabelText("New Item"), "   ");
  expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
});

test("a failed capture keeps the text", async () => {
  backend(configured, { captureError: "That's too long to save (1 MB max)" });
  localStorage.setItem("place", "inbox");
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

const atSecond = (y: number, mo: number, d: number, h: number, mi: number, s: number) => new Date(y, mo - 1, d, h, mi, s).getTime() * 1000;

test("an Item captured in the same minute as the one above keeps its time only for hover and screen readers", async () => {
  backend(configured, {
    items: () => [
      feedItem("4", "next day", atSecond(2026, 10, 15, 9, 41, 20)),
      feedItem("3", "next minute", atSecond(2026, 10, 14, 9, 42, 0)),
      feedItem("2", "same minute", atSecond(2026, 10, 14, 9, 41, 59)),
      feedItem("1", "first", atSecond(2026, 10, 14, 9, 41, 5)),
    ],
  });
  const { container } = render(<App />);
  await screen.findByText("next day");
  const times = [...container.querySelectorAll<HTMLElement>(".nb-feed-scroll time")];
  expect(times.map((t) => t.classList.contains("nb-reveal"))).toEqual([false, true, false, false]);
  expect(times.every((t) => t.textContent)).toBe(true);
});

test("Trash shows every Item's time", async () => {
  backend(configured, {
    items: () => [
      { ...feedItem("2", "same minute", atSecond(2026, 10, 14, 9, 41, 59)), purge_at_us: Date.now() * 1000 },
      { ...feedItem("1", "first", atSecond(2026, 10, 14, 9, 41, 5)), purge_at_us: Date.now() * 1000 },
    ],
  });
  localStorage.setItem("place", "trash");
  const { container } = render(<App />);
  await screen.findByText("same minute");
  expect(container.querySelectorAll(".nb-feed-scroll time.nb-reveal")).toHaveLength(0);
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

test("middle-clicking a link opens it in the browser, never in the app", async () => {
  const calls = backend(configured, { items: () => [feedItem("1", "read https://example.com/x", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  const link = await screen.findByRole("link", { name: "https://example.com/x" });
  const middle = createEvent("auxclick", link, { button: 1, bubbles: true, cancelable: true }, { EventType: "MouseEvent" });
  fireEvent(link, middle);
  expect(middle.defaultPrevented).toBe(true);
  await vi.waitFor(() =>
    expect(calls).toContainEqual({ cmd: "plugin:opener|open_url", args: expect.objectContaining({ url: "https://example.com/x" }) }),
  );
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
      args: { view: { kind: "all" }, before: { capture_time_us: at(2026, 10, 14, 9, 41), id: "1", purge_at_us: null } },
    }),
  );
});

test("a rejected secret shows in the sidebar and opens Settings", async () => {
  backend(configured, { status: "unauthorized" });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Secret rejected" }));
  expect(screen.getByRole("heading", { name: "Settings" })).toBeInTheDocument();
});

test("a status read that answers after a newer sync-status event doesn't undo it", async () => {
  let release!: () => void;
  const calls = backend(configured, { status: "syncing", gates: { sync_status: new Promise((r) => (release = r)) } });
  render(<App />);
  await vi.waitFor(() => expect(calls.some((c) => c.cmd === "sync_status")).toBe(true));
  await act(() => emit("sync-status", "synced"));
  await act(async () => release());
  expect(await screen.findByText("Synced")).toBeInTheDocument();
  expect(screen.queryByText("Syncing…")).not.toBeInTheDocument();
});

test("the status line follows sync-status events", async () => {
  backend(configured);
  render(<App />);
  expect(await screen.findByText("Synced")).toBeInTheDocument();
  await act(() => emit("sync-status", "offline"));
  expect(await screen.findByText("Offline, retrying")).toBeInTheDocument();
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
  await userEvent.click(await screen.findByRole("button", { name: /^Inbox/ }));
  expect(await screen.findByText("inbox item")).toBeInTheDocument();
  await act(async () => release());
  expect(screen.queryByText("all items item")).not.toBeInTheDocument();
  expect(screen.getByText("inbox item")).toBeInTheDocument();
});

test("a Keychain problem shows in the sidebar", async () => {
  backend(configured, { status: "keychain" });
  render(<App />);
  expect(await screen.findByText("Keychain access needed")).toBeInTheDocument();
});

test("the theme is Warm paper until another is chosen", async () => {
  backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.click(screen.getByRole("button", { name: "Theme" }));
  expect(screen.getByRole("menuitemradio", { name: "Warm paper" })).toHaveAttribute("aria-checked", "true");
  expect(document.documentElement.dataset.theme).toBe("paper");
});

test("a theme chosen in Settings applies at once and is remembered", async () => {
  backend(configured);
  const { unmount } = render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.click(screen.getByRole("button", { name: "Theme" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Notepad" }));
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
  await userEvent.click(screen.getByRole("button", { name: "Theme" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Blackboard" }));
  expect(document.documentElement.dataset.theme).toBe("blackboard");

  unmount();
  render(<App />);
  await screen.findByText("Nothing here yet.");
  expect(document.documentElement.dataset.theme).toBe("blackboard");
});

const scan: Staged = { id: "s1", filename: "scan.png", size_bytes: 1_200_000, mime_type: "image/png" };
const report: FeedAttachment = { id: "a1", filename: "report.pdf", mime_type: "application/pdf", size_bytes: 2_400_000, has_thumbnail: false, runnable: false };
const photo: FeedAttachment = { id: "a2", filename: "photo.jpg", mime_type: "image/jpeg", size_bytes: 900_000, has_thumbnail: true, runnable: false };
const installer: FeedAttachment = { id: "a3", filename: "setup.command", mime_type: "application/octet-stream", size_bytes: 300, has_thumbnail: false, runnable: true };

test("picked files become chips, and one can be removed", async () => {
  const calls = backend(configured, { picked: { staged: [scan], errors: ["big.bin is over 100 MB"] } });
  localStorage.setItem("place", "inbox");
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Attach files" }));
  expect(await screen.findByText("scan.png")).toBeInTheDocument();
  expect(screen.getByRole("alertdialog", { name: "Couldn't attach a file" })).toHaveTextContent("big.bin is over 100 MB");
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Remove scan.png" }));
  expect(screen.queryByText("scan.png")).not.toBeInTheDocument();
  expect(calls).toContainEqual({ cmd: "unstage_attachment", args: { id: "s1" } });
});

test("an Attachment alone can be sent", async () => {
  const calls = backend(configured, { picked: { staged: [scan], errors: [] } });
  localStorage.setItem("place", "inbox");
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Attach files" }));
  await screen.findByText("scan.png");
  await userEvent.click(screen.getByRole("button", { name: "Send" }));
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "", attachmentIds: ["s1"], target: { kind: "inbox" } } });
  await vi.waitFor(() => expect(screen.queryByText("scan.png")).not.toBeInTheDocument());
});

test("a pasted image is staged from its bytes, and an oversized one is refused", async () => {
  const calls = backend(configured, { staged: [scan] });
  localStorage.setItem("place", "inbox");
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  const image = new File([new Uint8Array([1, 2, 3])], "image.png", { type: "image/png" });
  fireEvent.paste(box, { clipboardData: { files: [image], getData: () => "" } });
  expect(await screen.findByText("scan.png")).toBeInTheDocument();
  expect(calls.some((c) => c.cmd === "stage_attachment_bytes")).toBe(true);

  const huge = { name: "huge.mov", size: MAX_ATTACHMENT_BYTES + 1, arrayBuffer: async () => new ArrayBuffer(0) };
  fireEvent.paste(box, { clipboardData: { files: [huge], getData: () => "" } });
  expect(await screen.findByRole("alertdialog")).toHaveTextContent("huge.mov is over 100 MB");
});

for (const count of [1, 3]) {
  test(`pasting text with ${count} images preserves both in the captured Item`, async () => {
    const user = userEvent.setup();
    const staged = Array.from({ length: count }, (_, i) => ({ ...scan, id: `mixed-${i}`, filename: `mixed-${i}.png` }));
    const calls = backend(configured, { staged: [...staged] });
    localStorage.setItem("place", "inbox");
    render(<App />);
    const box = await screen.findByLabelText("New Item");
    await user.click(box);
    await user.paste({
      files: staged.map((file) => new File(["image"], file.filename, { type: "image/png" })),
      getData: (type: string) => type === "text" || type === "text/plain" ? "caption\nsecond line" : "",
    } as unknown as DataTransfer);
    expect(box).toHaveValue("caption\nsecond line");
    for (const file of staged) await screen.findByText(file.filename);
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(calls).toContainEqual({ cmd: "capture", args: { text: "caption\nsecond line", attachmentIds: staged.map((file) => file.id), target: { kind: "inbox" } } });
  });
}

test("files staged from a drop become chips, and failures are named", async () => {
  backend(configured);
  localStorage.setItem("place", "inbox");
  render(<App />);
  await screen.findByLabelText("New Item");
  await act(() =>
    emit("attachments-staged", { staged: [scan], errors: ["Photos isn't a file", "big.bin is over 100 MB"] }),
  );
  expect(await screen.findByText("scan.png")).toBeInTheDocument();
  const dialog = screen.getByRole("alertdialog", { name: "Couldn't attach 2 files" });
  expect(within(dialog).getAllByRole("listitem").map((li) => li.textContent)).toEqual([
    "Photos isn't a file",
    "big.bin is over 100 MB",
  ]);
  await userEvent.click(within(dialog).getByRole("button", { name: "OK" }));
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  expect(screen.getByText("scan.png")).toBeInTheDocument();
});

test("a file chip opens the file, and says why it can't", async () => {
  const calls = backend(configured, {
    items: () => [feedItem("1", "lab", at(2026, 10, 14, 9, 41), false, [report])],
    openError: "Can't download while offline",
  });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Open report.pdf" }));
  expect(calls).toContainEqual({ cmd: "open_attachment", args: { id: "a1" } });
  expect(await screen.findByText("Can't download while offline")).toBeInTheDocument();
  expect(screen.getByText("2.3 MB")).toBeInTheDocument();
});

test("an image shows its filename until the thumbnail arrives", async () => {
  backend(configured, { items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [photo])] });
  render(<App />);
  expect(await screen.findByText("photo.jpg")).toBeInTheDocument();
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
});

test("an image with a thumbnail shows it from local storage", async () => {
  backend(configured, {
    items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [photo])],
    thumbnail: "/data/thumbnails/a2.jpg",
  });
  render(<App />);
  const img = await screen.findByRole("img", { name: "photo.jpg" });
  expect(img).toHaveAttribute("src", expect.stringContaining("asset://localhost/"));
});

test("a video with a poster shows it with a play badge and opens in the default app", async () => {
  const clip: FeedAttachment = { ...photo, id: "a4", filename: "clip.mov", mime_type: "video/quicktime", size_bytes: 40_000_000 };
  const calls = backend(configured, {
    items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [clip])],
    thumbnail: "/data/thumbnails/a4.jpg",
  });
  render(<App />);
  expect(await screen.findByRole("img", { name: "clip.mov" })).toHaveAttribute("src", expect.stringContaining("asset://localhost/"));
  const button = screen.getByRole("button", { name: "Play clip.mov" });
  expect(button.querySelector(".nb-thumb-play")).not.toBeNull();
  await userEvent.click(button);
  expect(calls).toContainEqual({ cmd: "open_attachment", args: { id: "a4" } });
});

test("a video without a poster stays a file chip", async () => {
  const clip: FeedAttachment = { ...report, id: "a4", filename: "clip.mov", mime_type: "video/quicktime", size_bytes: 40_000_000 };
  const calls = backend(configured, { items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [clip])] });
  render(<App />);
  const chip = await screen.findByRole("button", { name: "Open clip.mov" });
  expect(chip).toHaveClass("nb-file");
  expect(screen.getByText("38.1 MB")).toBeInTheDocument();
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  expect(calls.some((c) => c.cmd === "thumbnail")).toBe(false);
});

test("a stored theme that isn't one falls back to Warm paper", async () => {
  localStorage.setItem("theme", "toString");
  backend(configured);
  render(<App />);
  await screen.findByText("Nothing here yet.");
  expect(document.documentElement.dataset.theme).toBe("paper");
});

test("a file that can run code is never opened, only shown in Finder", async () => {
  const calls = backend(configured, { items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [installer])] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Open setup.command" }));
  expect(screen.getByText("NoteBank won't open setup.command because it can run code.")).toBeInTheDocument();
  expect(calls.some((c) => c.cmd === "open_attachment")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "Show in Finder" }));
  expect(calls).toContainEqual({ cmd: "reveal_attachment", args: { id: "a3" } });
});

test("a second click while downloading is ignored", async () => {
  const calls = backend(configured, {
    items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [report])],
    openHang: true,
  });
  render(<App />);
  const chip = await screen.findByRole("button", { name: "Open report.pdf" });
  await userEvent.click(chip);
  await userEvent.click(chip);
  expect(calls.filter((c) => c.cmd === "open_attachment")).toHaveLength(1);
});

test("the Archived section is there with nothing archived, and says so when opened", async () => {
  backend(configured, { topics: [topic("g", "Gym")] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Archived" }));
  expect(screen.getAllByText("None yet")).toHaveLength(1);
});

test("archived Topics are under a collapsed Archived section", async () => {
  backend(configured, { topics: [topic("g", "Gym"), topic("o", "Old", { archived: true })] });
  render(<App />);
  expect(await screen.findByRole("button", { name: "Gym" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Old" })).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Archived 1" }));
  expect(screen.getByRole("button", { name: "Old" })).toBeInTheDocument();
});

test("a Topic's menu archives it, and an archived one's unarchives it", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym"), topic("o", "Old", { archived: true })] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Archive" }));
  expect(calls).toContainEqual({ cmd: "archive_topic", args: { id: "g" } });
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();

  await userEvent.click(screen.getByRole("button", { name: "Archived 1" }));
  await userEvent.click(screen.getByRole("button", { name: "Old actions" }));
  expect(screen.queryByRole("menuitem", { name: "Archive" })).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("menuitem", { name: "Unarchive" }));
  expect(calls).toContainEqual({ cmd: "unarchive_topic", args: { id: "o" } });
});

test("Escape closes a menu and returns focus to its button", async () => {
  backend(configured, { topics: [topic("g", "Gym")] });
  render(<App />);
  const button = await screen.findByRole("button", { name: "Gym actions" });
  await userEvent.click(button);
  expect(screen.getByRole("menu")).toBeInTheDocument();
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  expect(button).toHaveFocus();
});

test("scrolling elsewhere closes an open menu", async () => {
  backend(configured, { topics: [topic("g", "Gym")] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym actions" }));
  fireEvent.scroll(screen.getByTestId("feed-items"));
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
});

test("the sidebar refetches Topics when items change", async () => {
  let topics: Topic[] = [];
  mockWindows("main");
  mockIPC(
    (cmd) => {
      if (cmd === "get_settings") return configured;
      if (cmd === "list_topics") return topics;
      if (cmd === "sync_status") return "synced";
      if (cmd === "startup_error") return null;
      return [];
    },
    { shouldMockEvents: true },
  );
  render(<App />);
  expect(await screen.findByText("None yet")).toBeInTheDocument();
  topics = [topic("g", "From my phone")];
  await act(() => emit("items-changed"));
  expect(await screen.findByRole("button", { name: "From my phone" })).toBeInTheDocument();
});

test("when the selected Topic disappears the Inbox is shown", async () => {
  let topics = [topic("g", "Gym")];
  const calls: { cmd: string; args: any }[] = [];
  mockWindows("main");
  mockIPC(
    (cmd, args) => {
      calls.push({ cmd, args });
      if (cmd === "get_settings") return configured;
      if (cmd === "list_topics") return topics;
      if (cmd === "sync_status") return "synced";
      if (cmd === "startup_error") return null;
      return [];
    },
    { shouldMockEvents: true },
  );
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym" }));
  topics = [];
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(screen.getByRole("button", { name: /^Inbox/ })).toHaveAttribute("aria-current", "page"));
  const lists = calls.filter((c) => c.cmd === "list_items");
  expect(lists[lists.length - 1].args.view).toEqual({ kind: "inbox" });
});

test("a failed Topic change is shown in a dialog", async () => {
  backend(configured, { topics: [topic("g", "Gym")], failing: { archive_topic: "That Topic no longer exists" } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Archive" }));
  const dialog = await screen.findByRole("alertdialog", { name: "Couldn't archive the Topic" });
  expect(dialog).toHaveTextContent("That Topic no longer exists");
  await userEvent.click(within(dialog).getByRole("button", { name: "OK" }));
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
});

test("+ creates a Topic in the shared dialog and opens it", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  await userEvent.type(screen.getByLabelText("Topic name"), "Books{Enter}");
  expect(calls).toContainEqual({ cmd: "picker_topic", args: { name: "Books" } });
  await vi.waitFor(() => expect(screen.queryByLabelText("Topic name")).not.toBeInTheDocument());
  const lists = calls.filter((c) => c.cmd === "list_items");
  expect(lists[lists.length - 1].args.view).toEqual({ kind: "topic", id: "new" });
});

test("a name clash keeps the field open with the error", async () => {
  backend(configured, { failing: { picker_topic: 'A Topic named "Books" already exists' } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  await userEvent.type(screen.getByLabelText("Topic name"), "books{Enter}");
  expect(await screen.findByRole("alert")).toHaveTextContent('A Topic named "Books" already exists');
  expect(screen.getByLabelText("Topic name")).toHaveValue("books");
});

test("Escape cancels naming a Topic", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  await userEvent.type(screen.getByLabelText("Topic name"), "Books{Escape}");
  expect(screen.queryByLabelText("Topic name")).not.toBeInTheDocument();
  expect(calls.some((c) => c.cmd === "picker_topic")).toBe(false);
});

test("Enter twice creates one Topic", async () => {
  let release!: () => void;
  const calls = backend(configured, { gates: { picker_topic: new Promise<void>((resolve) => (release = resolve)) } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  // The first create is still in flight when the second Enter arrives.
  await userEvent.type(screen.getByLabelText("Topic name"), "Books{Enter}{Enter}");
  await act(async () => release());
  await vi.waitFor(() => expect(screen.queryByLabelText("Topic name")).not.toBeInTheDocument());
  expect(calls.filter((c) => c.cmd === "picker_topic")).toHaveLength(1);
  expect(screen.queryByRole("alert")).not.toBeInTheDocument();
});

test("Rename edits a Topic's name in place", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
  const field = screen.getByLabelText("Topic name");
  expect(field).toHaveValue("Gym");
  await userEvent.clear(field);
  await userEvent.type(field, "Lifting{Enter}");
  expect(calls).toContainEqual({ cmd: "rename_topic", args: { id: "g", name: "Lifting" } });
});

const filed = (id: string, text: string, topic_id: string | null): FeedItem => ({ ...feedItem(id, text, at(2026, 10, 14, 9, 41)), topic_id });

test("a submenu that would run past the bottom of the window opens upward instead", async () => {
  backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  const rect = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
    return { top: 500, bottom: this.classList.contains("nb-submenu") ? window.innerHeight + 80 : 540, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON() {} } as DOMRect;
  });
  await userEvent.hover(screen.getByRole("menuitem", { name: "Move to" }));
  expect(screen.getByRole("menu", { name: "Move to" })).toHaveClass("up");
  rect.mockRestore();
});

test("Move to… lists the Inbox and open Topics, with the current place ticked", async () => {
  const calls = backend(configured, {
    topics: [topic("g", "Gym"), topic("w", "Work"), topic("o", "Old", { archived: true })],
    items: () => [filed("1", "squat 100", null)],
  });
  render(<App />);
  const article = await screen.findByRole("article");
  await userEvent.click(within(article).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  const targets = within(screen.getByRole("menu", { name: "Move to" })).getAllByRole("menuitemradio");
  expect(targets.map((t) => [t.textContent?.replace(" ✓", ""), t.getAttribute("aria-checked")])).toEqual([
    ["Inbox", "true"],
    ["Tunnel", "false"],
    ["Gym", "false"],
    ["Work", "false"],
  ]);
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  expect(calls).toContainEqual({ cmd: "move_item", args: { itemId: "1", target: { kind: "topic", id: "g" } } });
});

test("Move to filters its places as you type and keeps New Topic… below the list", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym"), topic("w", "Work")], items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.keyboard("{ArrowDown}{ArrowRight}");
  const filter = screen.getByRole("searchbox", { name: "Find a place" });
  expect(filter).toHaveFocus();
  await userEvent.type(filter, "w");
  expect(within(screen.getByRole("menu", { name: "Move to" })).getAllByRole("menuitemradio").map((t) => t.textContent)).toEqual(["Work"]);
  expect(screen.getByRole("menuitem", { name: "New Topic…" })).toBeInTheDocument();
  await userEvent.keyboard("{ArrowDown}");
  expect(screen.getByRole("menuitemradio", { name: "Work" })).toHaveFocus();
  await userEvent.keyboard("{Enter}");
  expect(calls).toContainEqual({ cmd: "move_item", args: { itemId: "1", target: { kind: "topic", id: "w" } } });
});

test("moving an Item to where it is does nothing", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "x", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Inbox" }));
  expect(calls.some((c) => c.cmd === "move_item")).toBe(false);
});

const grip = (text: string) => within(screen.getByText(text).closest("article") as HTMLElement).getByTitle("Drag to a Topic");
function drag(text: string, target: HTMLElement | null, distance = 10) {
  fireEvent.pointerDown(grip(text), { clientX: 0, clientY: 0, button: 0 });
  fireEvent.pointerMove(window, { clientX: distance, clientY: 0 });
  if (target) fireEvent.pointerEnter(target);
  fireEvent.pointerUp(window, { clientX: distance, clientY: 0 });
}
const moves = (calls: { cmd: string; args: any }[]) => calls.filter((c) => c.cmd === "move_item").map((c) => c.args);

test("dragging an Item by its grip onto a Topic moves it, and Undo moves it back", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await screen.findByText("squat 100");
  drag("squat 100", screen.getByRole("button", { name: "Gym" }));
  await vi.waitFor(() => expect(moves(calls)).toEqual([{ itemId: "1", target: { kind: "topic", id: "g" } }]));
  await screen.findByText("Moved to Gym");
  await userEvent.click(screen.getByRole("button", { name: "Undo" }));
  expect(moves(calls)).toEqual([{ itemId: "1", target: { kind: "topic", id: "g" } }, { itemId: "1", target: { kind: "inbox" } }]);
});

test("Move to… also says where the Item went", async () => {
  backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "x", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  expect(await screen.findByText("Moved to Gym")).toBeInTheDocument();
});

test("only the Inbox and other open Topics take a dropped Item", async () => {
  const calls = backend(configured, {
    topics: [topic("g", "Gym"), topic("o", "Old", { archived: true })],
    items: () => [filed("1", "squat 100", "g")],
  });
  render(<App />);
  await screen.findByText("squat 100");
  await userEvent.click(screen.getByRole("button", { name: /Archived/ }));
  for (const target of [screen.getByRole("button", { name: "Gym" }), screen.getByRole("button", { name: "Old" }), screen.getByRole("button", { name: /^All Items/ }), screen.getByRole("button", { name: /^Trash/ })]) {
    drag("squat 100", target);
  }
  expect(moves(calls)).toEqual([]);
  drag("squat 100", screen.getByRole("button", { name: /^Inbox/ }));
  await vi.waitFor(() => expect(moves(calls)).toEqual([{ itemId: "1", target: { kind: "inbox" } }]));
  expect(await screen.findByText("Moved to the Inbox")).toBeInTheDocument();
});

test("a press that barely moves, or Escape mid-drag, moves nothing", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await screen.findByText("squat 100");
  const gym = screen.getByRole("button", { name: "Gym" });
  drag("squat 100", gym, 3);
  fireEvent.pointerDown(grip("squat 100"), { clientX: 0, clientY: 0, button: 0 });
  fireEvent.pointerMove(window, { clientX: 10, clientY: 0 });
  fireEvent.pointerEnter(gym);
  fireEvent.keyDown(window, { key: "Escape" });
  fireEvent.pointerUp(window, { clientX: 10, clientY: 0 });
  await new Promise((r) => setTimeout(r, 50));
  expect(moves(calls)).toEqual([]);
});

test("right-clicking an Item opens its menu", async () => {
  backend(configured, { items: () => [filed("1", "x", null)] });
  render(<App />);
  fireEvent.contextMenu(await screen.findByRole("article"));
  expect(screen.getByRole("menu", { name: "Item actions" })).toBeInTheDocument();
});

test("a failed move is shown in a dialog", async () => {
  backend(configured, {
    topics: [topic("g", "Gym")],
    items: () => [filed("1", "x", null)],
    failing: { move_item: "That Topic is archived" },
  });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  expect(await screen.findByRole("alertdialog", { name: "Couldn't move the Item" })).toHaveTextContent("That Topic is archived");
});

test("All Items shows each Item's place as a chip, Topic names as text", async () => {
  backend(configured, {
    topics: [topic("g", "<b>Gym</b>")],
    // Newest first, as list_items returns them; the Feed shows them oldest first.
    items: () => [filed("2", "loose", null), filed("1", "squat 100", "g")],
  });
  render(<App />);
  const [first, second] = await screen.findAllByRole("article");
  expect(within(first).getByTitle("In <b>Gym</b>")).toHaveTextContent("<b>Gym</b>");
  expect(within(second).getByTitle("In Inbox")).toHaveTextContent("Inbox");

  await userEvent.click(screen.getByRole("button", { name: "<b>Gym</b>" }));
  await vi.waitFor(() => expect(within(screen.getAllByRole("article")[0]).queryByTitle("In <b>Gym</b>")).not.toBeInTheDocument());
});

test("each Topic in the sidebar shows how many Items it has", async () => {
  backend(configured, { topics: [topic("g", "Gym", { item_count: 12 })] });
  render(<App />);
  const name = await screen.findByRole("button", { name: "Gym" });
  expect(name.parentElement).toHaveTextContent("12");
});

test("capturing in a Topic files the Item there", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")] });
  render(<App />);
  expect(await screen.findByPlaceholderText("Write to Inbox…")).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Gym" }));
  await userEvent.type(await screen.findByPlaceholderText("Write to Gym…"), "squat 100{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "squat 100", attachmentIds: [], target: { kind: "topic", id: "g" } } });
});

test("an archived Topic shows a bar instead of the composer", async () => {
  const calls = backend(configured, { topics: [topic("o", "Old", { archived: true })] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Archived 1" }));
  await userEvent.click(screen.getByRole("button", { name: "Old" }));
  expect(await screen.findByText('"Old" is archived.')).toBeInTheDocument();
  expect(screen.getByLabelText("New Item")).not.toBeVisible();
  await userEvent.click(screen.getByRole("button", { name: "Unarchive" }));
  expect(calls).toContainEqual({ cmd: "unarchive_topic", args: { id: "o" } });
});

async function openDelete(name: string) {
  await userEvent.click(await screen.findByRole("button", { name: `${name} actions` }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Delete…" }));
}

test("deleting an empty Topic just confirms", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")] });
  render(<App />);
  await openDelete("Gym");
  const dialog = screen.getByRole("dialog", { name: 'Delete "Gym"?' });
  expect(within(dialog).queryByRole("button", { name: "Keep all" })).not.toBeInTheDocument();
  await userEvent.click(within(dialog).getByRole("button", { name: "Delete" }));
  expect(calls).toContainEqual({ cmd: "delete_topic", args: { id: "g", keep: { kind: "none" } } });
  await vi.waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
});

test("Keep all and Delete all send their choice", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym", { item_count: 3 })] });
  render(<App />);
  await openDelete("Gym");
  expect(screen.getByRole("dialog")).toHaveTextContent("It has 3 Items.");
  await userEvent.click(screen.getByRole("button", { name: "Keep all" }));
  expect(calls).toContainEqual({ cmd: "delete_topic", args: { id: "g", keep: { kind: "all" } } });

  await vi.waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Delete all" }));
  expect(calls).toContainEqual({ cmd: "delete_topic", args: { id: "g", keep: { kind: "none" } } });
});

test("Select manually pages through the Topic and keeps only checked Items", async () => {
  const notes = Array.from({ length: 100 }, (_, i) => feedItem(`p${i}`, `note ${i}`, at(2026, 10, 14, 9, 0) - i));
  const calls = backend(configured, {
    topics: [topic("g", "Gym", { item_count: 101 })],
    items: (args) => (args.view.kind !== "topic" ? [] : args.before ? [feedItem("last", "last one", at(2026, 10, 1, 9, 0))] : notes),
  });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Select manually…" }));
  const dialog = screen.getByRole("dialog", { name: 'Choose Items to keep from "Gym"' });
  expect(await within(dialog).findByText("Page 1 of 2")).toBeInTheDocument();
  expect(within(dialog).getByRole("checkbox", { name: /note 3$/ })).not.toBeChecked();
  await userEvent.click(within(dialog).getByRole("checkbox", { name: /note 3$/ }));

  await userEvent.click(within(dialog).getByRole("button", { name: "Next" }));
  await userEvent.click(await within(dialog).findByRole("checkbox", { name: /last one/ }));
  expect(within(dialog).getByText("Page 2 of 2")).toBeInTheDocument();
  expect(within(dialog).getByRole("button", { name: "Next" })).toBeDisabled();

  await userEvent.click(within(dialog).getByRole("button", { name: "Prev" }));
  expect(await within(dialog).findByRole("checkbox", { name: /note 3$/ })).toBeChecked();
  await userEvent.click(within(dialog).getByRole("button", { name: "Keep 2 · Trash 99" }));
  expect(calls).toContainEqual({ cmd: "delete_topic", args: { id: "g", keep: { kind: "only", ids: ["p3", "last"] } } });
});

test("a failed delete keeps the dialog open and says why", async () => {
  backend(configured, { topics: [topic("g", "Gym", { item_count: 1 })], failing: { delete_topic: "That Topic no longer exists" } });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Delete all" }));
  expect(await screen.findByRole("alertdialog", { name: "Couldn't delete the Topic" })).toHaveTextContent("no longer exists");
  expect(screen.getByRole("dialog", { name: 'Delete "Gym"?' })).toBeInTheDocument();
});

test("the draft survives a visit to an archived Topic", async () => {
  backend(configured, { topics: [topic("o", "Old", { archived: true })] });
  localStorage.setItem("place", "inbox");
  render(<App />);
  await userEvent.type(await screen.findByLabelText("New Item"), "half a thought");
  await userEvent.click(screen.getByRole("button", { name: "Archived 1" }));
  await userEvent.click(screen.getByRole("button", { name: "Old" }));
  expect(await screen.findByText('"Old" is archived.')).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  expect(await screen.findByLabelText("New Item")).toHaveValue("half a thought");
});

test("clicking Delete all twice deletes once and shows no error", async () => {
  let release!: () => void;
  const calls = backend(configured, {
    topics: [topic("g", "Gym", { item_count: 1 })],
    gates: { delete_topic: new Promise<void>((resolve) => (release = resolve)) },
  });
  render(<App />);
  await openDelete("Gym");
  await userEvent.dblClick(screen.getByRole("button", { name: "Delete all" }));
  await act(async () => release());
  await vi.waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
  expect(calls.filter((c) => c.cmd === "delete_topic")).toHaveLength(1);
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
});

test("Select manually takes focus on its first checkbox, so Escape closes it and focus goes back", async () => {
  backend(configured, {
    topics: [topic("g", "Gym", { item_count: 2 })],
    items: (args) => (args.view.kind === "topic" ? [feedItem("1", "one", at(2026, 10, 14, 9, 0)), feedItem("2", "two", at(2026, 10, 14, 8, 0))] : []),
  });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Select manually…" }));
  await vi.waitFor(() => expect(screen.getByRole("checkbox", { name: /one$/ })).toHaveFocus());
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Gym actions" })).toHaveFocus();
});

test("closing the Error dialog returns focus to what opened it", async () => {
  backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "x", null)], failing: { move_item: "That Topic is archived" } });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  await userEvent.click(await screen.findByRole("button", { name: "OK" }));
  expect(screen.getByRole("button", { name: "Item actions" })).toHaveFocus();
});

test("a Topic of exactly 100 Items has one page", async () => {
  const notes = Array.from({ length: 100 }, (_, i) => feedItem(`p${i}`, `note ${i}`, at(2026, 10, 14, 9, 0) - i));
  backend(configured, { topics: [topic("g", "Gym", { item_count: 100 })], items: (args) => (args.view.kind === "topic" && !args.before ? notes : []) });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Select manually…" }));
  expect(await screen.findByText("Page 1 of 1")).toBeInTheDocument();
  await screen.findByRole("checkbox", { name: /note 0$/ });
  expect(screen.getByRole("button", { name: "Next" })).toBeDisabled();
});

test("a slow page shows Loading and holds the pager and the confirm", async () => {
  const notes = Array.from({ length: 100 }, (_, i) => feedItem(`p${i}`, `note ${i}`, at(2026, 10, 14, 9, 0) - i));
  let release!: () => void;
  const slow = new Promise<void>((resolve) => (release = resolve));
  backend(configured, {
    topics: [topic("g", "Gym", { item_count: 101 })],
    items: async (args) => {
      if (args.view.kind !== "topic") return [];
      if (!args.before) return notes;
      await slow;
      return [feedItem("last", "last one", at(2026, 10, 1, 9, 0))];
    },
  });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Select manually…" }));
  await screen.findByRole("checkbox", { name: /note 0$/ });
  await userEvent.click(screen.getByRole("button", { name: "Next" }));
  expect(await screen.findByText("Loading Items…", {}, { timeout: 1500 })).toBeInTheDocument();
  for (const name of ["Prev", "Next", "Keep 0 · Trash 101"]) expect(screen.getByRole("button", { name })).toBeDisabled();
  await act(async () => release());
  expect(await screen.findByRole("checkbox", { name: /last one/ })).toBeInTheDocument();
  expect(screen.queryByText("Loading Items…")).not.toBeInTheDocument();
});

test("a page that fails to load says so in the list, keeps the ticks and can be retried", async () => {
  const notes = Array.from({ length: 100 }, (_, i) => feedItem(`p${i}`, `note ${i}`, at(2026, 10, 14, 9, 0) - i));
  let fail = true;
  backend(configured, {
    topics: [topic("g", "Gym", { item_count: 101 })],
    items: (args) => {
      if (args.view.kind !== "topic") return [];
      if (!args.before) return notes;
      if (fail) throw "The local store is busy";
      return [feedItem("last", "last one", at(2026, 10, 1, 9, 0))];
    },
  });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Select manually…" }));
  await userEvent.click(await screen.findByRole("checkbox", { name: /note 3$/ }));
  await userEvent.click(screen.getByRole("button", { name: "Next" }));
  const dialog = screen.getByRole("dialog");
  expect(await within(dialog).findByText("Couldn't load the Items")).toBeInTheDocument();
  expect(dialog).toHaveTextContent("The local store is busy");
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  fail = false;
  await userEvent.click(within(dialog).getByRole("button", { name: "Try again" }));
  expect(await within(dialog).findByRole("checkbox", { name: /last one/ })).toBeInTheDocument();
  expect(within(dialog).getByRole("button", { name: "Keep 1 · Trash 100" })).toBeInTheDocument();
});

test("a slow delete says what it's doing and holds Cancel, then a Notice says what happened", async () => {
  let release!: () => void;
  backend(configured, {
    topics: [topic("g", "Gym", { item_count: 3 })],
    gates: { delete_topic: new Promise<void>((resolve) => (release = resolve)) },
  });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Keep all" }));
  expect(await screen.findByText("Moving 3 Items to the Inbox…", {}, { timeout: 1500 })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Cancel" })).toBeDisabled();
  expect(screen.queryByRole("button", { name: "Delete all" })).not.toBeInTheDocument();
  await act(async () => release());
  await vi.waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
  expect(screen.getByText('Deleted "Gym". 3 Items moved to the Inbox.')).toBeInTheDocument();
});

test("the Notice goes on dismiss, or when the view changes", async () => {
  backend(configured, { topics: [topic("g", "Gym", { item_count: 2 }), topic("w", "Work")] });
  render(<App />);
  await openDelete("Gym");
  await userEvent.click(screen.getByRole("button", { name: "Delete all" }));
  expect(await screen.findByText('Deleted "Gym". 2 Items moved to Trash.')).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Dismiss" }));
  expect(screen.queryByText(/Deleted "Gym"/)).not.toBeInTheDocument();

  await openDelete("Work");
  await userEvent.click(screen.getByRole("button", { name: "Delete" }));
  expect(await screen.findByText('Deleted "Work".')).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  expect(screen.queryByText('Deleted "Work".')).not.toBeInTheDocument();
});

test("the Notice goes by itself after 8 seconds, but waits while hovered", async () => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  try {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    backend(configured, { topics: [topic("g", "Gym")] });
    render(<App />);
    await user.click(await screen.findByRole("button", { name: "Gym actions" }));
    await user.click(screen.getByRole("menuitem", { name: "Delete…" }));
    await user.click(screen.getByRole("button", { name: "Delete" }));
    const notice = await screen.findByText('Deleted "Gym".');
    await user.hover(notice);
    await act(async () => vi.advanceTimersByTime(9000));
    expect(screen.getByText('Deleted "Gym".')).toBeInTheDocument();
    await user.unhover(notice);
    await act(async () => vi.advanceTimersByTime(8000));
    expect(screen.queryByText('Deleted "Gym".')).not.toBeInTheDocument();
  } finally {
    vi.useRealTimers();
  }
});

test("Topics sort by name the way people read them, accents with their letter", async () => {
  // The Rust side sorts by lowercased bytes, which puts "École" after "Zebra".
  backend(configured, { topics: [topic("a", "apple"), topic("z", "Zebra"), topic("e", "École")] });
  render(<App />);
  await screen.findByRole("button", { name: "apple" });
  const names = Array.from(document.querySelectorAll(".nb-topic-name")).map((b) => b.textContent);
  expect(names).toEqual(["apple", "École", "Zebra"]);
});

test("archiving the open Topic opens the Archived section, so the selection stays in view", async () => {
  const topics = [topic("g", "Gym")];
  backend(configured, { topics });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym" }));
  topics[0] = topic("g", "Gym", { archived: true });
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(screen.getByRole("button", { name: "Archived 1" })).toHaveAttribute("aria-expanded", "true"));
  expect(screen.getByRole("button", { name: "Gym" })).toHaveAttribute("aria-current", "page");
});

test("after renaming a Topic, focus is on its row", async () => {
  const topics = [topic("g", "Gym")];
  backend(configured, { topics });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Gym actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
  await userEvent.clear(screen.getByLabelText("Topic name"));
  await userEvent.type(screen.getByLabelText("Topic name"), "Lifting{Enter}");
  topics[0] = topic("g", "Lifting");
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(screen.getByRole("button", { name: "Lifting" })).toHaveFocus());
});

test("after creating a Topic focus is on its row, and Escape puts focus back on +", async () => {
  const topics: Topic[] = [];
  backend(configured, { topics });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  await userEvent.keyboard("{Escape}");
  expect(screen.getByRole("button", { name: "New Topic" })).toHaveFocus();

  await userEvent.click(screen.getByRole("button", { name: "New Topic" }));
  await userEvent.type(screen.getByLabelText("Topic name"), "Reading{Enter}");
  topics.push(topic("new", "Reading"));
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(screen.getByRole("button", { name: "Reading" })).toHaveFocus());
});

test("arrow keys move through a menu and open and close its submenu", async () => {
  backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  expect(screen.getByRole("menuitem", { name: "Edit" })).toHaveFocus();
  await userEvent.keyboard("{ArrowDown}{ArrowDown}{ArrowDown}");
  expect(screen.getByRole("menuitem", { name: "Move to Trash" })).toHaveFocus();
  await userEvent.keyboard("{ArrowDown}");
  expect(screen.getByRole("menuitem", { name: "Edit" })).toHaveFocus();
  await userEvent.keyboard("{End}");
  expect(screen.getByRole("menuitem", { name: "Move to Trash" })).toHaveFocus();
  await userEvent.keyboard("{Home}");
  expect(screen.getByRole("menuitem", { name: "Edit" })).toHaveFocus();
  await userEvent.keyboard("{ArrowDown}{ArrowRight}");
  expect(screen.getByRole("searchbox", { name: "Find a place" })).toHaveFocus();
  await userEvent.keyboard("{ArrowDown}");
  expect(screen.getByRole("menuitemradio", { name: "Inbox" })).toHaveFocus();
  await userEvent.keyboard("{ArrowDown}{ArrowDown}");
  expect(screen.getByRole("menuitemradio", { name: "Gym" })).toHaveFocus();
  await userEvent.keyboard("{ArrowLeft}");
  expect(screen.queryByRole("menuitemradio", { name: "Gym" })).not.toBeInTheDocument();
  expect(screen.getByRole("menuitem", { name: "Move to" })).toHaveFocus();
});

test("Copy text puts the Item's text on the clipboard", async () => {
  const user = userEvent.setup();
  backend(configured, { items: () => [filed("1", "squat 100\nfelt easy", null)] });
  render(<App />);
  await user.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await user.click(screen.getByRole("menuitem", { name: "Copy text" }));
  expect(await navigator.clipboard.readText()).toBe("squat 100\nfelt easy");
});

test("an Item with only files has no Copy text", async () => {
  backend(configured, { items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [report])] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  expect(screen.queryByRole("menuitem", { name: "Copy text" })).not.toBeInTheDocument();
});

test("Settings opens as a panel over the window, keeping the draft, and Escape closes it", async () => {
  backend(configured);
  localStorage.setItem("place", "inbox");
  render(<App />);
  await userEvent.type(await screen.findByLabelText("New Item"), "half a thought");
  await userEvent.click(screen.getByRole("button", { name: "Settings" }));
  expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument();
  expect(screen.getByLabelText("Server URL")).toHaveFocus();
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("dialog", { name: "Settings" })).not.toBeInTheDocument();
  expect(screen.getByLabelText("New Item")).toHaveValue("half a thought");
  expect(screen.getByRole("button", { name: "Settings" })).toHaveFocus();
});

test("on first launch Save waits for both the Server URL and the secret", async () => {
  backend({ server_url: null, has_secret: false });
  render(<App />);
  const save = await screen.findByRole("button", { name: "Save" });
  expect(save).toBeDisabled();
  await userEvent.type(screen.getByLabelText("Server URL"), "https://notes.example.com");
  expect(save).toBeDisabled();
  await userEvent.type(screen.getByLabelText("Secret"), "s3cret");
  expect(save).toBeEnabled();
});

test("a slow save says Saving…, holds both buttons and saves once", async () => {
  let release!: () => void;
  const calls = backend(configured, { gates: { save_settings: new Promise<void>((resolve) => (release = resolve)) } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await userEvent.dblClick(screen.getByRole("button", { name: "Save" }));
  expect(await screen.findByRole("button", { name: "Saving…" }, { timeout: 1500 })).toBeDisabled();
  expect(screen.getByRole("button", { name: "Cancel" })).toBeDisabled();
  await act(async () => release());
  await vi.waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).not.toBeInTheDocument());
  expect(calls.filter((c) => c.cmd === "save_settings")).toHaveLength(1);
});

test("while older Items load, a Loading line shows at the top", async () => {
  let release!: () => void;
  const slow = new Promise<void>((resolve) => (release = resolve));
  backend(configured, {
    items: async (args) => {
      if (!args.before) return [feedItem("2", "newest page", at(2026, 10, 14, 9, 41))];
      await slow;
      return [feedItem("1", "older page", at(2026, 10, 13, 9, 41))];
    },
  });
  render(<App />);
  await screen.findByText("newest page");
  fireEvent.scroll(screen.getByTestId("feed-items"));
  expect(await screen.findByText("Loading earlier Items…", {}, { timeout: 1500 })).toBeInTheDocument();
  await act(async () => release());
  expect(await screen.findByText("older page")).toBeInTheDocument();
  expect(screen.queryByText("Loading earlier Items…")).not.toBeInTheDocument();
});

test("Items that fail to load are shown in the Error dialog", async () => {
  backend(configured, { failing: { list_items: "The local store is busy" } });
  render(<App />);
  expect(await screen.findByRole("alertdialog", { name: "Couldn't load the Items" })).toHaveTextContent("The local store is busy");
});

const trashOf = async (text: string, user: { click: (el: Element) => Promise<void> } = userEvent) => {
  const article = (await screen.findByText(text)).closest("article")!;
  await user.click(within(article as HTMLElement).getByRole("button", { name: "Item actions" }));
  await user.click(screen.getByRole("menuitem", { name: "Move to Trash" }));
};

test("the Item menu is Edit, Move to, Copy text, then Move to Trash in red after a separator", async () => {
  backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  const menu = screen.getByRole("menu", { name: "Item actions" });
  expect(within(menu).getAllByRole("menuitem").map((m) => m.textContent)).toEqual(["Edit", "Move to", "Copy text", "Move to Trash"]);
  expect(within(menu).getByRole("separator")).toBeInTheDocument();
  expect(within(menu).getByRole("menuitem", { name: "Move to Trash" })).toHaveClass("is-danger");
});

test("Move to Trash acts at once, and Undo restores the Item and highlights it", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await trashOf("squat 100");
  expect(calls).toContainEqual({ cmd: "trash_item", args: { itemId: "1" } });
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  await screen.findByText("Item moved to Trash");
  await userEvent.click(screen.getByRole("button", { name: "Undo" }));
  expect(calls).toContainEqual({ cmd: "restore_item", args: { itemId: "1" } });
  await vi.waitFor(() => expect(screen.getByRole("article")).toHaveClass("is-highlight"));
  expect(screen.queryByText("Item moved to Trash")).not.toBeInTheDocument();
});

test("Undo highlights the Item even when it isn't back in the list yet", async () => {
  const calls: { cmd: string }[] = backend(configured, {
    items: () => (calls.some((c) => c.cmd === "trash_item") && !calls.some((c) => c.cmd === "restore_item") ? [] : [filed("1", "squat 100", null)]),
  });
  render(<App />);
  await trashOf("squat 100");
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(screen.queryByRole("article")).not.toBeInTheDocument());
  await userEvent.click(screen.getByRole("button", { name: "Undo" }));
  await vi.waitFor(() => expect(screen.getByRole("article")).toHaveClass("is-highlight"));
});

test("a second Move to Trash replaces the Notice, and Undo restores the second Item", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null), filed("2", "bench 70", null)] });
  render(<App />);
  await trashOf("squat 100");
  await trashOf("bench 70");
  expect(screen.getAllByText("Item moved to Trash")).toHaveLength(1);
  await userEvent.click(screen.getByRole("button", { name: "Undo" }));
  expect(calls.filter((c) => c.cmd === "restore_item")).toEqual([{ cmd: "restore_item", args: { itemId: "2" } }]);
});

test("a new Undo Notice gets its own 6 seconds", async () => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  try {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    backend(configured, { items: () => [filed("1", "squat 100", null), filed("2", "bench 70", null)] });
    render(<App />);
    await trashOf("squat 100", user);
    await act(async () => vi.advanceTimersByTime(6000));
    await trashOf("bench 70", user);
    await act(async () => vi.advanceTimersByTime(4000));
    expect(screen.getByText("Item moved to Trash")).toBeInTheDocument();
  } finally {
    vi.useRealTimers();
  }
});

test("⌘Z runs Undo while the Notice shows, but not while typing or after it's gone", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  localStorage.setItem("place", "inbox");
  render(<App />);
  await trashOf("squat 100");
  await screen.findByText("Item moved to Trash");
  await userEvent.type(screen.getByLabelText("New Item"), "abc{Meta>}z{/Meta}");
  expect(calls.some((c) => c.cmd === "restore_item")).toBe(false);
  screen.getByLabelText("New Item").blur();
  await userEvent.keyboard("{Meta>}z{/Meta}");
  expect(calls.filter((c) => c.cmd === "restore_item")).toHaveLength(1);
  await userEvent.keyboard("{Meta>}z{/Meta}");
  expect(calls.filter((c) => c.cmd === "restore_item")).toHaveLength(1);
});

const blur = () => (document.activeElement as HTMLElement | null)?.blur();

test("⌘Z does nothing while search results cover the Notice or a dialog is open", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await trashOf("squat 100");
  await screen.findByText("Item moved to Trash");
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "x");
  await screen.findByText("No Items match.");
  blur();
  await userEvent.keyboard("{Meta>}z{/Meta}");
  expect(calls.some((c) => c.cmd === "restore_item")).toBe(false);
  await userEvent.click(screen.getByRole("textbox", { name: "Search" }));
  await userEvent.keyboard("{Escape}");
  await userEvent.click(screen.getByRole("button", { name: "Settings" }));
  blur();
  await userEvent.keyboard("{Meta>}z{/Meta}");
  expect(calls.some((c) => c.cmd === "restore_item")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
  blur();
  await userEvent.keyboard("{Meta>}z{/Meta}");
  expect(calls.filter((c) => c.cmd === "restore_item")).toHaveLength(1);
});

test("a failed Move to Trash is shown in a dialog, with no Notice", async () => {
  backend(configured, { items: () => [filed("1", "squat 100", null)], failing: { trash_item: "disk full" } });
  render(<App />);
  await trashOf("squat 100");
  expect(await screen.findByRole("alertdialog", { name: "Couldn't move the Item to Trash" })).toHaveTextContent("disk full");
  expect(screen.queryByText("Item moved to Trash")).not.toBeInTheDocument();
});

const editorOf = () => screen.getByRole("textbox", { name: "Edit Item" }).closest(".nb-editor") as HTMLElement;
const openEdit = async (text: string) => {
  const article = (await screen.findByText(text)).closest("article") as HTMLElement;
  await userEvent.click(within(article).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Edit" }));
};

test("Edit opens in place with the composer still there; Shift+Enter adds a line and Enter saves", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  localStorage.setItem("place", "inbox");
  render(<App />);
  await openEdit("squat 100");
  const box = screen.getByRole("textbox", { name: "Edit Item" });
  expect(box).toHaveValue("squat 100");
  expect(box).toHaveFocus();
  expect(screen.getByLabelText("New Item")).toBeVisible();
  await userEvent.type(box, " x5{Shift>}{Enter}{/Shift}felt good{Enter}");
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "squat 100 x5\nfelt good", addIds: [], removeIds: [], baseRev: 0 } });
  await vi.waitFor(() => expect(screen.queryByRole("textbox", { name: "Edit Item" })).not.toBeInTheDocument());
});

test("double-clicking an Item opens Edit, and Escape puts it back unchanged", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await userEvent.dblClick(await screen.findByText("squat 100"));
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), " changed{Escape}");
  expect(calls.some((c) => c.cmd === "edit_item")).toBe(false);
  expect(screen.getByText("squat 100")).toBeInTheDocument();
});

test("Enter while composing text with an input method doesn't save", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await openEdit("squat 100");
  fireEvent.keyDown(screen.getByRole("textbox", { name: "Edit Item" }), { key: "Enter", isComposing: true });
  expect(calls.some((c) => c.cmd === "edit_item")).toBe(false);
});

test("emptying the Item turns Save into Move to Trash, which shows the undo Notice", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)], edited: { trashed: true } });
  render(<App />);
  await openEdit("squat 100");
  await userEvent.clear(screen.getByRole("textbox", { name: "Edit Item" }));
  expect(editorOf()).toHaveClass("is-empty");
  expect(within(editorOf()).getByText("An empty Item goes to Trash.")).toBeInTheDocument();
  expect(within(editorOf()).queryByRole("button", { name: "Save" })).not.toBeInTheDocument();
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Move to Trash" }));
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "", addIds: [], removeIds: [], baseRev: 0 } });
  expect(await screen.findByText("Item moved to Trash")).toBeInTheDocument();
});

test("files can be added, pasted and removed while editing, into the editor and not the composer", async () => {
  const calls = backend(configured, {
    items: () => [{ ...filed("1", "receipt", null), attachments: [report] }],
    picked: { staged: [scan], errors: [] },
    staged: [{ id: "s2", filename: "Pasted image.png", size_bytes: 10, mime_type: "image/png" }],
  });
  render(<App />);
  await openEdit("receipt");
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Attach files" }));
  fireEvent.paste(screen.getByRole("textbox", { name: "Edit Item" }), { clipboardData: { files: [new File(["x"], "")], getData: () => "" } });
  await within(editorOf()).findByText("Pasted image.png");
  expect(within(screen.getByLabelText("New Item").closest("form")!).queryByText("Pasted image.png")).not.toBeInTheDocument();
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Remove report.pdf" }));
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Save" }));
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "receipt", addIds: ["s1", "s2"], removeIds: ["a1"], baseRev: 0 } });
});

test("a mixed paste replaces selected editor text and keeps its image", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [filed("1", "before AFTER after", null)], staged: [scan] });
  render(<App />);
  await openEdit("before AFTER after");
  const box = screen.getByRole("textbox", { name: "Edit Item" }) as HTMLTextAreaElement;
  await user.click(box);
  box.setSelectionRange(7, 12);
  await user.paste({
    files: [new File(["image"], "image.png", { type: "image/png" })],
    getData: (type: string) => type === "text" || type === "text/plain" ? "caption" : "",
  } as unknown as DataTransfer);
  expect(box).toHaveValue("before caption after");
  await within(editorOf()).findByText(scan.filename);
  await user.click(within(editorOf()).getByRole("button", { name: "Save" }));
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "before caption after", addIds: [scan.id], removeIds: [], baseRev: 0 } });
});

test("a refetch while editing doesn't make Save remove the Item's files", async () => {
  const calls = backend(configured, { items: () => [{ ...filed("1", "receipt", null), attachments: [{ ...report }] }] });
  render(<App />);
  await openEdit("receipt");
  await act(() => emit("items-changed"));
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!{Enter}");
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "receipt!", addIds: [], removeIds: [], baseRev: 0 } });
});

test("Enter that confirms an input method's text doesn't save or send", async () => {
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await openEdit("squat 100");
  fireEvent.keyDown(screen.getByRole("textbox", { name: "Edit Item" }), { key: "Enter", keyCode: 229 });
  fireEvent.change(screen.getByLabelText("New Item"), { target: { value: "日本" } });
  fireEvent.keyDown(screen.getByLabelText("New Item"), { key: "Enter", keyCode: 229 });
  expect(calls.some((c) => c.cmd === "edit_item" || c.cmd === "capture")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "New Topic" }));
  fireEvent.change(screen.getByLabelText("Topic name"), { target: { value: "ジム" } });
  fireEvent.keyDown(screen.getByLabelText("Topic name"), { key: "Enter", keyCode: 229 });
  expect(calls.some((c) => c.cmd === "picker_topic")).toBe(false);
});

test("Cancel unstages the files added in the editor", async () => {
  const calls = backend(configured, { items: () => [filed("1", "receipt", null)], picked: { staged: [scan], errors: [] } });
  render(<App />);
  await openEdit("receipt");
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Attach files" }));
  await within(editorOf()).findByText("scan.png");
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Cancel" }));
  expect(calls).toContainEqual({ cmd: "unstage_attachment", args: { id: "s1" } });
});

test("a failed save keeps the editor open with the reason", async () => {
  backend(configured, { items: () => [filed("1", "squat 100", null)], failing: { edit_item: "That's too long to save (1 MB max)" } });
  render(<App />);
  await openEdit("squat 100");
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!{Enter}");
  expect(await within(editorOf()).findByRole("alert")).toHaveTextContent("Couldn't save the edit. Your changes are kept. That's too long to save (1 MB max)");
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("squat 100!");
});

test("an Item deleted elsewhere shows the Error dialog and the text stays in the editor", async () => {
  let items = [filed("1", "squat 100", null)];
  backend(configured, { items: () => items, failing: { edit_item: "That Item no longer exists" } });
  render(<App />);
  await openEdit("squat 100");
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), " kept");
  items = [];
  await act(() => emit("items-changed"));
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Save" }));
  const dialog = await screen.findByRole("alertdialog", { name: "Couldn't save the edit" });
  expect(dialog).toHaveTextContent("That Item no longer exists");
  await userEvent.click(within(dialog).getByRole("button", { name: "OK" }));
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("squat 100 kept");
});

test("an editor keeps the base it opened with when the Feed reloads under it", async () => {
  let base = 3;
  const calls = backend(configured, { items: () => [{ ...filed("1", "squat 100", null), edit_base: base }] });
  render(<App />);
  await openEdit("squat 100");
  base = 4;
  await act(() => emit("items-changed"));
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!{Enter}");
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "squat 100!", addIds: [], removeIds: [], baseRev: 3 } });
});

test("opening Edit on a second Item saves the first, unless that save fails", async () => {
  const failing: Record<string, string> = {};
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null), filed("2", "bench 70", null)], failing });
  render(<App />);
  await openEdit("squat 100");
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!");
  await userEvent.dblClick(screen.getByText("bench 70"));
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "squat 100!", addIds: [], removeIds: [], baseRev: 0 } });
  await vi.waitFor(() => expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("bench 70"));

  failing.edit_item = "disk full";
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!");
  await userEvent.dblClick(screen.getByText("squat 100"));
  expect(await within(editorOf()).findByRole("alert")).toHaveTextContent("disk full");
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("bench 70!");
});

test("switching views saves the open edit, and stays put if that save fails", async () => {
  const failing: Record<string, string> = {};
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null)], failing });
  render(<App />);
  await openEdit("squat 100");
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!");
  failing.edit_item = "disk full";
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  expect(await within(editorOf()).findByRole("alert")).toHaveTextContent("disk full");
  expect(screen.getByRole("button", { name: "All Items" })).toHaveAttribute("aria-current", "page");
  delete failing.edit_item;
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  expect(calls.filter((c) => c.cmd === "edit_item")).toEqual(Array(2).fill({ cmd: "edit_item", args: { itemId: "1", text: "squat 100!", addIds: [], removeIds: [], baseRev: 0 } }));
  await vi.waitFor(() => expect(screen.getByRole("button", { name: /^Inbox/ })).toHaveAttribute("aria-current", "page"));
  expect(screen.queryByRole("textbox", { name: "Edit Item" })).not.toBeInTheDocument();
});

test("Items in an archived Topic can be edited and moved to Trash", async () => {
  backend(configured, { topics: [topic("o", "Old", { archived: true, item_count: 1 })], items: () => [filed("1", "old note", "o")] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Archived 1" }));
  await userEvent.click(screen.getByRole("button", { name: "Old" }));
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  expect(screen.getByRole("menuitem", { name: "Edit" })).toBeInTheDocument();
  expect(screen.getByRole("menuitem", { name: "Move to Trash" })).toBeInTheDocument();
});

const DAY_MS = 86_400_000;
const inTrash = (it: FeedItem, daysLeft: number | null): FeedItem => ({
  ...it,
  purge_at_us: daysLeft === null ? null : (Date.now() + daysLeft * DAY_MS - 60_000) * 1000,
});
const rowOf = (text: string) => screen.getByText(text).closest("article") as HTMLElement;

test("Trash groups deleted Items under days remaining, soonest first, with where Restore puts them and no menu or editing", async () => {
  const calls = backend(configured, {
    topics: [topic("g", "Gym")],
    items: ({ view }) =>
      view.kind === "trash"
        ? [{ ...inTrash(filed("3", "just now", null), null), pending: true }, inTrash(filed("1", "old shoe sizes", "g"), 15), inTrash(filed("4", "socks", null), 15), inTrash(filed("2", "deadlift", null), 1)]
        : [],
  });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Trash/ }));
  await screen.findByText("old shoe sizes");
  expect(screen.getAllByRole("separator").map((s) => s.textContent)).toEqual(["1 day remaining", "15 days remaining", "Waiting for sync"]);
  expect(screen.getAllByRole("article").map((a) => a.querySelector(".nb-item-text")?.textContent)).toEqual(["deadlift", "socks", "old shoe sizes", "just now"]);
  expect(within(rowOf("old shoe sizes")).getByText("Gym")).toBeInTheDocument();
  expect(within(rowOf("deadlift")).getByText("Inbox")).toBeInTheDocument();
  expect(within(rowOf("deadlift")).queryByText(/left$/)).not.toBeInTheDocument();
  expect(within(rowOf("just now")).getByLabelText("Not synced yet")).toBeInTheDocument();
  expect(rowOf("old shoe sizes").querySelector("time")).toBeNull();
  expect(screen.queryByRole("button", { name: "Item actions" })).not.toBeInTheDocument();
  await userEvent.dblClick(screen.getByText("deadlift"));
  expect(screen.queryByRole("textbox", { name: "Edit Item" })).not.toBeInTheDocument();
  expect(screen.getByText("Items in Trash are deleted for good after 30 days.")).toBeInTheDocument();
  expect(screen.getByLabelText("New Item")).not.toBeVisible();
  expect(calls).toContainEqual({ cmd: "list_items", args: { view: { kind: "trash" }, before: null } });
});

test("an empty Trash says so", async () => {
  backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Trash/ }));
  expect(await screen.findByText("Trash is empty.")).toBeInTheDocument();
  expect(screen.getByText("Deleted Items stay here for 30 days.")).toBeInTheDocument();
});

test("Restore puts the Item back, and Show opens its Topic with it highlighted even pages back", async () => {
  const old = filed("x", "old shoe sizes", "g");
  const page = (day: number, prefix: string) => Array.from({ length: 100 }, (_, i) => feedItem(`${prefix}${i}`, `${prefix} ${i}`, at(2026, 10, day, 10, 0) - i));
  const calls = backend(configured, {
    topics: [topic("g", "Gym")],
    items: ({ view, before }) =>
      view.kind === "trash" ? [inTrash(old, 15)] : before === null ? page(16, "new") : before.id === "new99" ? page(15, "mid") : [old],
  });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Trash/ }));
  await screen.findByText("old shoe sizes");
  await userEvent.click(within(rowOf("old shoe sizes")).getByRole("button", { name: "Restore" }));
  expect(calls).toContainEqual({ cmd: "restore_item", args: { itemId: "x" } });
  await screen.findByText("Restored to Gym");
  await userEvent.click(screen.getByRole("button", { name: "Show" }));
  expect(screen.getByRole("button", { name: "Gym" })).toHaveAttribute("aria-current", "page");
  await vi.waitFor(() => expect(rowOf("old shoe sizes")).toHaveClass("is-highlight"));
});

test("a failed restore is shown in a dialog", async () => {
  backend(configured, { items: ({ view }) => (view.kind === "trash" ? [inTrash(filed("1", "gone", null), 3)] : []), failing: { restore_item: "That Item no longer exists" } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Trash/ }));
  await screen.findByText("gone");
  await userEvent.click(within(rowOf("gone")).getByRole("button", { name: "Restore" }));
  expect(await screen.findByRole("alertdialog", { name: "Couldn't restore the Item" })).toHaveTextContent("That Item no longer exists");
});

test("a drop in Trash attaches nothing and shows no drop target", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Trash/ }));
  await act(() => emit("attachments-staged", { staged: [scan], errors: [] }));
  expect(calls).toContainEqual({ cmd: "unstage_attachment", args: { id: "s1" } });
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  expect(screen.queryByText("scan.png")).not.toBeInTheDocument();
});

test("Inbox and Trash show counts, refetched when items change, and Trash stays selected", async () => {
  let counts = { inbox: 17, tunnel: 0, trash: 3 };
  backend(configured, { counts: () => counts });
  render(<App />);
  expect(within(await screen.findByRole("button", { name: /^Inbox/ })).getByText("17")).toBeInTheDocument();
  const trash = screen.getByRole("button", { name: /^Trash/ });
  expect(within(trash).getByText("3")).toBeInTheDocument();
  await userEvent.click(trash);
  counts = { inbox: 16, tunnel: 0, trash: 4 };
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(within(screen.getByRole("button", { name: /^Trash/ })).getByText("4")).toBeInTheDocument());
  expect(screen.getByRole("button", { name: /^Trash/ })).toHaveAttribute("aria-current", "page");
});

const found = (it: FeedItem, marked_text = it.text, marked_filenames = it.attachments.map((a) => a.filename)): SearchItem => ({ ...it, marked_text, marked_filenames });
const feedHidden = () => screen.getByTestId("feed-items").closest("main")!.getAttribute("aria-hidden") === "true";
// The results stay mounted, hidden, after one opens, so look only in the Feed.
const feedRow = (text: string) => within(screen.getByTestId("feed-items")).getByText(text).closest("article") as HTMLElement;
const searchCalls = (calls: { cmd: string; args: any }[]) => calls.filter((c) => c.cmd === "search_items");

test("typing in Search shows marked results over the Feed, and Esc brings the Feed back", async () => {
  const calls = backend(configured, {
    items: () => [feedItem("1", "in the feed", at(2026, 10, 14, 9, 41))],
    search: () => [found(feedItem("2", "paid the invoice", at(2026, 10, 3, 14, 2)), "paid the \uE000invoice\uE001")],
  });
  render(<App />);
  await screen.findByText("in the feed");
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "invoice");
  expect(await screen.findByRole("heading", { name: 'Results for "invoice"' })).toBeInTheDocument();
  const result = await screen.findByRole("button", { name: /paid the invoice/ });
  expect(within(result).getByText("invoice", { selector: "mark" })).toBeInTheDocument();
  expect(within(result).getByText("Inbox")).toBeInTheDocument();
  expect(feedHidden()).toBe(true);
  expect(searchCalls(calls)).toEqual([
    { cmd: "search_items", args: { query: { text: "invoice", place: { kind: "all" }, from_us: null, to_us: null, has_files: false }, before: null } },
  ]);
  await userEvent.keyboard("{Escape}");
  expect(feedHidden()).toBe(false);
  expect(screen.getByRole("textbox", { name: "Search" })).toHaveValue("");
});

test("Clear search empties the field, and a field of spaces doesn't search", async () => {
  const calls = backend(configured, { items: () => [feedItem("1", "in the feed", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  await screen.findByText("in the feed");
  const field = screen.getByRole("textbox", { name: "Search" });
  await userEvent.type(field, "   ");
  await new Promise((r) => setTimeout(r, 300));
  expect(searchCalls(calls)).toEqual([]);
  expect(feedHidden()).toBe(false);
  await userEvent.type(field, "x");
  expect(await screen.findByText("No Items match.")).toBeInTheDocument();
  expect(feedHidden()).toBe(true);
  await userEvent.click(screen.getByRole("button", { name: "Clear search" }));
  expect(field).toHaveValue("");
  expect(feedHidden()).toBe(false);
});

test("⌘F focuses Search", async () => {
  backend(configured);
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  await userEvent.keyboard("{Meta>}f{/Meta}");
  expect(field).toHaveFocus();
});

test("⌘F does nothing while a dialog is open", async () => {
  backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  blur();
  await userEvent.keyboard("{Meta>}f{/Meta}");
  expect(screen.getByRole("textbox", { name: "Search" })).not.toHaveFocus();
});

test("Clear search leaves focus in the field, even though WebKit doesn't focus a clicked button", async () => {
  backend(configured);
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  await userEvent.type(field, "x");
  blur();
  fireEvent.click(screen.getByRole("button", { name: "Clear search" }));
  expect(field).toHaveFocus();
});

test("Esc in Search puts focus back into an open edit", async () => {
  backend(configured, { items: () => [feedItem("1", "draft me", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  fireEvent.doubleClick(await screen.findByText("draft me"));
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "zz{Escape}");
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveFocus();
});

test("an open edit survives a search and is still there after Esc", async () => {
  backend(configured, { items: () => [feedItem("1", "draft me", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  fireEvent.doubleClick(await screen.findByText("draft me"));
  const editor = screen.getByRole("textbox", { name: "Edit Item" });
  await userEvent.type(editor, " more");
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "zz{Escape}");
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("draft me more");
});

test("typing quickly sends one search, and a slow earlier answer never replaces a newer one", async () => {
  let release!: () => void;
  const slow = new Promise<void>((resolve) => (release = resolve));
  const calls = backend(configured, {
    search: async ({ query }) => {
      if (query.text === "old") {
        await slow;
        return [found(feedItem("o", "stale answer", 1))];
      }
      return [found(feedItem("n", "fresh answer", 2))];
    },
  });
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  await userEvent.type(field, "old");
  await vi.waitFor(() => expect(searchCalls(calls)).toHaveLength(1));
  await userEvent.type(field, "er");
  expect(await screen.findByText("fresh answer")).toBeInTheDocument();
  await act(async () => release());
  expect(screen.queryByText("stale answer")).not.toBeInTheDocument();
  expect(searchCalls(calls).map((c) => c.args.query.text)).toEqual(["old", "older"]);
});

test("Search waits while an input method is composing, and its Esc doesn't clear", async () => {
  const calls = backend(configured);
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  fireEvent.compositionStart(field);
  fireEvent.change(field, { target: { value: "jie" } });
  await new Promise((r) => setTimeout(r, 300));
  expect(searchCalls(calls)).toEqual([]);
  fireEvent.change(field, { target: { value: "截" } });
  fireEvent.compositionEnd(field);
  await vi.waitFor(() => expect(searchCalls(calls).map((c) => c.args.query.text)).toEqual(["截"]));
  fireEvent.keyDown(field, { key: "Escape", keyCode: 229 });
  expect(field).toHaveValue("截");
});

test("results follow changes from sync", async () => {
  let answer: SearchItem[] = [found(feedItem("1", "soon trashed", 1))];
  backend(configured, { search: () => answer });
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "soon");
  await screen.findByText("soon trashed");
  answer = [];
  await act(() => emit("items-changed"));
  expect(await screen.findByText("No Items match.")).toBeInTheDocument();
});

test("a failed search shows the reason under the heading and keeps the text", async () => {
  backend(configured, { failing: { search_items: "database is locked" } });
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  await userEvent.type(field, "x");
  expect(await screen.findByRole("alert")).toHaveTextContent("Couldn't search. database is locked");
  expect(field).toHaveValue("x");
});

const pick = async (filter: string, choice: string) => {
  await userEvent.click(await screen.findByRole("button", { name: filter }));
  await userEvent.click(within(screen.getByRole("menu", { name: filter })).getByRole("menuitemradio", { name: choice }));
};
const lastQuery = (calls: { cmd: string; args: any }[]) => {
  const all = searchCalls(calls);
  return all[all.length - 1].args.query;
};

test("the place filter lists Inbox, open Topics, then archived ones, and narrows the search", async () => {
  const calls = backend(configured, { topics: [topic("t", "Taxes"), topic("o", "Old", { archived: true })] });
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
  const place = await screen.findByRole("button", { name: "Place" });
  expect(place).toHaveTextContent("Anywhere");
  await userEvent.click(place);
  const menu = screen.getByRole("menu", { name: "Place" });
  expect(within(menu).getAllByRole("menuitemradio").map((o) => o.textContent)).toEqual(["Anywhere", "Inbox", "Tunnel", "Taxes", "Old"]);
  expect(within(menu).getByText("Archived")).toBeInTheDocument();
  await userEvent.click(within(menu).getByRole("menuitemradio", { name: "Old" }));
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "topic", id: "o" }));
  expect(place).toHaveTextContent("Old");
  await pick("Place", "Inbox");
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "inbox" }));
});

test("a new search starts in the open Place and keeps its filter until the text is cleared", async () => {
  const calls = backend(configured, { topics: [topic("t", "Taxes")] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Taxes" }));
  const field = screen.getByRole("textbox", { name: "Search" });
  await userEvent.type(field, "note");
  expect(await screen.findByRole("button", { name: "Place" })).toHaveTextContent("Taxes");
  await vi.waitFor(() => expect(searchCalls(calls).length).toBeGreaterThan(0));
  expect(searchCalls(calls).map((c) => c.args.query.place)).toEqual(searchCalls(calls).map(() => ({ kind: "topic", id: "t" })));

  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  await userEvent.click(field);
  expect(screen.getByRole("button", { name: "Place" })).toHaveTextContent("Taxes");

  await userEvent.clear(field);
  await userEvent.type(field, "note");
  expect(await screen.findByRole("button", { name: "Place" })).toHaveTextContent("Inbox");
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "inbox" }));
});

test.each(["All Items", "Trash"])("a search from %s starts Anywhere", async (name) => {
  const calls = backend(configured, { topics: [topic("t", "Taxes")] });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Taxes" }));
  await userEvent.click(screen.getByRole("button", { name: new RegExp(`^${name}`) }));
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "note");
  expect(await screen.findByRole("button", { name: "Place" })).toHaveTextContent("Anywhere");
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "all" }));
});

test("date presets search back from now, and Has files narrows to Items with files", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
  const before = Date.now();
  await pick("Date", "Past week");
  await vi.waitFor(() => expect(lastQuery(calls).from_us).not.toBeNull());
  const weekAgo = new Date(before);
  weekAgo.setDate(weekAgo.getDate() - 7);
  expect(Math.abs(lastQuery(calls).from_us / 1000 - weekAgo.getTime())).toBeLessThan(5000);
  expect(lastQuery(calls).to_us).toBeNull();
  const hasFiles = screen.getByRole("button", { name: "Has files" });
  expect(hasFiles).toHaveAttribute("aria-pressed", "false");
  await userEvent.click(hasFiles);
  await vi.waitFor(() => expect(lastQuery(calls).has_files).toBe(true));
  expect(hasFiles).toHaveAttribute("aria-pressed", "true");
});

test("a custom range covers whole local days, even across a clock change", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
  await pick("Date", "Custom…");
  fireEvent.change(screen.getByLabelText("From"), { target: { value: "2026-11-01" } });
  fireEvent.change(screen.getByLabelText("To"), { target: { value: "2026-11-01" } });
  await vi.waitFor(() => expect(lastQuery(calls).to_us).not.toBeNull());
  const { from_us, to_us } = lastQuery(calls);
  expect(from_us).toBe(new Date(2026, 10, 1).getTime() * 1000);
  // Daylight saving ends that night in Los Angeles, so the day is 25 hours long.
  expect(to_us - from_us).toBe(25 * 60 * 60 * 1_000_000);
});

test("with filters set, no results offers Clear filters, which resets them", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
  await screen.findByText("No Items match.");
  expect(screen.queryByRole("button", { name: "Clear filters" })).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Has files" }));
  await userEvent.click(await screen.findByRole("button", { name: "Clear filters" }));
  await vi.waitFor(() => expect(lastQuery(calls)).toEqual({ text: "note", place: { kind: "all" }, from_us: null, to_us: null, has_files: false }));
  expect(screen.getByRole("button", { name: "Has files" })).toHaveAttribute("aria-pressed", "false");
});

test("a Topic chosen as the place that's deleted elsewhere falls back to Anywhere", async () => {
  const topics = [topic("t", "Taxes")];
  const calls = backend(configured, { topics });
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
  await pick("Place", "Taxes");
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "topic", id: "t" }));
  topics.splice(0);
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "all" }));
  expect(screen.getByRole("button", { name: "Place" })).toHaveTextContent("Anywhere");
});

test("opening a result shows it highlighted in its Topic even pages back, and the field brings the results back", async () => {
  const old = filed("x", "the invoice", "g");
  const page = (day: number, prefix: string) => Array.from({ length: 100 }, (_, i) => feedItem(`${prefix}${i}`, `${prefix} ${i}`, at(2026, 10, day, 10, 0) - i));
  backend(configured, {
    topics: [topic("g", "Gym")],
    items: ({ before }) => (before === null ? page(16, "new") : before.id === "new99" ? page(15, "mid") : before.id === "mid99" ? [old] : []),
    search: () => [found(old)],
  });
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  await userEvent.type(field, "invoice");
  await userEvent.click(await screen.findByRole("button", { name: /the invoice/ }));
  expect(screen.getByRole("button", { name: "Gym" })).toHaveAttribute("aria-current", "page");
  await vi.waitFor(() => expect(feedRow("the invoice")).toHaveClass("is-highlight"));
  expect(field).toHaveValue("invoice");
  expect(screen.queryByRole("heading", { name: 'Results for "invoice"' })).not.toBeInTheDocument();
  await userEvent.click(field);
  expect(screen.getByRole("heading", { name: 'Results for "invoice"' })).toBeInTheDocument();
});

test("a result in an archived Topic opens that Topic", async () => {
  const it = filed("x", "kept note", "o");
  backend(configured, { topics: [topic("o", "Old", { archived: true })], items: ({ view }) => (view.kind === "topic" ? [it] : []), search: () => [found(it)] });
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "kept");
  await userEvent.click(await screen.findByRole("button", { name: /kept note/ }));
  expect(screen.getByRole("button", { name: "Old" })).toHaveAttribute("aria-current", "page");
  await vi.waitFor(() => expect(feedRow("kept note")).toHaveClass("is-highlight"));
});

test("opening a result saves the open edit first, and shows the editor's error if that save fails", async () => {
  const it = feedItem("1", "draft me", at(2026, 10, 14, 9, 41));
  const calls = backend(configured, { items: () => [it], search: () => [found(feedItem("2", "elsewhere", 1))], failing: { edit_item: "disk full" } });
  render(<App />);
  fireEvent.doubleClick(await screen.findByText("draft me"));
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), " more");
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "else");
  await userEvent.click(await screen.findByRole("button", { name: /elsewhere/ }));
  expect(calls.some((c) => c.cmd === "edit_item")).toBe(true);
  expect(await screen.findByText(/Couldn't save the edit\. Your changes are kept\. disk full/)).toBeInTheDocument();
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("draft me more");
  expect(screen.queryByRole("heading", { name: 'Results for "else"' })).not.toBeInTheDocument();
});

test("scrolling to the end of the results loads the next page", async () => {
  const many = Array.from({ length: 100 }, (_, i) => found(feedItem(`n${i}`, `note ${i}`, 1000 - i)));
  const calls = backend(configured, { search: ({ before }) => (before === null ? many : before.id === "n99" ? [found(feedItem("last", "the last note", 1))] : []) });
  render(<App />);
  await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
  await screen.findByText("note 0");
  fireEvent.scroll(screen.getByTestId("results"));
  expect(await screen.findByText("the last note")).toBeInTheDocument();
  expect(searchCalls(calls).some((c) => c.args.before?.id === "n99")).toBe(true);
});

test("hidden results don't search on every sync, and catch up when shown again", async () => {
  const it = feedItem("1", "found note", at(2026, 10, 14, 9, 41));
  const calls = backend(configured, { items: () => [it], search: () => [found(it)] });
  render(<App />);
  const field = await screen.findByRole("textbox", { name: "Search" });
  await userEvent.type(field, "found");
  await userEvent.click(await screen.findByRole("button", { name: /found note/ }));
  const before = searchCalls(calls).length;
  await act(() => emit("items-changed"));
  await new Promise((r) => setTimeout(r, 300));
  expect(searchCalls(calls)).toHaveLength(before);
  await userEvent.click(field);
  await vi.waitFor(() => expect(searchCalls(calls)).toHaveLength(before + 1));
});

test("Past month and Past year on a day the earlier month lacks end on that month's last day", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2028, 2, 31, 12, 0));
  try {
    const calls = backend(configured);
    render(<App />);
    await userEvent.type(await screen.findByRole("textbox", { name: "Search" }), "note");
    await pick("Date", "Past month");
    await vi.waitFor(() => expect(lastQuery(calls).from_us).toBe(new Date(2028, 1, 29, 12, 0).getTime() * 1000));
    vi.setSystemTime(new Date(2028, 1, 29, 12, 0));
    await pick("Date", "Past year");
    await vi.waitFor(() => expect(lastQuery(calls).from_us).toBe(new Date(2027, 1, 28, 12, 0).getTime() * 1000));
  } finally {
    vi.useRealTimers();
  }
});

test("a submenu opened by hovering closes when the pointer leaves it", async () => {
  backend(configured, { topics: [topic("t", "Taxes")], items: () => [feedItem("1", "hello", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  await screen.findByText("hello");
  await userEvent.click(screen.getByRole("button", { name: "Item actions" }));
  const moveTo = screen.getByRole("menuitem", { name: "Move to" });
  await userEvent.hover(moveTo);
  expect(screen.getByRole("menu", { name: "Move to" })).toBeInTheDocument();
  await userEvent.unhover(moveTo);
  await vi.waitFor(() => expect(screen.queryByRole("menu", { name: "Move to" })).not.toBeInTheDocument());
  expect(screen.getByRole("menu", { name: "Item actions" })).toBeInTheDocument();
});

test("heading toward the Move to submenu keeps it open even across other rows; pausing or backing off closes it", async () => {
  backend(configured, { topics: [topic("t", "Taxes")], items: () => [feedItem("1", "hello", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  await screen.findByText("hello");
  await userEvent.click(screen.getByRole("button", { name: "Item actions" }));
  const moveTo = screen.getByRole("menuitem", { name: "Move to" });
  const open = async () => {
    await userEvent.hover(moveTo);
    const sub = screen.getByRole("menu", { name: "Move to" });
    // Opened upward and to the left: near edge x = 100, bottom just 5 px below the Move to row.
    vi.spyOn(sub, "getBoundingClientRect").mockReturnValue({ left: 0, right: 100, top: 0, bottom: 200, x: 0, y: 0, width: 100, height: 200, toJSON: () => ({}) });
  };
  const subOpen = () => screen.queryByRole("menu", { name: "Move to" }) !== null;
  const wrap = moveTo.parentElement!;
  const copyText = screen.getByRole("menuitem", { name: "Copy text" });
  const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

  await open();
  fireEvent.mouseLeave(wrap, { clientX: 250, clientY: 195, relatedTarget: copyText });
  fireEvent.mouseMove(copyText, { clientX: 200, clientY: 205 });
  await pause(250);
  fireEvent.mouseMove(copyText, { clientX: 150, clientY: 210 });
  await pause(250);
  expect(subOpen()).toBe(true);
  await userEvent.hover(within(screen.getByRole("menu", { name: "Move to" })).getByRole("menuitemradio", { name: "Taxes" }));
  await pause(500);
  expect(subOpen()).toBe(true);

  await open();
  fireEvent.mouseLeave(wrap, { clientX: 250, clientY: 195, relatedTarget: copyText });
  fireEvent.mouseMove(copyText, { clientX: 200, clientY: 205 });
  await vi.waitFor(() => expect(subOpen()).toBe(false));

  await open();
  fireEvent.mouseLeave(wrap, { clientX: 250, clientY: 195, relatedTarget: copyText });
  fireEvent.mouseMove(copyText, { clientX: 248, clientY: 205 });
  fireEvent.mouseMove(copyText, { clientX: 251, clientY: 215 });
  expect(subOpen()).toBe(false);
});

const openSettings = async () => userEvent.click(await screen.findByRole("button", { name: "Settings" }));
const recorder = () => screen.getByRole("button", { name: /^Quick capture shortcut/ });

test("the quick-capture shortcut shows in Mac symbols on a Mac", async () => {
  const mac = vi.spyOn(navigator, "userAgent", "get").mockReturnValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)");
  try {
    backend(configured);
    render(<App />);
    await openSettings();
    expect(recorder()).toHaveTextContent("⇧⌘Space");
  } finally {
    mac.mockRestore();
  }
});

test("the shortcut shows as text elsewhere", async () => {
  backend(configured);
  render(<App />);
  await openSettings();
  expect(recorder()).toHaveTextContent("Shift+Win+Space");
});

test("recording a shortcut applies it at once, from the key's code", async () => {
  const calls = backend(configured);
  render(<App />);
  await openSettings();
  expect(recorder()).toHaveAttribute("aria-pressed", "false");
  await userEvent.click(recorder());
  expect(recorder()).toHaveTextContent("Press a shortcut… (Esc cancels)");
  expect(recorder()).toHaveAttribute("aria-pressed", "true");
  fireEvent.keyDown(recorder(), { key: "Control", code: "ControlLeft", ctrlKey: true });
  expect(recorder()).toHaveTextContent("Press a shortcut…");
  fireEvent.keyDown(recorder(), { key: "˚", code: "KeyK", ctrlKey: true, altKey: true });
  await vi.waitFor(() => expect(recorder()).toHaveTextContent("Ctrl+Alt+K"));
  expect(recorder()).toHaveAttribute("aria-pressed", "false");
  expect(calls.filter((c) => c.cmd === "set_quick_capture_shortcut").map((c) => c.args)).toEqual([{ shortcut: "Control+Alt+KeyK" }]);
});

test("recording hears the keys even though WebKit doesn't focus a clicked button", async () => {
  const calls = backend(configured);
  render(<App />);
  await openSettings();
  fireEvent.click(recorder());
  fireEvent.keyDown(document.activeElement!, { key: "k", code: "KeyK", ctrlKey: true, altKey: true });
  await vi.waitFor(() => expect(calls.some((c) => c.cmd === "set_quick_capture_shortcut")).toBe(true));
});

test("Escape stops recording without closing Settings or changing anything", async () => {
  const calls = backend(configured);
  render(<App />);
  await openSettings();
  await userEvent.click(recorder());
  fireEvent.keyDown(recorder(), { key: "Escape", code: "Escape" });
  expect(recorder()).toHaveTextContent("Shift+Win+Space");
  expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument();
  expect(calls.some((c) => c.cmd === "set_quick_capture_shortcut")).toBe(false);
});

test("a shortcut that can't be used shows why and keeps the old one", async () => {
  backend(configured, { shortcutError: "Couldn't use this shortcut: taken" });
  render(<App />);
  await openSettings();
  await userEvent.click(recorder());
  fireEvent.keyDown(recorder(), { key: "k", code: "KeyK", ctrlKey: true, altKey: true });
  expect(await screen.findByText("Couldn't use this shortcut: taken")).toBeInTheDocument();
  expect(recorder()).toHaveTextContent("Shift+Win+Space");
});

const quickSwitch = () => screen.getByRole("switch", { name: "Quick capture on" });
const turnedOff = { ...configured, quick_capture: { shortcut: "shift+super+Space", on: false } };

test("the switch turns quick capture off and on, keeping the shortcut", async () => {
  const calls = backend(configured);
  render(<App />);
  await openSettings();
  expect(quickSwitch()).toBeChecked();
  await userEvent.click(quickSwitch());
  await vi.waitFor(() => expect(quickSwitch()).not.toBeChecked());
  expect(recorder()).toHaveTextContent("Shift+Win+Space");
  await userEvent.click(quickSwitch());
  await vi.waitFor(() => expect(quickSwitch()).toBeChecked());
  expect(calls.filter((c) => c.cmd === "set_quick_capture_on").map((c) => c.args)).toEqual([{ on: false }, { on: true }]);
  expect(calls.some((c) => c.cmd === "set_quick_capture_shortcut")).toBe(false);
});

test("turning on a shortcut that's taken says why and stays off", async () => {
  backend(turnedOff, { shortcutError: "Couldn't use this shortcut: taken" });
  render(<App />);
  await openSettings();
  await userEvent.click(quickSwitch());
  expect(await screen.findByText("Couldn't use this shortcut: taken")).toBeInTheDocument();
  expect(quickSwitch()).not.toBeChecked();
});

test("recording a shortcut while off saves it and stays off", async () => {
  const calls = backend(turnedOff);
  render(<App />);
  await openSettings();
  await userEvent.click(recorder());
  fireEvent.keyDown(recorder(), { key: "k", code: "KeyK", ctrlKey: true, altKey: true });
  await vi.waitFor(() => expect(recorder()).toHaveTextContent("Ctrl+Alt+K"));
  expect(quickSwitch()).not.toBeChecked();
  expect(calls.some((c) => c.cmd === "set_quick_capture_on")).toBe(false);
});

test("the shortcut row is on the first-launch page too", async () => {
  backend({ server_url: null, has_secret: false });
  render(<App />);
  await screen.findByRole("heading", { name: "Settings" });
  expect(recorder()).toBeInTheDocument();
});

const loginSwitch = () => screen.getByRole("switch", { name: "Open at login" });

test("Open at login shows the OS's state and changes it", async () => {
  const calls = backend(configured, { autostart: false });
  render(<App />);
  await openSettings();
  await vi.waitFor(() => expect(loginSwitch()).toBeEnabled());
  expect(loginSwitch()).not.toBeChecked();
  await userEvent.click(loginSwitch());
  await vi.waitFor(() => expect(loginSwitch()).toBeChecked());
  expect(calls.filter((c) => c.cmd === "set_autostart").map((c) => c.args)).toEqual([{ on: true }]);
});

test("Open at login that the OS refuses says why and shows the real state", async () => {
  backend(configured, { autostart: false, failing: { set_autostart: "Couldn't change Open at login: denied" } });
  render(<App />);
  await openSettings();
  await vi.waitFor(() => expect(loginSwitch()).toBeEnabled());
  await userEvent.click(loginSwitch());
  expect(await screen.findByText("Couldn't change Open at login: denied")).toBeInTheDocument();
  expect(loginSwitch()).not.toBeChecked();
});

test("the first-launch page has no Open at login switch", async () => {
  const calls = backend({ server_url: null, has_secret: false });
  render(<App />);
  await screen.findByRole("heading", { name: "Settings" });
  expect(screen.queryByRole("switch", { name: "Open at login" })).toBeNull();
  expect(calls.some((c) => c.cmd === "autostart_on")).toBe(false);
});

const refused = (id: string, text: string | null, reason = "invalid"): FeedItem => ({ ...feedItem(id, text as string, at(2026, 10, 14, 9, 41)), sync_error: reason });
const conflicted = (id: string, row: string | null, other: string | null, mine: boolean): FeedItem => ({
  ...feedItem(id, row as string, at(2026, 10, 14, 9, 41)),
  conflict: { text: other, mine },
});
const menuOf = async (text: string) => {
  await userEvent.click(within(rowOf(text)).getByRole("button", { name: "Item actions" }));
  return screen.getByRole("menu", { name: "Item actions" });
};

test("a refused Capture shows Couldn't sync with the reason, and has no grip or double-click edit", async () => {
  backend(configured, { items: () => [refused("1", "bad one"), refused("2", "dup one", "exists"), refused("3", "odd one", "too_big")] });
  render(<App />);
  await screen.findByText("bad one");
  const mark = (t: string) => within(rowOf(t)).getByText("Couldn't sync").closest(".nb-mark")!;
  expect(mark("bad one")).toHaveAttribute("title", "The Server refused this Item as invalid. It's only on this Device.");
  expect(mark("dup one")).toHaveAttribute("title", "The Server already has an Item with this id. It's only on this Device.");
  expect(mark("odd one")).toHaveAttribute("title", "The Server refused this Item (too_big). It's only on this Device.");
  expect(within(rowOf("bad one")).queryByTitle("Drag to a Topic")).toBeNull();
  fireEvent.doubleClick(rowOf("bad one"));
  expect(screen.queryByRole("textbox", { name: "Edit Item" })).toBeNull();
});

test("a refused Capture's menu is Copy text and Discard… only", async () => {
  backend(configured, { items: () => [refused("1", "bad one")] });
  render(<App />);
  await screen.findByText("bad one");
  const menu = await menuOf("bad one");
  expect(within(menu).getAllByRole("menuitem").map((m) => m.textContent)).toEqual(["Copy text", "Discard…"]);
});

test("Discard… asks first; Cancel does nothing, Discard calls discard_item", async () => {
  const calls = backend(configured, { items: () => [refused("1", "bad one")] });
  render(<App />);
  await screen.findByText("bad one");
  await userEvent.click(within(await menuOf("bad one")).getByRole("menuitem", { name: "Discard…" }));
  const dialog = screen.getByRole("alertdialog", { name: "Discard this Item?" });
  await userEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("alertdialog")).toBeNull();
  expect(calls.some((c) => c.cmd === "discard_item")).toBe(false);
  await userEvent.click(within(await menuOf("bad one")).getByRole("menuitem", { name: "Discard…" }));
  fireEvent.click(within(screen.getByRole("alertdialog", { name: "Discard this Item?" })).getByRole("button", { name: "Discard" }));
  await vi.waitFor(() => expect(calls.filter((c) => c.cmd === "discard_item").map((c) => c.args)).toEqual([{ itemId: "1" }]));
});

test("a conflicted Item shows a Conflict button that opens both versions, footers placed by who is on the Server", async () => {
  backend(configured, { items: () => [conflicted("1", "server text", "my text", true), conflicted("2", "my row", "server other", false)] });
  render(<App />);
  await screen.findByText("server text");
  fireEvent.click(within(rowOf("server text")).getByRole("button", { name: "Conflict" }));
  const dialog = screen.getByRole("dialog", { name: "This Item was edited on two Devices" });
  expect(dialog).toHaveTextContent("Both edits started from the same text. Choose which one to keep. The other is discarded.");
  const theirs = within(dialog).getByRole("group", { name: "Theirs" });
  const mine = within(dialog).getByRole("group", { name: "Mine" });
  expect(theirs).toHaveTextContent("another Device");
  expect(theirs).toHaveTextContent("server text");
  expect(theirs).toHaveTextContent("Showing on all Devices");
  expect(mine).toHaveTextContent("this Device");
  expect(mine).toHaveTextContent("my text");
  expect(mine).toHaveTextContent("Only on this Device");
  fireEvent.keyDown(dialog, { key: "Escape" });
  fireEvent.click(within(rowOf("my row")).getByRole("button", { name: "Conflict" }));
  const second = screen.getByRole("dialog");
  expect(within(second).getByRole("group", { name: "Mine" })).toHaveTextContent("Showing on all Devices");
  expect(within(second).getByRole("group", { name: "Theirs" })).toHaveTextContent("Only on this Device");
});

test("Use mine and Keep theirs call resolve_conflict; Esc calls nothing", async () => {
  const calls = backend(configured, { items: () => [conflicted("1", "server text", "my text", true)] });
  render(<App />);
  await screen.findByText("server text");
  const open = () => fireEvent.click(within(rowOf("server text")).getByRole("button", { name: "Conflict" }));
  const resolves = () => calls.filter((c) => c.cmd === "resolve_conflict").map((c) => c.args);
  open();
  fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(resolves()).toEqual([]);
  open();
  fireEvent.click(screen.getByRole("button", { name: "Use mine" }));
  await vi.waitFor(() => expect(resolves()).toEqual([{ itemId: "1", keep: "mine" }]));
  await vi.waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  open();
  fireEvent.click(screen.getByRole("button", { name: "Keep theirs" }));
  await vi.waitFor(() => expect(resolves()).toHaveLength(2));
  expect(resolves()[1]).toEqual({ itemId: "1", keep: "theirs" });
});

test("Edit… in the Conflict dialog opens the editor filled with mine", async () => {
  backend(configured, { items: () => [conflicted("1", "my row text", "server other", false)] });
  render(<App />);
  await screen.findByText("my row text");
  fireEvent.click(within(rowOf("my row text")).getByRole("button", { name: "Conflict" }));
  fireEvent.click(screen.getByRole("button", { name: "Edit…" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(screen.getByRole("textbox", { name: "Edit Item" })).toHaveValue("my row text");
});

test("Edit in the menu and double-click on a conflicted row open the Conflict dialog", async () => {
  backend(configured, { items: () => [conflicted("1", "server text", "my text", true)] });
  render(<App />);
  await screen.findByText("server text");
  fireEvent.doubleClick(rowOf("server text"));
  expect(screen.getByRole("dialog", { name: "This Item was edited on two Devices" })).toBeInTheDocument();
  fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
  await userEvent.click(within(await menuOf("server text")).getByRole("menuitem", { name: "Edit" }));
  expect(screen.getByRole("dialog", { name: "This Item was edited on two Devices" })).toBeInTheDocument();
  expect(screen.queryByRole("textbox", { name: "Edit Item" })).toBeNull();
});

test("a side with no text shows (no text)", async () => {
  backend(configured, { items: () => [conflicted("1", "server text", null, true)] });
  render(<App />);
  await screen.findByText("server text");
  fireEvent.click(within(rowOf("server text")).getByRole("button", { name: "Conflict" }));
  expect(within(screen.getByRole("group", { name: "Mine" })).getByText("(no text)")).toBeInTheDocument();
});

const syncNotice = (kind: string, label: string, extra: Record<string, unknown> = {}) => ({ kind, item_id: "x", label, topic: null, topic_state: null, place: null, ...extra });

test.each([
  [syncNotice("move", "squat 100", { topic: "Gym", topic_state: "archived" }), 'Couldn\'t move "squat 100" to Gym: it was archived on another Device.'],
  [syncNotice("move", "squat 100", { topic: "Gym", topic_state: "deleted" }), 'Couldn\'t move "squat 100" to Gym: it was deleted on another Device.'],
  [syncNotice("move", "squat 100", { topic: "Gym", topic_state: null }), 'Couldn\'t move "squat 100" to Gym: it was archived or deleted on another Device.'],
  [syncNotice("inbox", "squat 100", { topic: "Gym", topic_state: "deleted" }), 'Saved "squat 100" to the Inbox: Gym was deleted on another Device.'],
  [syncNotice("empty", "squat 100"), 'Couldn\'t restore "squat 100": it has no text or files left.'],
  [syncNotice("gone", "squat 100"), 'Couldn\'t save your change to "squat 100": it was deleted for good on another Device.'],
])("a sync-notice %#, shows its sentence", async (n, sentence) => {
  backend(configured);
  render(<App />);
  await screen.findByRole("button", { name: /^Inbox/ });
  await act(() => emit("sync-notices", [n]));
  expect(await screen.findByText(sentence)).toBeInTheDocument();
});

test("several sync-notices in one event show the last and count the rest", async () => {
  backend(configured);
  render(<App />);
  await screen.findByRole("button", { name: /^Inbox/ });
  await act(() => emit("sync-notices", [syncNotice("empty", "a"), syncNotice("empty", "b"), syncNotice("gone", "c")]));
  expect(await screen.findByText('Couldn\'t save your change to "c": it was deleted for good on another Device. And 2 more.')).toBeInTheDocument();
});

test("Show on a sync-notice move opens the Item's Topic with it highlighted; empty and gone have no Show", async () => {
  backend(configured, { topics: [topic("g", "Gym")], items: ({ view }) => (view.kind === "topic" ? [filed("x", "squat 100", "g")] : []) });
  render(<App />);
  await screen.findByRole("button", { name: "Gym" });
  await act(() => emit("sync-notices", [syncNotice("gone", "a")]));
  await screen.findByText(/deleted for good/);
  expect(screen.queryByRole("button", { name: "Show" })).not.toBeInTheDocument();
  await act(() => emit("sync-notices", [syncNotice("move", "squat 100", { topic: "Gym", topic_state: "archived", place: "g" })]));
  await userEvent.click(await screen.findByRole("button", { name: "Show" }));
  expect(screen.getByRole("button", { name: "Gym" })).toHaveAttribute("aria-current", "page");
  await vi.waitFor(() => expect(rowOf("squat 100")).toHaveClass("is-highlight"));
});

test("a Notice doesn't start its 4 seconds while the window is unfocused", async () => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  const focus = vi.spyOn(document, "hasFocus").mockReturnValue(false);
  try {
    backend(configured);
    render(<App />);
    await screen.findByRole("button", { name: /^Inbox/ });
    await act(() => emit("sync-notices", [syncNotice("empty", "a")]));
    expect(await screen.findByText(/no text or files left/)).toBeInTheDocument();
    await act(async () => vi.advanceTimersByTime(9000));
    expect(screen.getByText(/no text or files left/)).toBeInTheDocument();
    focus.mockReturnValue(true);
    await act(async () => window.dispatchEvent(new Event("focus")));
    await act(async () => vi.advanceTimersByTime(8000));
    expect(screen.queryByText(/no text or files left/)).not.toBeInTheDocument();
  } finally {
    focus.mockRestore();
    vi.useRealTimers();
  }
});


const tunnelItem = (text: string | null = "transfer this"): FeedItem => ({ ...filed("tunnel-note", text ?? "", null), text, in_tunnel: true });
async function openTunnel() {
  await userEvent.click(await screen.findByRole("button", { name: /^Tunnel/ }));
  return screen.findByText("transfer this");
}

test("Tunnel sits under Inbox and shows its live count", async () => {
  backend(configured, { counts: () => ({ inbox: 2, tunnel: 3, trash: 1 }) });
  render(<App />);
  const tunnel = await screen.findByRole("button", { name: /^Tunnel\s*3$/ });
  expect(screen.getByRole("button", { name: /^Inbox\s*2$/ }).nextElementSibling).toBe(tunnel);
});

test("a Tunnel row copies once and shows Copied when trash after copy is off", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: false });
  render(<App />);
  await user.click(await openTunnel());
  expect(await screen.findByText("Copied")).toBeInTheDocument();
  expect(calls).toContainEqual({ cmd: "copy_item", args: { itemId: "tunnel-note" } });
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
});

for (const undo of ["button", "keyboard"]) {
  test(`copying a Tunnel note to Trash supports ${undo} Undo`, async () => {
    const user = userEvent.setup();
    const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true });
    render(<App />);
    await user.click(await openTunnel());
    expect(await screen.findByText("Copied · moved to Trash")).toBeInTheDocument();
    expect(calls.filter((c) => c.cmd === "trash_item")).toEqual([{ cmd: "trash_item", args: { itemId: "tunnel-note" } }]);
    if (undo === "button") await user.click(screen.getByRole("button", { name: "Undo" }));
    else fireEvent.keyDown(document.body, { key: "z", metaKey: true });
    await vi.waitFor(() => expect(calls).toContainEqual({ cmd: "restore_item", args: { itemId: "tunnel-note" } }));
  });
}

for (const answer of ["Turn on", "Not now"]) {
  test(`first Tunnel copy offers the synced setting: ${answer}`, async () => {
    const user = userEvent.setup();
    const calls = backend(configured, { items: () => [tunnelItem()] });
    render(<App />);
    await user.click(await openTunnel());
    const popup = await screen.findByRole("alertdialog", { name: "Move Tunnel notes to Trash after you copy them?" });
    expect(calls).toContainEqual({ cmd: "copy_item", args: { itemId: "tunnel-note" } });
    await user.click(within(popup).getByRole("button", { name: answer }));
    expect(calls).toContainEqual({ cmd: "set_trash_after_copy", args: { on: answer === "Turn on" } });
    expect(calls.some((c) => c.cmd === "trash_item")).toBe(answer === "Turn on");
    if (answer === "Turn on") expect(await screen.findByText("Copied · moved to Trash")).toBeInTheDocument();
    else {
      await user.click(screen.getByText("transfer this"));
      await vi.waitFor(() => expect(calls.filter((c) => c.cmd === "trash_after_copy")).toHaveLength(2));
      await screen.findByText("Copied");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    }
  });
}

test("double-clicking a Tunnel note edits it with at most one copy and no trash", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true });
  render(<App />);
  await user.dblClick(await openTunnel());
  expect(await screen.findByRole("textbox", { name: "Edit Item" })).toHaveValue("transfer this");
  await new Promise((resolve) => setTimeout(resolve, 650));
  expect(calls.filter((c) => c.cmd === "copy_item").length).toBeLessThanOrEqual(1);
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
});

test("links, attachments, and row buttons in the Tunnel never copy or trash", async () => {
  const user = userEvent.setup();
  const note = tunnelItem("https://example.com");
  note.attachments = [{ id: "f", filename: "note.pdf", mime_type: "application/pdf", size_bytes: 1, has_thumbnail: false, runnable: false }];
  const calls = backend(configured, { items: () => [note], trashAfterCopy: true });
  render(<App />);
  await user.click(await screen.findByRole("button", { name: /^Tunnel/ }));
  await user.click(screen.getByRole("link", { name: "https://example.com" }));
  await user.click(screen.getByRole("button", { name: /note.pdf/ }));
  await user.click(within(screen.getByRole("article")).getByRole("button", { name: "Item actions" }));
  await new Promise((resolve) => setTimeout(resolve, 650));
  expect(calls.some((c) => c.cmd === "copy_item")).toBe(false);
  expect(calls.some((c) => c.cmd === "plugin:opener|open_url")).toBe(true);
  expect(calls.some((c) => c.cmd === "open_attachment")).toBe(true);
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
});

test("a failed clipboard write never changes the setting or trashes", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true, failing: { copy_item: "Clipboard unavailable" } });
  render(<App />);
  await user.click(await openTunnel());
  expect(await screen.findByText("Couldn't copy the Item")).toBeInTheDocument();
  expect(calls.some((c) => ["trash_item", "set_trash_after_copy"].includes(c.cmd))).toBe(false);
});

test("an empty Tunnel Item is not copyable", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem(null)], trashAfterCopy: true });
  render(<App />);
  await user.click(await screen.findByRole("button", { name: /^Tunnel/ }));
  await user.click(screen.getByRole("article"));
  await new Promise((resolve) => setTimeout(resolve, 650));
  expect(calls.some((c) => c.cmd === "copy_item")).toBe(false);
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
});

test("an attachment-only Tunnel Item copies completely before it can be trashed", async () => {
  let finish!: () => void;
  const gate = new Promise<void>((resolve) => { finish = resolve; });
  const note = tunnelItem(null);
  note.attachments = [{ id: "f", filename: "note.pdf", mime_type: "application/pdf", size_bytes: 1, has_thumbnail: false, runnable: false }];
  const calls = backend(configured, { items: () => [note], trashAfterCopy: true, gates: { copy_item: gate } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Tunnel/ }));
  await userEvent.click(screen.getByRole("article"));
  await vi.waitFor(() => expect(calls.some((c) => c.cmd === "copy_item")).toBe(true));
  await new Promise((resolve) => setTimeout(resolve, 650));
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
  await act(async () => finish());
  expect(await screen.findByText("Copied · moved to Trash")).toBeInTheDocument();
});

test("a whole-Item download or clipboard failure retains the Tunnel Item", async () => {
  const note = tunnelItem();
  note.attachments = [{ id: "f", filename: "note.pdf", mime_type: "application/pdf", size_bytes: 1, has_thumbnail: false, runnable: false }];
  const calls = backend(configured, { items: () => [note], trashAfterCopy: true, failing: { copy_item: "Download failed" } });
  render(<App />);
  await userEvent.click(await openTunnel());
  expect(await screen.findByText("Couldn't copy the Item")).toBeInTheDocument();
  expect(calls.some((c) => ["trash_item", "set_trash_after_copy"].includes(c.cmd))).toBe(false);
});

test("leaving Tunnel during attachment downloads keeps the Item out of Trash", async () => {
  let finish!: () => void;
  const gate = new Promise<void>((resolve) => { finish = resolve; });
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true, gates: { copy_item: gate } });
  render(<App />);
  await userEvent.click(await openTunnel());
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  await act(async () => finish());
  await new Promise((resolve) => setTimeout(resolve, 650));
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
  expect(screen.queryByText("Copied · moved to Trash")).not.toBeInTheDocument();
});

test("Move to Tunnel and Undo preserve the original place", async () => {
  const calls = backend(configured, { items: () => [filed("1", "move this", "g")], topics: [topic("g", "Gym")] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Tunnel" }));
  expect(await screen.findByText("Moved to the Tunnel")).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Undo" }));
  expect(moves(calls)).toEqual([{ itemId: "1", target: { kind: "tunnel" } }, { itemId: "1", target: { kind: "topic", id: "g" } }]);
});

test("dragging from Tunnel to Inbox and Undo returns to Tunnel", async () => {
  const calls = backend(configured, { items: () => [tunnelItem()] });
  render(<App />);
  await openTunnel();
  drag("transfer this", screen.getByRole("button", { name: /^Inbox/ }));
  await screen.findByText("Moved to the Inbox");
  await userEvent.click(screen.getByRole("button", { name: "Undo" }));
  expect(moves(calls)).toEqual([{ itemId: "tunnel-note", target: { kind: "inbox" } }, { itemId: "tunnel-note", target: { kind: "tunnel" } }]);
});

test("dropping an Inbox note onto Tunnel moves it there", async () => {
  const calls = backend(configured, { items: () => [filed("1", "move this", null)] });
  render(<App />);
  await screen.findByText("move this");
  drag("move this", screen.getByRole("button", { name: /^Tunnel/ }));
  await vi.waitFor(() => expect(moves(calls)).toEqual([{ itemId: "1", target: { kind: "tunnel" } }]));
});

test("Tunnel settings round-trip", async () => {
  const calls = backend(configured, { trashAfterCopy: true });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  const toggle = await screen.findByRole("switch", { name: "Trash Tunnel notes after copying" });
  await vi.waitFor(() => expect(toggle).toBeChecked());
  await userEvent.click(toggle);
  expect(calls).toContainEqual({ cmd: "set_trash_after_copy", args: { on: false } });
  expect(toggle).not.toBeChecked();
  await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await userEvent.click(screen.getByRole("button", { name: "Settings" }));
  expect(await screen.findByRole("switch", { name: "Trash Tunnel notes after copying" })).not.toBeChecked();
});


test("Tunnel search filters and opens a result in its own place", async () => {
  const calls = backend(configured, { items: () => [tunnelItem()], search: () => [found(tunnelItem())] });
  render(<App />);
  const search = await screen.findByRole("textbox", { name: /Search/ });
  await userEvent.type(search, "transfer");
  const results = await screen.findByTestId("results");
  await within(results).findByText("transfer this");
  await userEvent.click(screen.getByRole("button", { name: "Place" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Tunnel" }));
  await vi.waitFor(() => expect(calls.some((c) => c.cmd === "search_items" && c.args.query.place.kind === "tunnel")).toBe(true));
  await userEvent.click(within(results).getByRole("button", { name: /transfer this/ }));
  expect(screen.getByRole("button", { name: /^Tunnel/ })).toHaveAttribute("aria-current", "page");
});


test("two quickly clicked Tunnel notes both move to Trash", async () => {
  const user = userEvent.setup();
  const second = { ...tunnelItem("second transfer"), id: "second" };
  const calls = backend(configured, { items: () => [tunnelItem(), second], trashAfterCopy: true });
  render(<App />);
  await user.click(await openTunnel());
  await user.click(screen.getByText("second transfer"));
  await vi.waitFor(() => expect(calls.filter((c) => c.cmd === "trash_item").map((c) => c.args.itemId)).toEqual(["tunnel-note", "second"]));
});

test("leaving Tunnel cancels a pending copy-to-Trash decision", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true });
  render(<App />);
  await user.click(await openTunnel());
  await user.click(screen.getByRole("button", { name: /^Inbox/ }));
  await new Promise((resolve) => setTimeout(resolve, 650));
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
});


test("a synced setting change updates the switch while Settings stays open", async () => {
  let remote = true;
  backend(configured, { pulledTrashAfterCopy: () => remote });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  const toggle = await screen.findByRole("switch", { name: "Trash Tunnel notes after copying" });
  await vi.waitFor(() => expect(toggle).toBeChecked());
  remote = false;
  await act(() => emit("items-changed"));
  await vi.waitFor(() => expect(toggle).not.toBeChecked());
});

test("copying the same Tunnel note again restarts its Copied confirmation", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: false });
  render(<App />);
  await user.click(await openTunnel());
  await screen.findByText("Copied");
  await act(() => new Promise((resolve) => setTimeout(resolve, 750)));
  await user.click(screen.getByText("transfer this"));
  await vi.waitFor(() => expect(calls.filter((c) => c.cmd === "trash_after_copy")).toHaveLength(2));
  await act(() => new Promise((resolve) => setTimeout(resolve, 400)));
  expect(screen.getByText("Copied")).toBeInTheDocument();
});


test("a slow system double-click edits a Tunnel note without trashing it", async () => {
  userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true, doubleClickIntervalMs: 900 });
  render(<App />);
  const text = await openTunnel();
  fireEvent.click(text, { detail: 1 });
  await act(() => new Promise((resolve) => setTimeout(resolve, 650)));
  fireEvent.click(text, { detail: 2 });
  fireEvent.doubleClick(text, { detail: 2 });
  expect(await screen.findByRole("textbox", { name: "Edit Item" })).toHaveValue("transfer this");
  await act(() => new Promise((resolve) => setTimeout(resolve, 400)));
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
});

test("a failed system timing read keeps a copied Tunnel note out of Trash", async () => {
  const user = userEvent.setup();
  const calls = backend(configured, { items: () => [tunnelItem()], trashAfterCopy: true, failing: { double_click_interval_ms: "Timing unavailable" } });
  render(<App />);
  await user.click(await openTunnel());
  expect(await screen.findByText("Timing unavailable")).toBeInTheDocument();
  expect(calls.some((c) => c.cmd === "trash_item")).toBe(false);
  expect(calls).toContainEqual({ cmd: "copy_item", args: { itemId: "tunnel-note" } });
});


test("a new desktop opens Home with the sidebar and captures to a chosen Topic or Tunnel", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")] });
  localStorage.removeItem("place");
  render(<App />);
  await screen.findByRole("heading", { name: "NoteBank" });
  expect(screen.getByRole("navigation")).toBeVisible();
  expect(calls.some((c) => c.cmd === "list_items")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "Topic" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  await userEvent.type(screen.getByRole("textbox", { name: "New Item" }), "squat{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "squat", attachmentIds: [], target: { kind: "topic", id: "g" } } });
  await userEvent.click(screen.getByRole("switch", { name: "Tunnel" }));
  await userEvent.type(screen.getByRole("textbox", { name: "New Item" }), "transfer{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "transfer", attachmentIds: [], target: { kind: "tunnel" } } });
});

test("Home and Topic feeds share the unsent draft but Topic capture stays fixed", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")] });
  localStorage.removeItem("place");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "keep draft");
  await userEvent.click(within(screen.getByRole("navigation")).getByRole("button", { name: "Gym" }));
  expect(box).toHaveValue("keep draft");
  expect(screen.queryByRole("switch", { name: "Tunnel" })).not.toBeInTheDocument();
  await userEvent.type(box, "{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "keep draft", attachmentIds: [], target: { kind: "topic", id: "g" } } });
  await userEvent.click(screen.getByRole("button", { name: "Home" }));
  expect(screen.getByRole("switch", { name: "Tunnel" })).toBeInTheDocument();
});

test("typing a new name in the destination offers Create, which picks the new Topic without sending the draft", async () => {
  const calls = backend(configured);
  localStorage.removeItem("place");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "tile ideas");
  await userEvent.click(screen.getByRole("button", { name: "Topic" }));
  await userEvent.type(screen.getByRole("searchbox", { name: "Find or create a Topic" }), "Mosaic");
  expect(screen.getByRole("menuitem", { name: "Create “Mosaic”" })).toBeInTheDocument();
  await userEvent.keyboard("{Enter}");
  expect(calls).toContainEqual({ cmd: "picker_topic", args: { name: "Mosaic" } });
  expect(calls.some((c) => c.cmd === "capture" || c.cmd === "create_topic")).toBe(false);
  await vi.waitFor(() => expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Mosaic"));
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  expect(box).toHaveFocus();
  await userEvent.type(box, "{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "tile ideas", attachmentIds: [], target: { kind: "topic", id: "new" } } });
});

test("typing an open Topic's name offers no Create, and Enter picks that Topic", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")] });
  localStorage.removeItem("place");
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Topic" }));
  await userEvent.type(screen.getByRole("searchbox", { name: "Find or create a Topic" }), "gym");
  expect(screen.queryByRole("menuitem", { name: /^Create/ })).not.toBeInTheDocument();
  await userEvent.keyboard("{Enter}");
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Gym");
  expect(calls.some((c) => c.cmd === "picker_topic")).toBe(false);
});

test("Create with an archived Topic's name shows the error and keeps the name; Escape clears it, then closes the menu", async () => {
  const calls = backend(configured, { topics: [topic("o", "Old", { archived: true })] });
  localStorage.removeItem("place");
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Topic" }));
  const filter = screen.getByRole("searchbox", { name: "Find or create a Topic" });
  await userEvent.type(filter, "old");
  await userEvent.click(screen.getByRole("menuitem", { name: "Create “old”" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("An archived Topic has that name");
  expect(filter).toHaveValue("old");
  await userEvent.type(filter, "{Escape}");
  expect(filter).toHaveValue("");
  expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  expect(screen.getByRole("menuitem", { name: "New Topic…" })).toBeInTheDocument();
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Inbox");
  expect(calls.filter((c) => c.cmd === "picker_topic")).toHaveLength(1);
});

test("the composer's New Topic… opens the same dialog as Move to, and a refused name stays in it", async () => {
  const calls = backend(configured, { topics: [topic("o", "Old", { archived: true })] });
  localStorage.removeItem("place");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "tile ideas");
  await userEvent.click(screen.getByRole("button", { name: "Topic" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "New Topic…" }));
  const dialog = screen.getByRole("dialog", { name: "New Topic" });
  await userEvent.type(within(dialog).getByRole("textbox", { name: "Topic name" }), "old{Enter}");
  expect(await within(dialog).findByRole("alert")).toHaveTextContent("An archived Topic has that name");
  await userEvent.clear(within(dialog).getByRole("textbox", { name: "Topic name" }));
  await userEvent.type(within(dialog).getByRole("textbox", { name: "Topic name" }), "Mosaic");
  await userEvent.click(within(dialog).getByRole("button", { name: "Create" }));
  await vi.waitFor(() => expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Mosaic"));
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(box).toHaveFocus();
  expect(box).toHaveValue("tile ideas");
  expect(calls.some((c) => c.cmd === "capture")).toBe(false);
});

test("Move to… ends with New Topic…, which creates the Topic and moves the Item into it", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "tile ideas", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  const create = screen.getByRole("menuitem", { name: "New Topic…" });
  expect(screen.getByRole("menu", { name: "Move to" }).lastElementChild).toBe(create);
  await userEvent.click(create);
  const dialog = await screen.findByRole("dialog", { name: "New Topic" });
  await userEvent.type(within(dialog).getByRole("textbox", { name: "Topic name" }), "Mosaic{Enter}");
  await vi.waitFor(() => expect(moves(calls)).toEqual([{ itemId: "1", target: { kind: "topic", id: "new" } }]));
  expect(calls).toContainEqual({ cmd: "picker_topic", args: { name: "Mosaic" } });
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(await screen.findByText("Moved to Mosaic")).toBeInTheDocument();
});

test("Move to… New Topic… with an archived Topic's name keeps the dialog open and moves nothing", async () => {
  const calls = backend(configured, { topics: [topic("o", "Old", { archived: true })], items: () => [filed("1", "x", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "New Topic…" }));
  await userEvent.type(await screen.findByRole("textbox", { name: "Topic name" }), "OLD{Enter}");
  expect(await screen.findByRole("alert")).toHaveTextContent("An archived Topic has that name");
  expect(screen.getByRole("dialog", { name: "New Topic" })).toBeInTheDocument();
  expect(moves(calls)).toEqual([]);
  await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
});

test("Home drops a now-archived destination without discarding the draft", async () => {
  const topics = [topic("g", "Gym")];
  const calls = backend(configured, { topics });
  localStorage.removeItem("place");
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Topic" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  const box = screen.getByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "keep");
  topics[0].archived = true;
  await act(() => emit("items-changed"));
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Inbox");
  expect(box).toHaveValue("keep");
  await userEvent.type(box, "{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "keep", attachmentIds: [], target: { kind: "inbox" } } });
});

test("Tunnel removal uses the native transition after the saved deletion arrives", async () => {
  const updates: (() => void)[] = [];
  Object.defineProperty(document, "startViewTransition", { configurable: true, value: (update: () => void) => {
    updates.push(update);
    return { ready: Promise.resolve() };
  } });
  let removed = false;
  try {
    backend(configured, { items: () => removed ? [] : [tunnelItem()] });
    render(<App />);
    await openTunnel();
    removed = true;
    await act(() => emit("items-changed"));
    await vi.waitFor(() => expect(updates).toHaveLength(1));
    expect(screen.getByText("transfer this")).toBeInTheDocument();
    act(() => updates[0]());
    expect(screen.queryByText("transfer this")).not.toBeInTheDocument();
  } finally { delete (document as Partial<Document>).startViewTransition; }
});

test("a saved Topic destination waits for Topics to load before validating it", async () => {
  backend(configured, { topics: [topic("g", "Gym")] });
  localStorage.setItem("place", "g");
  render(<App />);
  await screen.findByRole("button", { name: "Gym" });
  await vi.waitFor(() => expect(screen.getByRole("button", { name: "Gym" })).toHaveAttribute("aria-current", "page"));
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveAttribute("placeholder", "Write to Gym…");
});

test("Home's Tunnel switch follows the other desktop window without losing its draft", async () => {
  backend(configured);
  localStorage.removeItem("place");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "keep draft");
  localStorage.setItem("tunnelSwitch", "true");
  act(() => window.dispatchEvent(new StorageEvent("storage", { key: "tunnelSwitch", newValue: "true" })));
  expect(screen.getByRole("switch", { name: "Tunnel" })).toBeChecked();
  expect(box).toHaveValue("keep draft");
});

test("Home offers capture without duplicating sidebar places", async () => {
  backend(configured, { topics: [topic("g", "Gym")] });
  localStorage.setItem("place", "home");
  render(<App />);
  await screen.findByRole("textbox", { name: "New Item" });
  expect(screen.queryByRole("button", { name: "Open Inbox" })).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Open Gym" })).not.toBeInTheDocument();
  expect(within(screen.getByRole("navigation")).getByRole("button", { name: "Gym" })).toBeVisible();
});

test("All Items is view-only and keeps the draft for the next capture destination", async () => {
  backend(configured);
  localStorage.setItem("place", "inbox");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "keep this draft");
  await userEvent.click(screen.getByRole("button", { name: "All Items" }));
  expect(screen.queryByRole("textbox", { name: "New Item" })).not.toBeInTheDocument();
  expect(screen.queryByText("Capture something below.")).not.toBeInTheDocument();
  expect(screen.getByText("Capture something in Home or choose a place in the sidebar.")).toBeVisible();
  await userEvent.click(screen.getByRole("button", { name: /^Inbox/ }));
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveValue("keep this draft");
});

test("opening an image refreshes its preview after the original downloads", async () => {
  const options: Options = {
    items: () => [feedItem("1", "", at(2026, 10, 14, 9, 41), false, [{ ...photo, filename: "photo.heic", mime_type: "image/heic", has_thumbnail: false }])],
  };
  const calls = backend(configured, options);
  render(<App />);
  await screen.findByText("photo.heic");
  await vi.waitFor(() => expect(calls.some(c => c.cmd === "thumbnail")).toBe(true));
  options.thumbnail = "/data/files/a2/photo.heic";
  await userEvent.click(screen.getByRole("button", { name: "Open photo.heic" }));
  expect(await screen.findByRole("img", { name: "photo.heic" })).toHaveAttribute("src", expect.stringContaining("photo.heic"));
});


test("the sidebar toggle persists its state across launches", async () => {
  backend(configured);
  const app = render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Hide sidebar" }));
  expect(screen.queryByRole("textbox", { name: "Search" })).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Show sidebar" })).toHaveAttribute("aria-expanded", "false");
  app.unmount();
  render(<App />);
  await screen.findByRole("button", { name: "Show sidebar" });
  expect(screen.queryByRole("textbox", { name: "Search" })).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Show sidebar" }));
  expect(screen.getByRole("navigation")).toBeInTheDocument();
});

test("the sidebar shortcut returns focus from Search to the capture box", async () => {
  backend(configured);
  localStorage.setItem("place", "home");
  render(<App />);
  await userEvent.click(await screen.findByRole("textbox", { name: "Search" }));
  fireEvent.keyDown(document.activeElement!, { key: "\\", metaKey: true });
  expect(screen.queryByRole("textbox", { name: "Search" })).not.toBeInTheDocument();
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveFocus();
});

test("Search temporarily opens a collapsed sidebar and empty Escape restores it", async () => {
  backend(configured);
  localStorage.setItem("place", "home");
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Hide sidebar" }));
  fireEvent.keyDown(document.body, { key: "f", metaKey: true });
  expect(screen.getByRole("textbox", { name: "Search" })).toHaveFocus();
  fireEvent.keyDown(document.activeElement!, { key: "f", metaKey: true });
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("textbox", { name: "Search" })).not.toBeInTheDocument();
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveFocus();
});

test("empty Search Escape keeps an originally open sidebar open", async () => {
  backend(configured);
  render(<App />);
  await screen.findByRole("navigation");
  fireEvent.keyDown(document.body, { key: "f", ctrlKey: true });
  await userEvent.keyboard("{Escape}");
  expect(screen.getByRole("navigation")).toBeInTheDocument();
});

test("sidebar + opens the shared dialog and a reserved name stays in it", async () => {
  backend(configured, { failing: { picker_topic: 'Inbox is a built-in name. Pick another.' } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  const dialog = screen.getByRole("dialog", { name: "New Topic" });
  expect(within(screen.getByRole("navigation")).queryByRole("textbox", { name: "Topic name" })).not.toBeInTheDocument();
  await userEvent.type(within(dialog).getByRole("textbox", { name: "Topic name" }), "Inbox");
  await userEvent.click(within(dialog).getByRole("button", { name: "Create" }));
  expect(await within(dialog).findByRole("alert")).toHaveTextContent("built-in name");
});

test("collapsing during Search uncovers the draft and returns focus", async () => {
  backend(configured);
  localStorage.setItem("place", "home");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  await userEvent.type(box, "unfinished capture");
  await userEvent.type(screen.getByRole("textbox", { name: "Search" }), "look up");
  fireEvent.keyDown(document.activeElement!, { key: "\\", metaKey: true });
  expect(box.closest("main")).not.toHaveClass("is-covered");
  expect(box).toHaveFocus();
  expect(box).toHaveValue("unfinished capture");
});

test("cancelling sidebar New Topic restores + focus after a click without browser focus", async () => {
  backend(configured);
  localStorage.setItem("place", "home");
  render(<App />);
  const box = await screen.findByRole("textbox", { name: "New Item" });
  box.focus();
  const plus = screen.getByRole("button", { name: "New Topic" });
  fireEvent.click(plus);
  await userEvent.keyboard("{Escape}");
  expect(plus).toHaveFocus();
});


test("the collapsed rail keeps main Places available without a Search button", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Hide sidebar" }));
  const rail = screen.getByRole("navigation");
  expect(within(rail).queryByRole("button", { name: "Search" })).not.toBeInTheDocument();
  expect(within(rail).queryByRole("button", { name: /Trash/ })).not.toBeInTheDocument();
  expect(within(rail).queryByRole("button", { name: "New Topic" })).not.toBeInTheDocument();
  for (const [name,kind] of [["Home","all"],["Inbox","inbox"],["Tunnel","tunnel"]]) {
    await userEvent.click(within(rail).getByRole("button", { name }));
    if (name !== "Home") await vi.waitFor(() => expect(calls.filter(c=>c.cmd==="list_items").slice(-1)[0]?.args.view).toEqual({kind}));
    expect(screen.getByRole("button", { name: "Show sidebar" })).toHaveAttribute("aria-expanded", "false");
  }
});
