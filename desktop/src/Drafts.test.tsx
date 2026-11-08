import { act, fireEvent, render, screen } from "@testing-library/react";
import { emit } from "@tauri-apps/api/event";
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { afterEach, expect, test, vi } from "vitest";
import App from "./App";
import type { StagedFiles, Topic } from "./api";

type Row = { place: string; text: string; home_topic_id: string | null };
function backend(opts: { load?: Promise<Row[]>; capture?: Promise<void>; save?: Promise<void>; pick?: Promise<StagedFiles>; topicsRefresh?: Promise<Topic[]>; saveFailures?: number } = {}) {
  localStorage.setItem("place", "inbox");
  const drafts = new Map<string, Row>();
  const calls: { cmd: string; args: any }[] = [];
  let topicLoads = 0;
  mockWindows("main");
  mockIPC(async (cmd, args: any) => {
    calls.push({ cmd, args });
    if (cmd === "get_settings") return { server_url: "https://example.test", has_secret: true, quick_capture: { shortcut: "shift+super+Space", on: true } };
    if (cmd === "list_topics" && topicLoads++ > 0 && opts.topicsRefresh) return opts.topicsRefresh;
    if (cmd === "picker_topic") { await emit("items-changed"); return { id: "books-id", name: args.name, archived: false, item_count: 0 }; }
    if (cmd === "list_topics") return [{ id: "work-id", name: "Work", archived: false, item_count: 0 }];
    if (cmd === "sync_status") return "synced";
    if (cmd === "nav_counts") return { inbox: 0, tunnel: 0, trash: 0 };
    if (cmd === "list_items") return [];
    if (cmd === "startup_error" || cmd === "trash_after_copy") return null;
    if (cmd === "double_click_interval_ms") return 500;
    if (cmd === "pick_files") return opts.pick ?? { staged: [], errors: [] };
    if (cmd === "list_drafts") return opts.load ?? [...drafts.values()];
    if (cmd === "save_draft") {
      await opts.save;
      if (opts.saveFailures && opts.saveFailures-- > 0) throw "disk full";
      if (args.text.trim()) drafts.set(args.place, { place: args.place, text: args.text, home_topic_id: args.homeTopicId });
      else drafts.delete(args.place);
    }
    if (cmd === "capture") { await opts.capture; drafts.delete(args.draft); }
  }, { shouldMockEvents: true });
  return { drafts, calls };
}
const box = () => screen.getByRole("textbox", { name: "New Item" });
async function settle() { await act(async () => {}); }
async function start() { const app = render(<App />); await settle(); return app; }
async function open(name: string) { fireEvent.click(screen.getByRole("button", { name: new RegExp(`^${name}\\d*$`) })); await settle(); }
function type(text: string) { fireEvent.change(box(), { target: { value: text } }); }
async function tick(ms = 300) { await act(async () => { await vi.advanceTimersByTimeAsync(ms); }); }
afterEach(() => vi.useRealTimers());

test("each place keeps its own text", async () => {
  const { drafts } = backend(); await start();
  type("inbox note"); await open("Work");
  expect(drafts.get("inbox")?.text).toBe("inbox note");
  expect(box()).toHaveValue("");
  type("work note"); await open("Inbox");
  expect(box()).toHaveValue("inbox note");
  await open("Tunnel"); expect(box()).toHaveValue("");
  type("tunnel note"); await open("Home"); expect(box()).toHaveValue("");
  type("home note"); await open("Tunnel"); expect(box()).toHaveValue("tunnel note");
});

test("staged files stay with their place", async () => {
  let release!: (files: StagedFiles) => void;
  backend({ pick: new Promise<StagedFiles>(r => { release = r; }) }); await start();
  await act(() => emit("attachments-staged", { staged: [{ id: "s1", filename: "receipt.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  expect(screen.getByText("receipt.png")).toBeInTheDocument();
  await open("Work"); expect(screen.queryByText("receipt.png")).not.toBeInTheDocument();
  await open("Inbox"); expect(screen.getByText("receipt.png")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  await open("Work");
  await act(async () => release({ staged: [{ id: "s2", filename: "late.txt", size_bytes: 1, mime_type: "text/plain" }], errors: [] }));
  expect(screen.queryByText("late.txt")).not.toBeInTheDocument();
  await open("Inbox"); expect(screen.getByText("late.txt")).toBeInTheDocument();
});

test.each(["Work", "Trash"])("delayed native drop stays in Inbox after navigating to %s", async (destination) => {
  const { calls } = backend(); await start();
  await act(() => emit("attachments-staging", "drop-inbox"));
  await open(destination);
  await act(() => emit("attachments-staged", { drop_id: "drop-inbox", staged: [{ id: "late", filename: "late.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  expect(screen.queryByText("late.png")).not.toBeInTheDocument();
  expect(calls.filter(c => c.cmd === "unstage_attachment")).toHaveLength(0);
  await open("Inbox");
  expect(screen.getByText("late.png")).toBeInTheDocument();
});

test("overlapping native drops return to their places in completion order", async () => {
  backend(); await start();
  await act(() => emit("attachments-staging", "drop-inbox"));
  await open("Work");
  await act(() => emit("attachments-staging", "drop-work"));
  await act(() => emit("attachments-staged", { drop_id: "drop-work", staged: [{ id: "w", filename: "work.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  await act(() => emit("attachments-staged", { drop_id: "drop-inbox", staged: [{ id: "i", filename: "inbox.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  expect(screen.getByText("work.png")).toBeInTheDocument();
  expect(screen.queryByText("inbox.png")).not.toBeInTheDocument();
  await open("Inbox");
  expect(screen.getByText("inbox.png")).toBeInTheDocument();
  expect(screen.queryByText("work.png")).not.toBeInTheDocument();
});

test("text is saved after typing stops and restored on restart", async () => {
  const { drafts } = backend(); const app = await start(); vi.useFakeTimers();
  type("hello"); await tick(299); expect(drafts.has("inbox")).toBe(false);
  await tick(1); expect(drafts.get("inbox")?.text).toBe("hello");
  app.unmount(); vi.useRealTimers(); await start();
  expect(box()).toHaveValue("hello");
});

test("home remembers its chosen Topic", async () => {
  const { drafts } = backend(); const app = await start(); await open("Home");
  fireEvent.click(screen.getByRole("button", { name: "Topic" })); await settle();
  fireEvent.click(screen.getByRole("menuitemradio", { name: "Work" }));
  vi.useFakeTimers(); type("x"); await tick();
  expect(drafts.get("home")?.home_topic_id).toBe("work-id");
  fireEvent.click(screen.getByRole("button", { name: "Topic" }));
  fireEvent.click(screen.getByRole("menuitemradio", { name: "Inbox" })); await tick();
  expect(drafts.get("home")?.home_topic_id).toBe(null);
  fireEvent.click(screen.getByRole("button", { name: "Topic" }));
  fireEvent.click(screen.getByRole("menuitemradio", { name: "Work" })); await tick();
  app.unmount(); vi.useRealTimers(); await start();
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Work");
});

test("sending deletes only that place's draft", async () => {
  let release!: () => void;
  const { drafts, calls } = backend({ save: new Promise<void>(r => { release = r; }) });
  await start(); vi.useFakeTimers(); type("i"); await tick();
  await open("Work"); type("w"); await tick(); await open("Inbox");
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(calls.filter(c => c.cmd === "capture")).toHaveLength(0);
  await act(async () => release());
  expect(calls.find(c => c.cmd === "capture")?.args.draft).toBe("inbox");
  expect(drafts.has("inbox")).toBe(false);
  expect(drafts.get("topic:work-id")?.text).toBe("w");
  await open("Work"); expect(box()).toHaveValue("w");
});

test("a save still debouncing doesn't bring back sent text", async () => {
  const { drafts } = backend(); await start(); vi.useFakeTimers(); type("hello");
  fireEvent.keyDown(box(), { key: "Enter" }); await tick(1000);
  expect(drafts.has("inbox")).toBe(false); expect(box()).toHaveValue("");
});

test("switching place mid-send clears the place that was sent", async () => {
  let release!: () => void;
  backend({ capture: new Promise<void>(r => { release = r; }) }); await start();
  type("i"); fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  await open("Work"); type("w"); await act(async () => release());
  expect(box()).toHaveValue("w");
  await open("Inbox"); expect(box()).toHaveValue("");
});

test("typing before drafts load wins", async () => {
  let release!: (rows: Row[]) => void;
  backend({ load: new Promise<Row[]>(r => { release = r; }) }); await start();
  type("new");
  await act(async () => release([{ place: "inbox", text: "old", home_topic_id: null }, { place: "topic:work-id", text: "work old", home_topic_id: null }]));
  expect(box()).toHaveValue("new");
  await open("Work"); expect(box()).toHaveValue("work old");
});

test("blur flushes the pending save", async () => {
  const { drafts } = backend(); await start(); vi.useFakeTimers(); type("hello");
  await act(async () => { fireEvent.blur(window); });
  expect(drafts.get("inbox")?.text).toBe("hello");
});


test("a Home draft restored after its Topic was archived sends to the Inbox it shows", async () => {
  let load!: (rows: Row[]) => void;
  const { calls } = backend({ load: new Promise<Row[]>(r => { load = r; }), topicsRefresh: Promise.resolve([{ id: "work-id", name: "Work", archived: true, item_count: 0 }]) });
  await start(); await open("Home");
  await act(async () => { await emit("items-changed"); });
  await settle();
  await act(async () => load([{ place: "home", text: "for work", home_topic_id: "work-id" }]));
  expect(box()).toHaveValue("for work");
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Inbox");
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(calls.find(c => c.cmd === "capture")?.args.target).toEqual({ kind: "inbox" });
});

test("a just-created Home Topic leaves the picker once the refresh no longer has it", async () => {
  let release!: (topics: Topic[]) => void;
  backend({ topicsRefresh: new Promise<Topic[]>(r => { release = r; }) });
  await start(); await open("Home"); type("book note");
  fireEvent.click(screen.getByRole("button", { name: "Topic" }));
  fireEvent.change(screen.getByRole("searchbox", { name: "Find or create a Topic" }), { target: { value: "Books" } });
  fireEvent.click(screen.getByRole("menuitem", { name: "Create “Books”" }));
  await settle();
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Books");
  await act(async () => release([{ id: "work-id", name: "Work", archived: false, item_count: 0 }]));
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Inbox");
  fireEvent.click(screen.getByRole("button", { name: "Topic" }));
  expect(screen.queryByRole("menuitemradio", { name: "Books" })).not.toBeInTheDocument();
  expect(screen.getByRole("menuitemradio", { name: "Work" })).toBeInTheDocument();
});

test("creating a Home destination survives a delayed Topics refresh", async () => {
  let release!: (topics: Topic[]) => void;
  const { calls, drafts } = backend({ topicsRefresh: new Promise<Topic[]>(r => { release = r; }) });
  await start(); await open("Home"); type("book note");
  fireEvent.click(screen.getByRole("button", { name: "Topic" }));
  fireEvent.change(screen.getByRole("searchbox", { name: "Find or create a Topic" }), { target: { value: "Books" } });
  fireEvent.click(screen.getByRole("menuitem", { name: "Create “Books”" }));
  await settle();
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Books");
  await open("Inbox"); await open("Home");
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Books");
  await act(async () => { fireEvent.blur(window); });
  expect(drafts.get("home")?.home_topic_id).toBe("books-id");
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(calls.find(c => c.cmd === "capture")?.args.target).toEqual({ kind: "topic", id: "books-id" });
  await act(async () => release([{ id: "work-id", name: "Work", archived: false, item_count: 0 }, { id: "books-id", name: "Books", archived: false, item_count: 0 }]));
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Books");
});


test("typing in Home before drafts load keeps its text and destination together", async () => {
  let release!: (rows: Row[]) => void;
  const { calls, drafts } = backend({ load: new Promise<Row[]>(r => { release = r; }) });
  await start(); await open("Home"); type("new home note");
  await act(async () => release([{ place: "home", text: "old home note", home_topic_id: "work-id" }]));
  expect(box()).toHaveValue("new home note");
  expect(screen.getByRole("button", { name: "Topic" })).toHaveTextContent("Inbox");
  await act(async () => { fireEvent.blur(window); });
  expect(drafts.get("home")).toEqual({ place: "home", text: "new home note", home_topic_id: null });
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(calls.find(c => c.cmd === "capture")?.args.target).toEqual({ kind: "inbox" });
});

test("clear isn't offered while that box is sending", async () => {
  let release!: () => void;
  const { drafts } = backend({ capture: new Promise<void>(r => { release = r; }) });
  await start(); type("sent once");
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(screen.queryByRole("button", { name: "Clear" })).not.toBeInTheDocument();
  await act(async () => release());
  await act(async () => { fireEvent.blur(window); });
  expect(drafts.has("inbox")).toBe(false);
});

test("clear comes back after a send fails twice the same way", async () => {
  const failing = Promise.reject("disk full");
  failing.catch(() => {});
  backend({ capture: failing });
  await start(); type("keep me");
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(box()).toHaveValue("keep me");
  expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument();
});

test("a failed draft save is retried on the next flush", async () => {
  const { drafts } = backend({ saveFailures: 1 });
  await start(); type("keep");
  await act(async () => { fireEvent.blur(window); }); await settle();
  expect(drafts.has("inbox")).toBe(false);
  await act(async () => { fireEvent.blur(window); }); await settle();
  expect(drafts.get("inbox")?.text).toBe("keep");
});

test("clear shows for a box of only spaces", async () => {
  backend();
  await start(); type("  \n ");
  expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument();
});

test("clear only shows when the box has content", async () => {
  backend(); await start();
  expect(screen.queryByRole("button", { name: "Clear" })).not.toBeInTheDocument();
  type("note");
  expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument();
});

test("clear empties text and files and deletes the draft", async () => {
  const { drafts, calls } = backend(); await start(); vi.useFakeTimers();
  type("note");
  await act(() => emit("attachments-staged", { staged: [{ id: "s1", filename: "receipt.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  await tick(); expect(drafts.get("inbox")?.text).toBe("note");
  type("latest note");
  fireEvent.click(screen.getByRole("button", { name: "Clear" })); await settle();
  expect(box()).toHaveValue("");
  expect(screen.queryByText("receipt.png")).not.toBeInTheDocument();
  expect(drafts.has("inbox")).toBe(false);
  await tick(1000); expect(drafts.has("inbox")).toBe(false);
  expect(calls.filter(c => c.cmd === "unstage_attachment")).toHaveLength(0);
  expect(screen.getByText("Cleared").closest('[role="status"]')).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Undo" })).toBeInTheDocument();
  expect(box()).toHaveFocus();
});

test("the Cleared notice lasts as long as an informational one", async () => {
  backend(); await start(); vi.useFakeTimers();
  const focus = vi.spyOn(document, "hasFocus").mockReturnValue(true);
  try {
    type("note");
    fireEvent.click(screen.getByRole("button", { name: "Clear" })); await settle();
    await tick(3999); expect(screen.getByText("Cleared")).toBeInTheDocument();
    await tick(1); expect(screen.queryByText("Cleared")).not.toBeInTheDocument();
  } finally { focus.mockRestore(); }
});

test("undo restores text and files", async () => {
  const { drafts } = backend(); await start(); vi.useFakeTimers();
  type("note");
  await act(() => emit("attachments-staged", { staged: [{ id: "s1", filename: "receipt.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  fireEvent.click(screen.getByRole("button", { name: "Clear" })); await settle();
  fireEvent.click(screen.getByRole("button", { name: "Undo" })); await settle();
  expect(box()).toHaveValue("note");
  expect(screen.getByText("receipt.png")).toBeInTheDocument();
  expect(drafts.get("inbox")?.text).toBe("note");
  expect(screen.queryByText("Cleared")).not.toBeInTheDocument();
});

test.each(["metaKey", "ctrlKey"])("cmd+z in the empty box restores (%s)", async (modifier) => {
  const { drafts } = backend(); await start();
  type("note");
  fireEvent.click(screen.getByRole("button", { name: "Clear" })); await settle();
  fireEvent.keyDown(document.activeElement!, { key: "z", [modifier]: true, shiftKey: true });
  expect(box()).toHaveValue("");
  expect(screen.getByText("Cleared")).toBeInTheDocument();
  fireEvent.keyDown(document.activeElement!, { key: "z", [modifier]: true }); await settle();
  expect(box()).toHaveValue("note");
  expect(drafts.get("inbox")?.text).toBe("note");
  expect(screen.queryByText("Cleared")).not.toBeInTheDocument();
  type("");
  fireEvent.keyDown(box(), { key: "z", [modifier]: true });
  expect(box()).toHaveValue("");
});

test("undo after typing new text does nothing", async () => {
  const { drafts } = backend(); await start(); vi.useFakeTimers();
  type("old");
  fireEvent.click(screen.getByRole("button", { name: "Clear" })); await settle();
  type("fresh");
  fireEvent.click(screen.getByRole("button", { name: "Undo" })); await settle();
  expect(box()).toHaveValue("fresh");
  type("");
  fireEvent.keyDown(box(), { key: "z", metaKey: true });
  expect(box()).toHaveValue("");
  type("fresh"); await tick();
  expect(drafts.get("inbox")?.text).toBe("fresh");
});
