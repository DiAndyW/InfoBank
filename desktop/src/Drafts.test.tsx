import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { emit } from "@tauri-apps/api/event";
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { afterEach, expect, test, vi } from "vitest";
import App from "./App";
import { behaviourTest, noticeMessage } from "./behaviour-test";
import type { Staged, StagedFiles, Topic } from "./api";

type Row = { place: string; text: string; home_topic_id: string | null; attachments?: Staged[] };
function backend(opts: { load?: Promise<Row[]>; capture?: Promise<void>; save?: Promise<void>; pick?: Promise<StagedFiles>; topicsRefresh?: Promise<Topic[]>; saveFailures?: number; updateReady?: boolean } = {}) {
  localStorage.setItem("place", "inbox");
  const drafts = new Map<string, Row>();
  const calls: { cmd: string; args: any }[] = [];
  let topicLoads = 0;
  mockWindows("main");
  mockIPC(async (cmd, args: any) => {
    calls.push({ cmd, args });
    if (cmd === "get_settings") return { server_url: "https://example.test", has_secret: true, quick_capture: { shortcut: "shift+super+Space", on: true } };
    if (cmd === "list_topics" && topicLoads++ > 0 && opts.topicsRefresh) return opts.topicsRefresh;
    if (cmd === "picker_topic") { await emit("items-changed"); return { id: "books-id", name: args.name, activity_at_us: 1794629106000000, item_count: 0 }; }
    if (cmd === "list_topics") return [{ id: "work-id", name: "Work", activity_at_us: 1794629106000000, item_count: 0 }];
    if (cmd === "sync_status") return "synced";
    if (cmd === "update_status") return { current_version: "0.1.0", status: opts.updateReady ? { state: "ready", version: "0.2.0" } : { state: "off" } };
    if (cmd === "nav_counts") return { inbox: 0, tunnel: 0, trash: 0 };
    if (cmd === "list_items") return [];
    if (cmd === "startup_error" || cmd === "trash_after_copy") return null;
    if (cmd === "double_click_interval_ms") return 500;
    if (cmd === "pick_files") return opts.pick ?? { staged: [], errors: [] };
    if (cmd === "list_drafts") return (await (opts.load ?? [...drafts.values()])).map(row => ({ ...row, attachments: row.attachments ?? [] }));
    if (cmd === "save_draft") {
      await opts.save;
      if (opts.saveFailures && opts.saveFailures-- > 0) throw "disk full";
      if (args.text.trim() || args.attachmentIds?.length) drafts.set(args.place, { place: args.place, text: args.text, home_topic_id: args.homeTopicId, ...(args.attachmentIds?.length ? { attachments: args.attachmentIds.map((id: string) => ({ ...file, id })) } : {}) });
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
  expect(screen.getByRole("button", { name: "receipt.png" })).toBeInTheDocument();
  await open("Work"); expect(screen.queryByRole("button", { name: "receipt.png" })).not.toBeInTheDocument();
  await open("Inbox"); expect(screen.getByRole("button", { name: "receipt.png" })).toBeInTheDocument();
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
  expect(screen.queryByRole("button", { name: "late.png" })).not.toBeInTheDocument();
  expect(calls.filter(c => c.cmd === "unstage_attachment")).toHaveLength(0);
  await open("Inbox");
  expect(screen.getByRole("button", { name: "late.png" })).toBeInTheDocument();
});

test("overlapping native drops return to their places in completion order", async () => {
  backend(); await start();
  await act(() => emit("attachments-staging", "drop-inbox"));
  await open("Work");
  await act(() => emit("attachments-staging", "drop-work"));
  await act(() => emit("attachments-staged", { drop_id: "drop-work", staged: [{ id: "w", filename: "work.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  await act(() => emit("attachments-staged", { drop_id: "drop-inbox", staged: [{ id: "i", filename: "inbox.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  expect(screen.getByRole("button", { name: "work.png" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "inbox.png" })).not.toBeInTheDocument();
  await open("Inbox");
  expect(screen.getByRole("button", { name: "inbox.png" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "work.png" })).not.toBeInTheDocument();
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

test("a Home draft restored after its Topic was deleted sends to the Inbox it shows", async () => {
  let load!: (rows: Row[]) => void;
  const { calls } = backend({ load: new Promise<Row[]>(r => { load = r; }), topicsRefresh: Promise.resolve([]) });
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
  await act(async () => release([{ id: "work-id", name: "Work", activity_at_us: 1794629106000000, item_count: 0 }]));
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
  await act(async () => release([{ id: "work-id", name: "Work", activity_at_us: 1794629106000000, item_count: 0 }, { id: "books-id", name: "Books", activity_at_us: 1794629106000000, item_count: 0 }]));
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
  expect(screen.queryByRole("button", { name: "Clear draft" })).not.toBeInTheDocument();
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
  expect(screen.getByRole("button", { name: "Clear draft" })).toBeInTheDocument();
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
  expect(screen.getByRole("button", { name: "Clear draft" })).toBeInTheDocument();
});

test("clear only shows when the box has content", async () => {
  backend(); await start();
  expect(screen.queryByRole("button", { name: "Clear draft" })).not.toBeInTheDocument();
  type("note");
  expect(screen.getByRole("button", { name: "Clear draft" })).toBeInTheDocument();
});

test("clear empties text and files and deletes the draft", async () => {
  const { drafts, calls } = backend(); await start(); vi.useFakeTimers();
  type("note");
  await act(() => emit("attachments-staged", { staged: [{ id: "s1", filename: "receipt.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  await tick(); expect(drafts.get("inbox")?.text).toBe("note");
  type("latest note");
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  expect(box()).toHaveValue("");
  expect(screen.queryByRole("button", { name: "receipt.png" })).not.toBeInTheDocument();
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
    fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
    await tick(3999); expect(screen.getByText("Cleared")).toBeInTheDocument();
    await tick(1); expect(screen.queryByText("Cleared")).not.toBeInTheDocument();
  } finally { focus.mockRestore(); }
});

test("undo restores text and files", async () => {
  const { drafts } = backend(); await start(); vi.useFakeTimers();
  type("note");
  await act(() => emit("attachments-staged", { staged: [{ id: "s1", filename: "receipt.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  fireEvent.click(screen.getByRole("button", { name: "Undo" })); await settle();
  expect(box()).toHaveValue("note");
  expect(screen.getByRole("button", { name: "receipt.png" })).toBeInTheDocument();
  expect(drafts.get("inbox")?.text).toBe("note");
  expect(screen.queryByText("Cleared")).not.toBeInTheDocument();
});

test.each(["metaKey", "ctrlKey"])("cmd+z in the empty box restores (%s)", async (modifier) => {
  const { drafts } = backend(); await start();
  type("note");
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
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
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  type("fresh");
  fireEvent.click(screen.getByRole("button", { name: "Undo" })); await settle();
  expect(box()).toHaveValue("fresh");
  type("");
  fireEvent.keyDown(box(), { key: "z", metaKey: true });
  expect(box()).toHaveValue("");
  type("fresh"); await tick();
  expect(drafts.get("inbox")?.text).toBe("fresh");
});

test.each([false, true])("restart_waits_for_capture_and_preserves_only_failed_text (fails=%s)", async (fails) => {
  let release!: () => void;
  let reject!: (reason: string) => void;
  let save!: () => void;
  const { calls, drafts } = backend({
    updateReady: true,
    capture: new Promise<void>((resolve, fail) => { release = resolve; reject = fail; }),
    save: new Promise<void>(r => { save = r; }),
  });
  await start(); vi.useFakeTimers();
  type("keep until captured");
  fireEvent.keyDown(box(), { key: "Enter" }); await settle();
  expect(calls.some(c => c.cmd === "capture")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Restart" })); await settle();
  expect(calls.some(c => c.cmd === "restart_to_update")).toBe(false);
  await act(async () => { if (fails) reject("capture failed"); else release(); });
  if (fails) {
    expect(calls.find(c => c.cmd === "save_draft")?.args).toMatchObject({ place: "inbox", text: "keep until captured" });
    expect(calls.some(c => c.cmd === "restart_to_update")).toBe(false);
    await act(async () => save());
    expect(drafts.get("inbox")?.text).toBe("keep until captured");
  } else {
    await tick(1000);
    expect(calls.filter(c => c.cmd === "save_draft")).toHaveLength(0);
    expect(drafts.has("inbox")).toBe(false);
  }
  expect(calls.filter(c => c.cmd === "restart_to_update")).toHaveLength(1);
});


test("restart_waits_for_the_open_picker_and_persists_its_files", async () => {
  let pick!: (files: StagedFiles) => void;
  const { calls } = backend({ updateReady: true, pick: new Promise<StagedFiles>(r => { pick = r; }) });
  await start();
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  await settle();
  fireEvent.click(screen.getByRole("button", { name: "Restart" }));
  await settle();
  expect(calls.some(c => c.cmd === "restart_to_update")).toBe(false);
  await act(async () => pick({ staged: [{ id: "picked", filename: "picked.txt", size_bytes: 1, mime_type: "text/plain" }], errors: [] }));
  expect(calls.find(c => c.cmd === "save_draft")?.args.attachmentIds).toEqual(["picked"]);
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  expect(calls.filter(c => c.cmd === "restart_to_update")).toHaveLength(1);
});

test("composer grows with text and shrinks after Clear", async () => {
  backend(); await start();
  const el = box() as HTMLTextAreaElement;
  let height = 56;
  Object.defineProperty(el, "scrollHeight", { get: () => height });
  height = 104;
  type("wrapped text");
  expect(el.style.height).toBe("104px");
  height = 56;
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" }));
  await settle();
  expect(el.style.height).toBe("56px");
});

test("composer holds its row's height while measuring so the Feed above isn't resized", async () => {
  backend(); await start();
  const el = box() as HTMLTextAreaElement;
  const row = el.parentElement!;
  Object.defineProperty(row, "offsetHeight", { value: 152 });
  const rowHeights: string[] = [];
  Object.defineProperty(el, "scrollHeight", { get: () => { rowHeights.push(row.style.height); return 152; } });
  type("wrapped text");
  expect(rowHeights[0]).toBe("152px");
  expect(row.style.height).toBe("");
});

test("composer refits when its row changes size, such as a sidebar toggle", async () => {
  const observed = new Map<Element, ResizeObserverCallback>();
  const Original = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    constructor(private callback: ResizeObserverCallback) {}
    observe(target: Element) { observed.set(target, this.callback); }
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver;
  try {
    backend(); await start();
    const el = box() as HTMLTextAreaElement;
    const resize = () => observed.get(el.parentElement!)!([], {} as ResizeObserver);
    let height = 104;
    Object.defineProperty(el, "scrollHeight", { get: () => height });
    Object.defineProperty(el, "clientHeight", { get: () => Math.min(height, 120) });
    resize();
    expect(el.style.height).toBe("104px");
    expect(el.style.overflowY).toBe("hidden");
    height = 200;
    resize();
    expect(el.style.height).toBe("200px");
    expect(el.style.overflowY).toBe("auto");
    height = 56;
    resize();
    expect(el.style.height).toBe("56px");
    expect(el.style.overflowY).toBe("hidden");
  } finally { globalThis.ResizeObserver = Original; }
});

behaviourTest("failure.draft", async expected => {
  const options = { saveFailures: 3 };
  backend(options);
  await start(); type("keep");
  for (let attempt = 1; attempt <= 3; attempt++) {
    await act(async () => { fireEvent.blur(window); }); await settle();
    expect(screen.queryByText(`${expected.message} disk full`) !== null).toBe(attempt === 3);
  }
  await act(async () => { fireEvent.blur(window); }); await settle();
  expect(screen.queryByText(`${expected.message} disk full`)).not.toBeInTheDocument();
  options.saveFailures = 1;
  type("keep editing");
  await act(async () => { fireEvent.blur(window); }); await settle();
  expect(screen.queryByText(`${expected.message} disk full`)).not.toBeInTheDocument();
});

test("draft failures and recovery preserve the Send error", async () => {
  const failure = Promise.reject("This Topic was deleted.");
  failure.catch(() => {});
  backend({ capture: failure, saveFailures: 4 });
  await start(); type("keep");
  fireEvent.click(screen.getByRole("button", { name: "Send" })); await settle();
  for (let attempt = 0; attempt < 5; attempt++) {
    await act(async () => { fireEvent.blur(window); }); await settle();
    expect(screen.getByText("Item failed to send. This Topic was deleted.")).toBeInTheDocument();
  }
});

behaviourTest("notice.cleared", async expected => {
  backend(); await start();
  type("a note");
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  const notice = screen.getByText(noticeMessage(expected)).closest('[role="status"]')! as HTMLElement;
  expect(within(notice).getAllByRole("button").map(button => button.textContent || "close")).toEqual(expected.buttons);
});

const file: Staged = { id: "owned", filename: "owned.txt", size_bytes: 3, mime_type: "text/plain" };
test("queued attachment work preserves text typed after a queued blur save", async () => {
  const opts: { save?: Promise<void> } = {};
  const { drafts } = backend(opts);
  const app = await start();
  vi.useFakeTimers();
  type("original");
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  let release!: () => void;
  opts.save = new Promise(resolve => { release = resolve; });
  fireEvent.click(screen.getByRole("button", { name: `Remove ${file.filename}` }));
  await settle();
  await act(() => emit("attachments-staged", { staged: [{ ...file, id: "new", filename: "new.txt" }], errors: [] }));
  type("intermediate");
  fireEvent.blur(window);
  await settle();
  type("latest");
  await act(async () => release());
  await tick(1000);
  expect(box()).toHaveValue("latest");
  expect(drafts.get("inbox")?.text).toBe("latest");
  expect(drafts.get("inbox")?.attachments?.map(attachment => attachment.id)).toEqual(["new"]);
  app.unmount();
  await start();
  expect(box()).toHaveValue("latest");
});

test.each(["button", "Enter"])("Send through %s waits for accepted attachment ownership", async trigger => {
  let save!: () => void;
  const { drafts, calls } = backend({ save: new Promise(resolve => { save = resolve; }) });
  await start();
  type("send with file");
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  if (trigger === "button") fireEvent.click(screen.getByRole("button", { name: "Send" }));
  else fireEvent.keyDown(box(), { key: "Enter" });
  await settle();
  expect(calls.filter(call => call.cmd === "capture")).toHaveLength(0);
  expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
  await act(async () => save());
  expect(drafts.get("inbox")?.attachments?.map(attachment => attachment.id)).toEqual([file.id]);
  expect(screen.getByText(file.filename)).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Send" }));
  await settle();
  expect(calls.find(call => call.cmd === "capture")?.args.attachmentIds).toEqual([file.id]);
  expect(drafts.has("inbox")).toBe(false);
  expect(screen.queryByText(file.filename)).not.toBeInTheDocument();
});

behaviourTest("composer.draft_attachments", async expected => {
  const { drafts } = backend(); const app = await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual(expected.offered ? [file.id] : []);
  app.unmount(); await start();
  expect(screen.queryByText(file.filename) !== null).toBe(expected.offered);
  fireEvent.click(screen.getByRole("button", { name: `Remove ${file.filename}` })); await settle();
  expect(drafts.has("inbox")).toBe(false);
});

test("attachment edits win delayed hydration while inactive files restore", async () => {
  let load!: (rows: Row[]) => void;
  backend({ load: new Promise<Row[]>(r => { load = r; }) }); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  await act(async () => load([
    { place: "inbox", text: "old", home_topic_id: null, attachments: [{ ...file, id: "old" }] },
    { place: "topic:work-id", text: "", home_topic_id: null, attachments: [{ ...file, id: "inactive" }] },
  ]));
  expect(box()).toHaveValue("");
  await open("Work"); expect(screen.getByText(file.filename)).toBeInTheDocument();
});

test("late picker persists origin immediately after navigation", async () => {
  let pick!: (files: StagedFiles) => void;
  const { drafts } = backend({ pick: new Promise(r => { pick = r; }) }); await start();
  fireEvent.click(screen.getByRole("button", { name: "Attach files" })); await open("Work");
  await act(async () => pick({ staged: [file], errors: [] }));
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([file.id]);
  expect(drafts.has("topic:work-id")).toBe(false);
});

test("failed ownership save keeps retryable files and reports immediately", async () => {
  const { drafts } = backend({ saveFailures: 1 }); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  expect(screen.getByRole("alert")).toHaveTextContent("Draft failed to save.");
  expect(screen.getByText(file.filename)).toBeInTheDocument();
  await act(async () => fireEvent.blur(window));
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([file.id]);
});

test("Clear invalidates an accepted picker and Undo restores ownership", async () => {
  let pick!: (files: StagedFiles) => void;
  const { drafts } = backend({ pick: new Promise(r => { pick = r; }) }); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  await act(async () => pick({ staged: [{ ...file, id: "late", filename: "late.txt" }], errors: [] }));
  expect(screen.queryByText("late.txt")).not.toBeInTheDocument();
  expect(drafts.has("inbox")).toBe(false);
  fireEvent.click(screen.getByRole("button", { name: "Undo" })); await settle();
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([file.id]);
});

test.each(["before", "after"])("failed Clear preserves a pending picker completed %s its save fails", async completion => {
  let pick!: (files: StagedFiles) => void;
  let save!: () => void;
  const opts = { pick: new Promise<StagedFiles>(resolve => { pick = resolve; }), save: new Promise<void>(resolve => { save = resolve; }), saveFailures: 1 };
  const { drafts, calls } = backend(opts); const app = await start(); vi.useFakeTimers();
  type("keep this text");
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  if (completion === "before") await act(async () => pick({ staged: [file], errors: [] }));
  await act(async () => save());
  expect(box()).toHaveValue("keep this text");
  expect(screen.getByRole("alert")).toHaveTextContent("Draft failed to save.");
  expect(screen.queryByText("Cleared")).toBeNull();
  if (completion === "after") await act(async () => pick({ staged: [file], errors: [] }));
  expect(calls.filter(call => call.cmd === "unstage_attachment")).toHaveLength(0);
  expect(screen.getByText(file.filename)).toBeInTheDocument();
  expect(drafts.get("inbox")?.text).toBe("keep this text");
  expect(drafts.get("inbox")?.attachments?.map(attachment => attachment.id)).toEqual([file.id]);
  app.unmount(); await start();
  expect(box()).toHaveValue("keep this text");
  expect(screen.getByText(file.filename)).toBeInTheDocument();
});

test("restart flush failure unfreezes without losing attachments", async () => {
  const opts = { updateReady: true, saveFailures: 0 };
  const { calls } = backend(opts); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  type("latest"); opts.saveFailures = 1;
  fireEvent.click(screen.getByRole("button", { name: "Restart" })); await settle();
  expect(calls.some(c => c.cmd === "restart_to_update")).toBe(false);
  expect(box()).not.toHaveAttribute("readonly");
  expect(screen.getByText(file.filename)).toBeInTheDocument();
});

test("failed detach preserves visible file and never deletes bytes", async () => {
  const opts = { saveFailures: 0 }; const { calls } = backend(opts); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  opts.saveFailures = 1;
  fireEvent.click(screen.getByRole("button", { name: `Remove ${file.filename}` })); await settle();
  expect(screen.getByText(file.filename)).toBeInTheDocument();
  expect(calls.filter(c => c.cmd === "unstage_attachment")).toHaveLength(0);
});

test("overlapping pickers preserve both origin files even after navigation", async () => {
  let pick!: (files: StagedFiles) => void;
  const { drafts } = backend({ pick: new Promise(r => { pick = r; }) }); await start();
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  await open("Work");
  await act(async () => pick({ staged: [{ ...file, id: "second" }], errors: [] }));
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual(["second", file.id]);
});

test("completed attachment waits for ownership commit", async () => {
  let save!: () => void;
  const { drafts } = backend({ save: new Promise(r => { save = r; }) }); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  expect(screen.queryByText(file.filename)).not.toBeInTheDocument();
  expect(screen.getByLabelText("1 import pending")).toBeInTheDocument();
  await act(async () => save());
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([file.id]);
  expect(screen.getByText(file.filename)).toBeInTheDocument();
});

test("blur during delayed Clear cannot resurrect its snapshot", async () => {
  let save!: () => void;
  const { drafts } = backend({ save: new Promise(r => { save = r; }) }); await start();
  type("clear me");
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" }));
  await act(async () => fireEvent.blur(window));
  await act(async () => save());
  expect(drafts.has("inbox")).toBe(false);
});

test("Clear protects its snapshot while detach is committing", async () => {
  let save!: () => void;
  backend({ save: new Promise(r => { save = r; }) }); await start();
  type("snapshot");
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  expect(box()).toHaveAttribute("readonly");
  type("would be lost");
  expect(box()).toHaveValue("snapshot");
  await act(async () => save());
  expect(box()).not.toHaveAttribute("readonly");
});

test("missing-original Send keeps restored metadata and text", async () => {
  const failed = Promise.reject("An attachment is missing; add it again"); failed.catch(() => {});
  const { drafts } = backend({ load: Promise.resolve([{ place: "inbox", text: "keep", home_topic_id: null, attachments: [file] }]), capture: failed });
  await start(); fireEvent.click(screen.getByRole("button", { name: "Send" })); await settle();
  expect(box()).toHaveValue("keep");
  expect(screen.getByText(file.filename)).toBeInTheDocument();
  expect(screen.getByRole("alert")).toHaveTextContent("Item failed to send. An attachment is missing; add it again");
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([file.id]);
});

test("Clear survives remount without deleting Undo bytes", async () => {
  const { calls, drafts } = backend(); const app = await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  app.unmount(); await start();
  expect(drafts.has("inbox")).toBe(false);
  expect(screen.queryByText(file.filename)).not.toBeInTheDocument();
  expect(calls.filter(c => c.cmd === "unstage_attachment")).toHaveLength(0);
});

test("accepted picker cannot repopulate after Send", async () => {
  let pick!: (files: StagedFiles) => void;
  const { drafts } = backend({ pick: new Promise(r => { pick = r; }) }); await start();
  type("send"); fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  fireEvent.click(screen.getByRole("button", { name: "Send" })); await settle();
  await act(async () => pick({ staged: [file], errors: [] }));
  expect(screen.queryByText(file.filename)).not.toBeInTheDocument();
  expect(drafts.has("inbox")).toBe(false);
});

test("failed detach preserves overlapping successful origin import", async () => {
  const opts: { save?: Promise<void>; saveFailures?: number; pick?: Promise<StagedFiles> } = {};
  let pick!: (files: StagedFiles) => void;
  opts.pick = new Promise(resolve => { pick = resolve; });
  const { drafts, calls } = backend(opts); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  let save!: () => void;
  opts.save = new Promise(resolve => { save = resolve; }); opts.saveFailures = 1;
  fireEvent.click(screen.getByRole("button", { name: "Remove owned.txt" })); await settle();
  await open("Work");
  const other = { ...file, id: "new", filename: "new.txt" };
  await act(async () => pick({ staged: [other], errors: [] }));
  await act(async () => save());
  await open("Inbox");
  expect(screen.getByText(other.filename)).toBeInTheDocument();
  expect(screen.getByText(file.filename)).toBeInTheDocument();
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([file.id, other.id]);
  expect(calls.filter(c => c.cmd === "unstage_attachment")).toHaveLength(0);
});

test("removal waits for prior ownership mutation without losing its import", async () => {
  const opts: { save?: Promise<void> } = {};
  const { drafts } = backend(opts); await start();
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  let save!: () => void;
  opts.save = new Promise(resolve => { save = resolve; });
  const other = { ...file, id: "new", filename: "new.txt" };
  await act(() => emit("attachments-staged", { staged: [other], errors: [] }));
  fireEvent.click(screen.getByRole("button", { name: "Remove owned.txt" })); await settle();
  await act(async () => save());
  expect(screen.getByText(other.filename)).toBeInTheDocument();
  expect(screen.queryByText(file.filename)).not.toBeInTheDocument();
  expect(drafts.get("inbox")?.attachments?.map(f => f.id)).toEqual([other.id]);
});

test.each(["button", "Enter", "Clear"])("%s cannot consume a pending removal snapshot", async trigger => {
  const opts: { save?: Promise<void> } = {};
  const { drafts, calls } = backend(opts); await start();
  type("keep text");
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  let save!: () => void;
  opts.save = new Promise(resolve => { save = resolve; });
  fireEvent.click(screen.getByRole("button", { name: "Remove owned.txt" })); await settle();
  if (trigger === "Enter") fireEvent.keyDown(box(), { key: "Enter" });
  else fireEvent.click(screen.getByRole("button", { name: trigger === "button" ? "Send" : "Clear draft" }));
  await settle();
  expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
  expect(screen.getByRole("button", { name: "Clear draft" })).toBeDisabled();
  expect(calls.filter(c => c.cmd === "capture")).toHaveLength(0);
  await act(async () => save());
  expect(box()).toHaveValue("keep text");
  expect(drafts.get("inbox")?.text).toBe("keep text");
  expect(drafts.get("inbox")?.attachments ?? []).toEqual([]);
});

behaviourTest("composer.clear", async expected => {
  let finish!: (files: StagedFiles) => void;
  const { calls } = backend({ updateReady: true, pick: new Promise(r => { finish = r; }) }); await start();
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  expect(screen.getByRole("button", { name: expected.label! })).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: expected.label! })); await settle();
  expect(screen.queryByLabelText("1 import pending")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Restart" })); await settle();
  expect(calls.some(c => c.cmd === "restart_to_update")).toBe(false);
  await act(async () => finish({ staged: [file], errors: ["stale failure"] }));
  expect(screen.queryByText(file.filename)).toBeNull();
  expect(screen.queryByText("stale failure")).toBeNull();
  expect(calls.some(c => c.cmd === "restart_to_update")).toBe(true);
});

test("Clear retires old barriers without affecting another origin or new publication", async () => {
  let finish!: (files: StagedFiles) => void;
  const { drafts } = backend({ pick: new Promise(r => { finish = r; }) }); await start();
  type("old");
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  await open("Work");
  await act(() => emit("attachments-staging", "work-pending"));
  await open("Inbox");
  fireEvent.click(screen.getByRole("button", { name: "Clear draft" })); await settle();
  expect(screen.queryByLabelText("1 import pending")).toBeNull();
  await act(() => emit("attachments-staged", { staged: [{ ...file, id: "new", filename: "new.txt" }], errors: [] }));
  expect(screen.getByText("new.txt")).toBeInTheDocument();
  await open("Work");
  expect(screen.getByLabelText("1 import pending")).toBeInTheDocument();
  await act(async () => finish({ staged: [file], errors: ["stale failure"] }));
  expect(screen.getByLabelText("1 import pending")).toBeInTheDocument();
  await act(() => emit("attachments-staged", { drop_id: "work-pending", staged: [{ ...file, id: "work" }], errors: [] }));
  expect(drafts.get("topic:work-id")?.attachments?.map(f => f.id)).toEqual(["work"]);
  expect(screen.queryByText("stale failure")).toBeNull();
});
