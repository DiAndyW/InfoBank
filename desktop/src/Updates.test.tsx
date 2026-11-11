import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { emit } from "@tauri-apps/api/event";
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { expect, test, vi } from "vitest";
import App from "./App";

type Status = { state: string; version?: string; checked_at?: string };
const now = new Date("2026-11-07T12:00:00Z");

function backend(status: Status, configured = true, opts: { save?: Promise<void> | ((text: string) => Promise<void>); restartError?: string; install?: Promise<void>; checkError?: string } = {}) {
  localStorage.setItem("place", "inbox");
  const calls: string[] = [];
  mockWindows("main");
  mockIPC(async (cmd, args) => {
    calls.push(cmd);
    if (cmd === "get_settings") return { server_url: configured ? "https://notes.example.com" : null, has_secret: configured, quick_capture: { shortcut: "shift+super+Space", on: true } };
    if (cmd === "update_status") return { current_version: "0.1.0", status };
    if (cmd === "sync_status") return "synced";
    if (cmd === "nav_counts") return { inbox: 0, tunnel: 0, trash: 0 };
    if (cmd === "list_topics") return [{ id: "work-id", name: "Work", archived: false, item_count: 0 }];
    if (["list_items", "list_drafts"].includes(cmd)) return [];
    if (cmd === "save_draft") { await (typeof opts.save === "function" ? opts.save((args as { text: string }).text) : opts.save); localStorage.setItem("saved-draft", JSON.stringify(args)); }
    if (cmd === "restart_to_update") { await opts.install; if (opts.restartError) throw opts.restartError; }
    if (cmd === "check_for_updates" && opts.checkError) throw opts.checkError;
    if (["autostart_on", "trash_after_copy"].includes(cmd)) return false;
    return null;
  }, { shouldMockEvents: true });
  return calls;
}

async function settings(status: Status, configured = true) {
  const calls = backend(status, configured);
  render(<App />);
  if (configured) fireEvent.click(await screen.findByRole("button", { name: "Settings" }));
  await screen.findByRole("heading", { name: "Settings" });
  return calls;
}

test("the_sidebar_shows_update_ready_only_when_ready", async () => {
  const calls = backend({ state: "checking" });
  render(<App />);
  await screen.findByRole("button", { name: "Settings" });
  for (const status of [{ state: "checking" }, { state: "downloading", version: "0.2.0" }, { state: "up_to_date", checked_at: now.toISOString() }]) {
    await act(() => emit("update-status", status));
    expect(screen.queryByText("Update ready")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Restart" })).not.toBeInTheDocument();
  }
  await act(() => emit("update-status", { state: "ready", version: "0.2.0" }));
  expect(screen.getByText("Update ready")).toBeInTheDocument();
  await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Restart" })); });
  expect(calls).toContain("restart_to_update");
  await act(() => emit("update-status", { state: "offline" }));
  expect(screen.queryByText("Update ready")).not.toBeInTheDocument();
});

test.each([
  [{ state: "checking" }, "Checking…"],
  [{ state: "up_to_date", checked_at: now.toISOString() }, "Up to date, just now"],
  [{ state: "up_to_date", checked_at: "2026-11-07T10:00:00Z" }, "Up to date, 2 hours ago"],
  [{ state: "downloading", version: "0.2.0" }, "Downloading version 0.2.0…"],
  [{ state: "ready", version: "0.2.0" }, "Version 0.2.0 is ready"],
  [{ state: "offline" }, "No connection, try again later"],
  [{ state: "failed" }, "Couldn't update, try again later"],
] as const)("settings_shows_each_status_line: %s", async (status, text) => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  try {
    await settings(status);
    expect(screen.getByText(text)).toBeInTheDocument();
  } finally { vi.useRealTimers(); }
});

test("check_for_updates_is_disabled_while_busy_and_hidden_when_off", async () => {
  const calls = await settings({ state: "checking" });
  expect(screen.getByRole("button", { name: "Check for updates" })).toBeDisabled();
  await act(() => emit("update-status", { state: "downloading", version: "0.2.0" }));
  expect(screen.getByRole("button", { name: "Check for updates" })).toBeDisabled();
  await act(() => emit("update-status", { state: "offline" }));
  fireEvent.click(screen.getByRole("button", { name: "Check for updates" }));
  expect(calls).toContain("check_for_updates");
  await act(() => emit("update-status", { state: "off" }));
  expect(screen.queryByRole("button", { name: "Check for updates" })).not.toBeInTheDocument();
  const row = screen.getByText("Version", { exact: true }).parentElement!;
  expect(row).toHaveTextContent("Version0.1.0");
  expect(within(row).queryByRole("button")).not.toBeInTheDocument();
  expect(screen.queryByText("No connection, try again later")).not.toBeInTheDocument();
});

test("settings_offers_restart_when_ready", async () => {
  const calls = await settings({ state: "ready", version: "0.2.0" });
  expect(screen.getByText("Version 0.2.0 is ready")).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Check for updates" })).not.toBeInTheDocument();
  await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Restart to update" })); });
  expect(calls).toContain("restart_to_update");
});

test.each([true, false])("settings_shows_the_running_version (configured=%s)", async (configured) => {
  await settings({ state: "off" }, configured);
  expect(screen.getByText("Version", { exact: true })).toBeInTheDocument();
  expect(screen.getByText("0.1.0")).toBeInTheDocument();
});

test("settings_refreshes_relative_time_each_minute", async () => {
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  vi.setSystemTime(now);
  try {
    await settings({ state: "up_to_date", checked_at: now.toISOString() });
    expect(screen.getByText("Up to date, just now")).toBeInTheDocument();
    await act(() => vi.advanceTimersByTimeAsync(60_000));
    expect(screen.getByText("Up to date, 1 minute ago")).toBeInTheDocument();
  } finally { vi.useRealTimers(); }
});

async function ready(opts: Parameters<typeof backend>[2] = {}) {
  const calls = backend({ state: "ready", version: "0.2.0" }, true, opts);
  render(<App />);
  await screen.findByRole("textbox", { name: "New Item" });
  return calls;
}
const typeDraft = (text: string) => fireEvent.change(screen.getByRole("textbox", { name: "New Item" }), { target: { value: text } });
async function restart() { await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Restart" })); }); }
async function work() { await act(async () => { fireEvent.click(screen.getByRole("button", { name: /^Work\d*$/ })); }); }

test.each(["sidebar", "Settings"])("restart_waits_for_text_typed_a_moment_ago (%s)", async (source) => {
  let release!: () => void;
  const calls = await ready({ save: new Promise<void>(r => { release = r; }) });
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  try {
    typeDraft("just typed");
    if (source === "Settings") {
      fireEvent.click(screen.getByRole("button", { name: "Settings" }));
      await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Restart to update" })); });
    } else await restart();
    expect(calls).not.toContain("restart_to_update");
    expect(calls).toContain("save_draft");
    await act(async () => release());
    expect(calls).toContain("restart_to_update");
    expect(JSON.parse(localStorage.getItem("saved-draft")!)).toMatchObject({ place: "inbox", text: "just typed" });
  } finally { vi.useRealTimers(); }
});

test("restart_waits_for_another_places_save_in_flight", async () => {
  let release!: () => void;
  const calls = await ready({ save: new Promise<void>(r => { release = r; }) });
  typeDraft("Inbox text");
  await work();
  expect(calls).toContain("save_draft");
  await restart();
  expect(calls).not.toContain("restart_to_update");
  await act(async () => release());
  expect(calls).toContain("restart_to_update");
});

test("a_failed_draft_save_does_not_restart", async () => {
  let reject!: (reason: string) => void;
  const calls = await ready({ save: new Promise<void>((_, r) => { reject = r; }) });
  typeDraft("keep this");
  await work();
  expect(calls).toContain("save_draft");
  await restart();
  await act(async () => reject("disk full"));
  expect(calls).not.toContain("restart_to_update");
  expect(screen.getByRole("alertdialog", { name: "Couldn't save your drafts" })).toHaveTextContent("disk full");
  expect(screen.getByText("Update ready")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "OK" }));
  await act(async () => { fireEvent.click(screen.getByRole("button", { name: /^Inbox\d*$/ })); });
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveValue("keep this");
});

test.each([1, 2])("unsent_files_anywhere_ask_first (%s)", async (count) => {
  const calls = await ready();
  await act(() => emit("attachments-staged", { staged: [{ id: "one", filename: "one.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  await work();
  if (count === 2) await act(() => emit("attachments-staged", { staged: [{ id: "two", filename: "two.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  await restart();
  const title = count === 1 ? "Restart and remove 1 unsent file?" : "Restart and remove 2 unsent files?";
  const dialog = screen.getByRole("alertdialog", { name: title });
  expect(dialog).toHaveTextContent("Files you attached but haven't sent aren't kept across a restart.");
  expect(calls).not.toContain("restart_to_update");
  fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  expect(calls).not.toContain("restart_to_update");
  await restart();
  await act(async () => { fireEvent.click(within(screen.getByRole("alertdialog", { name: title })).getByRole("button", { name: "Restart" })); });
  expect(calls).toContain("restart_to_update");
});

test("no_files_no_question", async () => {
  const calls = await ready();
  await restart();
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  expect(calls).toContain("restart_to_update");
});

test.each([true, false])("restart_errors_are_visible_in_Settings (configured=%s)", async (configured) => {
  backend({ state: "ready", version: "0.2.0" }, configured, { restartError: "install failed" });
  render(<App />);
  if (configured) fireEvent.click(await screen.findByRole("button", { name: "Settings" }));
  fireEvent.click(await screen.findByRole("button", { name: "Restart to update" }));
  expect(await screen.findByRole("alertdialog", { name: "Couldn't update" })).toHaveTextContent("install failed");
});

test("check_errors_are_visible_in_first_run_Settings", async () => {
  backend({ state: "offline" }, false, { checkError: "check failed" });
  render(<App />);
  fireEvent.click(await screen.findByRole("button", { name: "Check for updates" }));
  expect(await screen.findByRole("alertdialog", { name: "Couldn't update" })).toHaveTextContent("check failed");
});

test.each([false, true])("restart_drains_saves_queued_during_its_wait (reject=%s)", async (fails) => {
  let releaseA!: () => void;
  let releaseB!: () => void;
  let rejectB!: (reason: string) => void;
  const a = new Promise<void>(r => { releaseA = r; });
  const b = new Promise<void>((resolve, reject) => { releaseB = resolve; rejectB = reject; });
  const calls = await ready({ save: text => text === "A" ? a : b });
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  try {
    typeDraft("A");
    await act(async () => { fireEvent.blur(window); });
    typeDraft("B");
    await act(() => vi.advanceTimersByTimeAsync(300));
    await restart();
    await act(async () => releaseA());
    expect(calls.filter(cmd => cmd === "save_draft")).toHaveLength(2);
    expect(calls).not.toContain("restart_to_update");
    if (fails) {
      await act(async () => rejectB("disk full"));
      expect(calls).not.toContain("restart_to_update");
      expect(screen.getByRole("alertdialog", { name: "Couldn't save your drafts" })).toHaveTextContent("disk full");
    } else {
      await act(async () => releaseB());
      expect(calls).toContain("restart_to_update");
      expect(JSON.parse(localStorage.getItem("saved-draft")!)).toMatchObject({ text: "B" });
    }
  } finally { vi.useRealTimers(); }
});

test("repeated_restart_clicks_share_one_attempt", async () => {
  let release!: () => void;
  const calls = await ready({ save: new Promise<void>(r => { release = r; }) });
  typeDraft("keep");
  await act(async () => {
    const button = screen.getByRole("button", { name: "Restart" });
    fireEvent.click(button);
    fireEvent.click(button);
  });
  expect(calls).not.toContain("restart_to_update");
  await act(async () => release());
  expect(calls.filter(cmd => cmd === "restart_to_update")).toHaveLength(1);
});

test.each(["save", "install"])("restart_can_be_retried_after_%s_failure", async (failure) => {
  let rejectSave!: (reason: string) => void;
  let attempts = 0;
  const calls = await ready({
    save: () => ++attempts === 1 && failure === "save" ? new Promise<void>((_, reject) => { rejectSave = reject; }) : Promise.resolve(),
    restartError: failure === "install" ? "install failed" : undefined,
  });
  typeDraft("keep for retry");
  await restart();
  if (failure === "save") await act(async () => rejectSave("disk full"));
  expect(screen.getByRole("alertdialog", { name: failure === "save" ? "Couldn't save your drafts" : "Couldn't update" })).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "OK" }));
  await restart();
  expect(calls.filter(cmd => cmd === "restart_to_update")).toHaveLength(failure === "save" ? 1 : 2);
});

test("restart_reports_a_new_save_that_fails_before_the_next_drain", async () => {
  let release!: () => void;
  const a = new Promise<void>(r => { release = r; });
  const calls = await ready({ save: text => text === "A" ? a : Promise.reject("disk full") });
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  try {
    typeDraft("A");
    await act(async () => { fireEvent.blur(window); });
    typeDraft("B");
    await act(() => vi.advanceTimersByTimeAsync(300));
    await restart();
    await act(async () => release());
    expect(calls).not.toContain("restart_to_update");
    expect(screen.getByRole("alertdialog", { name: "Couldn't save your drafts" })).toHaveTextContent("disk full");
  } finally { vi.useRealTimers(); }
});


test("restart_freezes_new_work_through_drain_and_install", async () => {
  let save!: () => void;
  let install!: () => void;
  const calls = await ready({ save: new Promise<void>(r => { save = r; }), install: new Promise<void>(r => { install = r; }) });
  typeDraft("keep");
  await restart();
  typeDraft("late");
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveValue("keep");
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveAttribute("readonly");
  expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
  expect(screen.getByRole("button", { name: "Attach files" })).toBeDisabled();
  fireEvent.keyDown(screen.getByRole("textbox", { name: "New Item" }), { key: "Enter" });
  fireEvent.paste(screen.getByRole("textbox", { name: "New Item" }), { clipboardData: { files: [new File(["x"], "late.txt")], getData: () => "" } });
  await act(() => emit("attachments-staging", "late-drop"));
  await act(() => emit("attachments-staged", { drop_id: "late-drop", staged: [{ id: "late", filename: "late.txt", size_bytes: 1, mime_type: "text/plain" }], errors: [] }));
  expect(screen.queryByText("late.txt")).not.toBeInTheDocument();
  expect(calls).not.toContain("capture");
  expect(calls).not.toContain("stage_attachment_bytes");
  expect(calls).not.toContain("restart_to_update");
  await act(async () => save());
  expect(calls).toContain("restart_to_update");
  expect(JSON.parse(localStorage.getItem("saved-draft")!)).toMatchObject({ text: "keep" });
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveAttribute("readonly");
  await act(async () => install());
});

test.each(["save", "install"])("restart_unfreezes_after_%s_error", async (failure) => {
  let reject!: (err: string) => void;
  await ready({ save: failure === "save" ? new Promise<void>((_, r) => { reject = r; }) : undefined, restartError: failure === "install" ? "install failed" : undefined });
  typeDraft("keep");
  await restart();
  if (failure === "save") await act(async () => reject("disk full"));
  fireEvent.click(screen.getByRole("button", { name: "OK" }));
  expect(screen.getByRole("textbox", { name: "New Item" })).not.toHaveAttribute("readonly");
  typeDraft("editable");
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveValue("editable");
  expect(screen.getByRole("button", { name: "Attach files" })).toBeEnabled();
});

test.each([true, false])("restart_waits_for_staging_then_confirms_the_final_count (saveFirst=%s)", async (saveFirst) => {
  let save!: () => void;
  const calls = await ready({ save: new Promise<void>(r => { save = r; }) });
  typeDraft("keep");
  await act(() => emit("attachments-staging", "pending-drop"));
  await restart();
  expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  if (saveFirst) await act(async () => save());
  expect(calls).not.toContain("restart_to_update");
  await act(() => emit("attachments-staged", { drop_id: "pending-drop", staged: [{ id: "one", filename: "one.png", size_bytes: 10, mime_type: "image/png" }], errors: [] }));
  if (!saveFirst) {
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(calls).not.toContain("restart_to_update");
    await act(async () => save());
  }
  const dialog = screen.getByRole("alertdialog", { name: "Restart and remove 1 unsent file?" });
  fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  expect(calls).not.toContain("restart_to_update");
  expect(screen.getByRole("textbox", { name: "New Item" })).not.toHaveAttribute("readonly");
  typeDraft("editable");
  expect(screen.getByRole("textbox", { name: "New Item" })).toHaveValue("editable");
});


test("restart_confirms_the_larger_count_after_an_initial_confirmation", async () => {
  const calls = await ready();
  const file = { id: "one", filename: "one.txt", size_bytes: 1, mime_type: "text/plain" };
  await act(() => emit("attachments-staged", { staged: [file], errors: [] }));
  await act(() => emit("attachments-staging", "pending"));
  await restart();
  await act(async () => { fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Restart" })); });
  expect(calls).not.toContain("restart_to_update");
  await act(() => emit("attachments-staged", { drop_id: "pending", staged: [{ ...file, id: "two", filename: "two.txt" }], errors: [] }));
  const dialog = screen.getByRole("alertdialog", { name: "Restart and remove 2 unsent files?" });
  await act(async () => { fireEvent.click(within(dialog).getByRole("button", { name: "Restart" })); });
  expect(calls.filter(c => c === "restart_to_update")).toHaveLength(1);
});
