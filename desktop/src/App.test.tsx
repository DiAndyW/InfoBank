import { act, fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { emit } from "@tauri-apps/api/event";
import { mockConvertFileSrc, mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { expect, test, vi } from "vitest";
import App from "./App";
import { MAX_ATTACHMENT_BYTES, type Counts, type FeedAttachment, type FeedItem, type SearchItem, type Settings, type Staged, type StagedFiles, type SyncStatus, type Topic } from "./api";

type Options = {
  topics?: Topic[];
  saveError?: string;
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
};

function backend(given: Omit<Settings, "quick_capture"> & Partial<Settings>, opts: Options = {}) {
  const settings: Settings = { quick_capture: { shortcut: "shift+super+Space", on: true }, ...given };
  let hotkey = settings.quick_capture;
  const calls: { cmd: string; args: any }[] = [];
  mockWindows("main");
  mockConvertFileSrc("macos");
  mockIPC(
    async (cmd, args) => {
      calls.push({ cmd, args });
      await opts.gates?.[cmd];
      if (opts.failing?.[cmd]) throw opts.failing[cmd];
      if (cmd === "get_settings") return settings;
      if (cmd === "list_topics") return opts.topics ?? [];
      if (cmd === "sync_status") return opts.status ?? "synced";
      if (cmd === "list_items") return opts.items ? opts.items(args) : [];
      if (cmd === "search_items") return opts.search ? opts.search(args) : [];
      if (cmd === "nav_counts") return opts.counts?.() ?? { inbox: 0, trash: 0 };
      if (cmd === "edit_item") return opts.edited ?? { trashed: false };
      if (["trash_item", "restore_item"].includes(cmd)) return null;
      if (cmd === "save_settings") {
        if (opts.saveError) throw opts.saveError;
        return null;
      }
      if (cmd === "capture") {
        if (opts.captureError) throw opts.captureError;
        return null;
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
  pending,
  attachments,
  purge_at_us: null,
});

const topic = (id: string, name: string, extra: Partial<Topic> = {}): Topic => ({ id, name, archived: false, item_count: 0, ...extra });

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
      if (cmd === "nav_counts") return { inbox: 0, trash: 0 };
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
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  await userEvent.type(box, "a{Shift>}{Enter}{/Shift}b");
  expect(box).toHaveValue("a\nb");
  expect(calls.some((c) => c.cmd === "capture")).toBe(false);
  await userEvent.type(box, "{Enter}");
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "a\nb", attachmentIds: [], topicId: null } });
  expect(box).toHaveValue("");
});

test("the main composer keeps autocorrect and Escape leaves its draft alone", async () => {
  const calls = backend(configured);
  render(<App />);
  const box = await screen.findByLabelText("New Item");
  expect(box).not.toHaveAttribute("autocorrect");
  await userEvent.type(box, "draft{Escape}");
  expect(box).toHaveValue("draft");
  expect(calls.some((c) => c.cmd === "dismiss_quick_capture")).toBe(false);
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
  await userEvent.click(await screen.findByRole("button", { name: "Secret rejected" }));
  expect(screen.getByRole("heading", { name: "Settings" })).toBeInTheDocument();
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
  await userEvent.selectOptions(screen.getByLabelText("Theme"), "Blackboard");
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
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "Attach files" }));
  await screen.findByText("scan.png");
  await userEvent.click(screen.getByRole("button", { name: "Send" }));
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "", attachmentIds: ["s1"], topicId: null } });
  await vi.waitFor(() => expect(screen.queryByText("scan.png")).not.toBeInTheDocument());
});

test("a pasted image is staged from its bytes, and an oversized one is refused", async () => {
  const calls = backend(configured, { staged: [scan] });
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

test("files staged from a drop become chips, and failures are named", async () => {
  backend(configured);
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

test("+ creates a Topic inline and opens it", async () => {
  const calls = backend(configured);
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  await userEvent.type(screen.getByLabelText("Topic name"), "Books{Enter}");
  expect(calls).toContainEqual({ cmd: "create_topic", args: { name: "Books" } });
  await vi.waitFor(() => expect(screen.queryByLabelText("Topic name")).not.toBeInTheDocument());
  const lists = calls.filter((c) => c.cmd === "list_items");
  expect(lists[lists.length - 1].args.view).toEqual({ kind: "topic", id: "new" });
});

test("a name clash keeps the field open with the error", async () => {
  backend(configured, { failing: { create_topic: 'A Topic named "Books" already exists' } });
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
  expect(calls.some((c) => c.cmd === "create_topic")).toBe(false);
});

test("Enter twice creates one Topic", async () => {
  let release!: () => void;
  const calls = backend(configured, { gates: { create_topic: new Promise<void>((resolve) => (release = resolve)) } });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: "New Topic" }));
  // The first create is still in flight when the second Enter arrives.
  await userEvent.type(screen.getByLabelText("Topic name"), "Books{Enter}{Enter}");
  await act(async () => release());
  await vi.waitFor(() => expect(screen.queryByLabelText("Topic name")).not.toBeInTheDocument());
  expect(calls.filter((c) => c.cmd === "create_topic")).toHaveLength(1);
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

test("Move to… lists the Inbox and open Topics, with the current place ticked", async () => {
  const calls = backend(configured, {
    topics: [topic("g", "Gym"), topic("w", "Work"), topic("o", "Old", { archived: true })],
    items: () => [filed("1", "squat 100", null)],
  });
  render(<App />);
  const article = await screen.findByRole("article");
  await userEvent.click(within(article).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to…" }));
  const targets = within(screen.getByRole("menu", { name: "Move to…" })).getAllByRole("menuitemradio");
  expect(targets.map((t) => [t.textContent?.replace(" ✓", ""), t.getAttribute("aria-checked")])).toEqual([
    ["Inbox", "true"],
    ["Gym", "false"],
    ["Work", "false"],
  ]);
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  expect(calls).toContainEqual({ cmd: "move_item", args: { itemId: "1", topicId: "g" } });
});

test("moving an Item to where it is does nothing", async () => {
  const calls = backend(configured, { topics: [topic("g", "Gym")], items: () => [filed("1", "x", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to…" }));
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Inbox" }));
  expect(calls.some((c) => c.cmd === "move_item")).toBe(false);
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
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to…" }));
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
  expect(calls).toContainEqual({ cmd: "capture", args: { text: "squat 100", attachmentIds: [], topicId: "g" } });
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
  await userEvent.click(screen.getByRole("menuitem", { name: "Move to…" }));
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
  expect(screen.getByRole("menuitemradio", { name: "Inbox" })).toHaveFocus();
  await userEvent.keyboard("{ArrowDown}");
  expect(screen.getByRole("menuitemradio", { name: "Gym" })).toHaveFocus();
  await userEvent.keyboard("{ArrowLeft}");
  expect(screen.queryByRole("menuitemradio", { name: "Gym" })).not.toBeInTheDocument();
  expect(screen.getByRole("menuitem", { name: "Move to…" })).toHaveFocus();
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

test("the Item menu is Edit, Move to…, Copy text, then Move to Trash in red after a separator", async () => {
  backend(configured, { items: () => [filed("1", "squat 100", null)] });
  render(<App />);
  await userEvent.click(within(await screen.findByRole("article")).getByRole("button", { name: "Item actions" }));
  const menu = screen.getByRole("menu", { name: "Item actions" });
  expect(within(menu).getAllByRole("menuitem").map((m) => m.textContent)).toEqual(["Edit", "Move to…", "Copy text", "Move to Trash"]);
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

test("a new Notice gets its own 8 seconds", async () => {
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
  render(<App />);
  await openEdit("squat 100");
  const box = screen.getByRole("textbox", { name: "Edit Item" });
  expect(box).toHaveValue("squat 100");
  expect(box).toHaveFocus();
  expect(screen.getByLabelText("New Item")).toBeVisible();
  await userEvent.type(box, " x5{Shift>}{Enter}{/Shift}felt good{Enter}");
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "squat 100 x5\nfelt good", addIds: [], removeIds: [] } });
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
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "", addIds: [], removeIds: [] } });
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
  fireEvent.paste(screen.getByRole("textbox", { name: "Edit Item" }), { clipboardData: { files: [new File(["x"], "")] } });
  await within(editorOf()).findByText("Pasted image.png");
  expect(within(screen.getByLabelText("New Item").closest("form")!).queryByText("Pasted image.png")).not.toBeInTheDocument();
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Remove report.pdf" }));
  await userEvent.click(within(editorOf()).getByRole("button", { name: "Save" }));
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "receipt", addIds: ["s1", "s2"], removeIds: ["a1"] } });
});

test("a refetch while editing doesn't make Save remove the Item's files", async () => {
  const calls = backend(configured, { items: () => [{ ...filed("1", "receipt", null), attachments: [{ ...report }] }] });
  render(<App />);
  await openEdit("receipt");
  await act(() => emit("items-changed"));
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!{Enter}");
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "receipt!", addIds: [], removeIds: [] } });
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
  expect(calls.some((c) => c.cmd === "create_topic")).toBe(false);
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

test("opening Edit on a second Item saves the first, unless that save fails", async () => {
  const failing: Record<string, string> = {};
  const calls = backend(configured, { items: () => [filed("1", "squat 100", null), filed("2", "bench 70", null)], failing });
  render(<App />);
  await openEdit("squat 100");
  await userEvent.type(screen.getByRole("textbox", { name: "Edit Item" }), "!");
  await userEvent.dblClick(screen.getByText("bench 70"));
  expect(calls).toContainEqual({ cmd: "edit_item", args: { itemId: "1", text: "squat 100!", addIds: [], removeIds: [] } });
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
  expect(calls.filter((c) => c.cmd === "edit_item")).toEqual(Array(2).fill({ cmd: "edit_item", args: { itemId: "1", text: "squat 100!", addIds: [], removeIds: [] } }));
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

test("Trash lists deleted Items with where Restore puts them and days left, with no menu or editing", async () => {
  const calls = backend(configured, {
    topics: [topic("g", "Gym")],
    items: ({ view }) =>
      view.kind === "trash"
        ? [inTrash(filed("1", "old shoe sizes", "g"), 15), inTrash(filed("2", "deadlift", null), 1), { ...inTrash(filed("3", "just now", null), null), pending: true }]
        : [],
  });
  render(<App />);
  await userEvent.click(await screen.findByRole("button", { name: /^Trash/ }));
  await screen.findByText("old shoe sizes");
  expect(within(rowOf("old shoe sizes")).getByText("Gym")).toBeInTheDocument();
  expect(within(rowOf("old shoe sizes")).getByText("15 days left")).toBeInTheDocument();
  expect(within(rowOf("deadlift")).getByText("Inbox")).toBeInTheDocument();
  expect(within(rowOf("deadlift")).getByText("1 day left")).toBeInTheDocument();
  expect(within(rowOf("just now")).queryByText(/left$/)).not.toBeInTheDocument();
  expect(within(rowOf("just now")).getByLabelText("Not synced yet")).toBeInTheDocument();
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
  let counts = { inbox: 17, trash: 3 };
  backend(configured, { counts: () => counts });
  render(<App />);
  expect(within(await screen.findByRole("button", { name: /^Inbox/ })).getByText("17")).toBeInTheDocument();
  const trash = screen.getByRole("button", { name: /^Trash/ });
  expect(within(trash).getByText("3")).toBeInTheDocument();
  await userEvent.click(trash);
  counts = { inbox: 16, trash: 4 };
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
  expect(within(menu).getAllByRole("menuitemradio").map((o) => o.textContent)).toEqual(["Anywhere", "Inbox", "Taxes", "Old"]);
  expect(within(menu).getByText("Archived")).toBeInTheDocument();
  await userEvent.click(within(menu).getByRole("menuitemradio", { name: "Old" }));
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "topic", id: "o" }));
  expect(place).toHaveTextContent("Old");
  await pick("Place", "Inbox");
  await vi.waitFor(() => expect(lastQuery(calls).place).toEqual({ kind: "inbox" }));
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
  const moveTo = screen.getByRole("menuitem", { name: "Move to…" });
  await userEvent.hover(moveTo);
  expect(screen.getByRole("menu", { name: "Move to…" })).toBeInTheDocument();
  await userEvent.unhover(moveTo);
  expect(screen.queryByRole("menu", { name: "Move to…" })).not.toBeInTheDocument();
  expect(screen.getByRole("menu", { name: "Item actions" })).toBeInTheDocument();
});

test("moving from Move to… toward its submenu keeps it open; straying outside that path or stopping short closes it", async () => {
  backend(configured, { topics: [topic("t", "Taxes")], items: () => [feedItem("1", "hello", at(2026, 10, 14, 9, 41))] });
  render(<App />);
  await screen.findByText("hello");
  await userEvent.click(screen.getByRole("button", { name: "Item actions" }));
  const moveTo = screen.getByRole("menuitem", { name: "Move to…" });
  const open = async () => {
    await userEvent.hover(moveTo);
    const sub = screen.getByRole("menu", { name: "Move to…" });
    // The submenu opens to the left: its near edge is x = 100, from y = 0 to 200.
    vi.spyOn(sub, "getBoundingClientRect").mockReturnValue({ left: 0, right: 100, top: 0, bottom: 200, x: 0, y: 0, width: 100, height: 200, toJSON: () => ({}) });
  };
  const subOpen = () => screen.queryByRole("menu", { name: "Move to…" }) !== null;
  const wrap = moveTo.parentElement!;

  await open();
  fireEvent.mouseLeave(wrap, { clientX: 110, clientY: 10, relatedTarget: document.body });
  fireEvent.mouseMove(document, { clientX: 105, clientY: 60 });
  expect(subOpen()).toBe(true);
  await userEvent.hover(within(screen.getByRole("menu", { name: "Move to…" })).getByRole("menuitemradio", { name: "Taxes" }));
  await new Promise((r) => setTimeout(r, 500));
  expect(subOpen()).toBe(true);

  await open();
  fireEvent.mouseLeave(wrap, { clientX: 110, clientY: 10, relatedTarget: document.body });
  fireEvent.mouseMove(document, { clientX: 120, clientY: 60 });
  expect(subOpen()).toBe(false);

  await open();
  fireEvent.mouseLeave(wrap, { clientX: 110, clientY: 10, relatedTarget: document.body });
  fireEvent.mouseMove(document, { clientX: 105, clientY: 60 });
  await vi.waitFor(() => expect(subOpen()).toBe(false));
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
