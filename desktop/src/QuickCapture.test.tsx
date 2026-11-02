import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { emit } from "@tauri-apps/api/event";
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { expect, test } from "vitest";
import Composer from "./Composer";
import QuickCapture from "./QuickCapture";
import type { Staged, Topic } from "./api";

const topic = (id: string, name: string, archived = false): Topic => ({ id, name, archived, item_count: 0 });
const staged: Staged = { id: "s1", filename: "receipt.png", size_bytes: 10, mime_type: "image/png" };

type Call = { cmd: string; args: any };

function quickBackend(opts: { topics?: () => Topic[]; captureError?: string; captureGate?: Promise<void>; staged?: Staged[]; stageGate?: Promise<void> } = {}) {
  const calls: Call[] = [];
  const created: Topic[] = [];
  mockWindows("quick-capture");
  mockIPC(
    async (cmd, args) => {
      calls.push({ cmd, args });
      const { name } = (args ?? {}) as { name: string };
      if (cmd === "list_topics") return [...(opts.topics?.() ?? []), ...created];
      if (cmd === "picker_topic") {
        const same = [...(opts.topics?.() ?? []), ...created].find((t) => t.name.toLowerCase() === name.trim().toLowerCase());
        if (same?.archived) throw "An archived Topic has that name";
        if (same) return same;
        created.push(topic("new", name.trim()));
        await emit("items-changed");
        return created[0];
      }
      if (cmd === "capture") {
        await opts.captureGate;
        if (opts.captureError) throw opts.captureError;
        return null;
      }
      if (cmd === "stage_attachment_bytes") {
        await opts.stageGate;
        return opts.staged?.shift();
      }
      if (cmd === "pick_files") return { staged: [], errors: [] };
      if (["unstage_attachment", "dismiss_quick_capture"].includes(cmd)) return null;
    },
    { shouldMockEvents: true },
  );
  return calls;
}

const box = () => screen.getByRole("textbox", { name: "New Item" });
const picker = () => screen.getByRole("button", { name: "Topic" });
const count = (calls: Call[], cmd: string) => calls.filter((c) => c.cmd === cmd).length;

async function pasteReceipt() {
  fireEvent.paste(box(), { clipboardData: { files: [new File(["x"], "receipt.png", { type: "image/png" })], getData: () => "" } });
  await screen.findByText("receipt.png");
}

async function choose(name: string) {
  await userEvent.click(picker());
  await userEvent.click(screen.getByRole("menuitemradio", { name }));
}

test("the composer hears only drops on its own window", async () => {
  const targets: unknown[] = [];
  mockWindows("quick-capture");
  mockIPC((cmd, args: any) => {
    if (cmd === "plugin:event|listen" && args.event === "attachments-staged") targets.push(args.target);
  });
  render(<Composer acceptsDrops target={{ kind: "inbox" }} placeholder="" onCaptured={() => {}} />);
  await waitFor(() => expect(targets).toEqual([{ kind: "WebviewWindow", label: "quick-capture" }]));
});

test("Enter captures into the Inbox and dismisses, leaving the text until the box is hidden", async () => {
  const calls = quickBackend();
  render(<QuickCapture />);
  await userEvent.type(box(), "milk{Enter}");
  await waitFor(() => expect(count(calls, "dismiss_quick_capture")).toBe(1));
  expect(calls.find((c) => c.cmd === "capture")!.args).toEqual({ text: "milk", attachmentIds: [], target: { kind: "inbox" } });
  expect(box()).toHaveValue("milk");
  await act(() => emit("quick-capture-hidden"));
  expect(box()).toHaveValue("");
});

test("a second Enter before the box hides doesn't capture twice", async () => {
  let release!: () => void;
  const calls = quickBackend({ captureGate: new Promise((r) => (release = r)) });
  render(<QuickCapture />);
  await userEvent.type(box(), "milk{Enter}{Enter}");
  await act(async () => release());
  await userEvent.type(box(), "{Enter}");
  expect(count(calls, "capture")).toBe(1);
  await act(() => emit("quick-capture-hidden"));
  await userEvent.type(box(), "eggs{Enter}");
  await waitFor(() => expect(count(calls, "capture")).toBe(2));
});

test("the Topic picker lists the Inbox and open Topics only, and a chosen Topic is used", async () => {
  const calls = quickBackend({ topics: () => [topic("t2", "Work"), topic("t1", "Gym"), topic("t3", "Old", true)] });
  render(<QuickCapture />);
  await waitFor(() => expect(count(calls, "list_topics")).toBe(1));
  expect(picker()).toHaveTextContent("Inbox");
  await userEvent.click(picker());
  expect(screen.getAllByRole("menuitemradio").map((i) => i.textContent)).toEqual(["Inbox", "Gym", "Work"]);
  await userEvent.click(screen.getByRole("menuitemradio", { name: "Gym" }));
  expect(picker()).toHaveTextContent("Gym");
  await userEvent.type(box(), "squat{Enter}");
  await waitFor(() => expect(calls.find((c) => c.cmd === "capture")?.args.target).toEqual({ kind: "topic", id: "t1" }));
});

test("opening the Topic picker doesn't send the draft", async () => {
  const calls = quickBackend({ topics: () => [topic("t1", "Gym")] });
  render(<QuickCapture />);
  await userEvent.type(box(), "draft");
  await choose("Gym");
  expect(count(calls, "capture")).toBe(0);
  expect(box()).toHaveValue("draft");
});

test("the Topic picker filters as you type and Enter picks the first match", async () => {
  quickBackend({ topics: () => [topic("t2", "Work"), topic("t1", "Gym"), topic("t3", "Woodwork")] });
  render(<QuickCapture />);
  await userEvent.click(picker());
  const filter = screen.getByRole("searchbox", { name: "Find or create a Topic" });
  expect(filter).toHaveFocus();
  await userEvent.type(filter, "wo");
  expect(screen.getAllByRole("menuitemradio").map((i) => i.textContent)).toEqual(["Woodwork", "Work"]);
  expect(screen.getByRole("menuitem", { name: "Create “wo”" })).toBeInTheDocument();
  await userEvent.type(filter, "{Enter}");
  expect(picker()).toHaveTextContent("Woodwork");
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
});

test("New Topic… sits below the scrolling list, so it shows however many Topics there are", async () => {
  quickBackend({ topics: () => Array.from({ length: 30 }, (_, i) => topic(`t${i}`, `Topic ${i}`)) });
  render(<QuickCapture />);
  await userEvent.click(picker());
  const list = screen.getByRole("menuitemradio", { name: "Topic 0" }).parentElement!;
  expect(list).toContainElement(screen.getByRole("menuitemradio", { name: "Topic 29" }));
  expect(list).not.toContainElement(screen.getByRole("menuitem", { name: "New Topic…" }));
});

test("New Topic… opens the New Topic dialog, which makes the Topic and returns to the draft; Escape closes only the dialog", async () => {
  const calls = quickBackend({ topics: () => [topic("t1", "Gym")] });
  render(<QuickCapture />);
  await userEvent.type(box(), "tile ideas");
  await userEvent.click(picker());
  await userEvent.click(screen.getByRole("menuitem", { name: "New Topic…" }));
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  let name = screen.getByRole("textbox", { name: "Topic name" });
  expect(name).toHaveFocus();
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(count(calls, "dismiss_quick_capture")).toBe(0);
  expect(box()).toHaveFocus();
  await userEvent.click(picker());
  await userEvent.click(screen.getByRole("menuitem", { name: "New Topic…" }));
  name = screen.getByRole("textbox", { name: "Topic name" });
  await userEvent.type(name, "Mosaic{Enter}");
  await waitFor(() => expect(picker()).toHaveTextContent("Mosaic"));
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(calls.filter((c) => c.cmd === "picker_topic").map((c) => c.args)).toEqual([{ name: "Mosaic" }]);
  expect(count(calls, "capture")).toBe(0);
  expect(box()).toHaveFocus();
  await userEvent.type(box(), "{Enter}");
  await waitFor(() => expect(calls.find((c) => c.cmd === "capture")?.args).toEqual({ text: "tile ideas", attachmentIds: [], target: { kind: "topic", id: "new" } }));
});

test("Escape steps back one level at a time; an archived name is refused in place", async () => {
  const calls = quickBackend({ topics: () => [topic("o", "Old", true)] });
  render(<QuickCapture />);
  await userEvent.click(picker());
  const filter = screen.getByRole("searchbox", { name: "Find or create a Topic" });
  await userEvent.type(filter, "old{Enter}");
  expect(await screen.findByRole("alert")).toHaveTextContent("An archived Topic has that name");
  expect(filter).toHaveValue("old");
  await userEvent.type(filter, "{Escape}");
  expect(filter).toHaveValue("");
  expect(screen.getByRole("menu", { name: "Topic" })).toBeInTheDocument();
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  expect(picker()).toHaveTextContent("Inbox");
  fireEvent.keyDown(box(), { key: "Escape", keyCode: 229 });
  fireEvent.keyDown(box(), { key: "Escape", isComposing: true });
  expect(count(calls, "capture") + count(calls, "dismiss_quick_capture")).toBe(0);
});

test("Escape dismisses without clearing; hiding then unstages, clears and goes back to the Inbox", async () => {
  const calls = quickBackend({ topics: () => [topic("t1", "Gym")], staged: [staged] });
  render(<QuickCapture />);
  await waitFor(() => expect(count(calls, "list_topics")).toBe(1));
  await choose("Gym");
  await userEvent.type(box(), "draft");
  await pasteReceipt();
  await userEvent.type(box(), "{Escape}");
  await waitFor(() => expect(count(calls, "dismiss_quick_capture")).toBe(1));
  expect(box()).toHaveValue("draft");
  expect(screen.getByText("receipt.png")).toBeInTheDocument();

  await act(() => emit("quick-capture-hidden"));
  expect(box()).toHaveValue("");
  expect(screen.queryByText("receipt.png")).not.toBeInTheDocument();
  expect(calls.filter((c) => c.cmd === "unstage_attachment").map((c) => c.args)).toEqual([{ id: "s1" }]);
  expect(picker()).toHaveTextContent("Inbox");
});

test("hiding while a capture is saving doesn't unstage its files", async () => {
  let release!: () => void;
  const calls = quickBackend({ staged: [staged], captureGate: new Promise((r) => (release = r)) });
  render(<QuickCapture />);
  await pasteReceipt();
  await userEvent.type(box(), "{Enter}");
  await waitFor(() => expect(count(calls, "capture")).toBe(1));
  await act(() => emit("quick-capture-hidden"));
  await act(async () => release());
  expect(count(calls, "unstage_attachment")).toBe(0);
  expect(screen.queryByText("receipt.png")).not.toBeInTheDocument();
});

test("a box hidden while saving still unstages a file pasted during the save", async () => {
  let release!: () => void;
  const calls = quickBackend({ staged: [staged], captureGate: new Promise((r) => (release = r)) });
  render(<QuickCapture />);
  await userEvent.type(box(), "milk{Enter}");
  await pasteReceipt();
  await act(() => emit("quick-capture-hidden"));
  await act(async () => release());
  await waitFor(() => expect(calls.filter((c) => c.cmd === "unstage_attachment").map((c) => c.args)).toEqual([{ id: "s1" }]));
  expect(screen.queryByText("receipt.png")).not.toBeInTheDocument();
});

test("a paste still staging when the box hides doesn't turn up next time", async () => {
  let release!: () => void;
  const calls = quickBackend({ staged: [staged], stageGate: new Promise((r) => (release = r)) });
  render(<QuickCapture />);
  fireEvent.paste(box(), { clipboardData: { files: [new File(["x"], "receipt.png", { type: "image/png" })], getData: () => "" } });
  await waitFor(() => expect(count(calls, "stage_attachment_bytes")).toBe(1));
  await act(() => emit("quick-capture-hidden"));
  await act(async () => release());
  await waitFor(() => expect(calls.filter((c) => c.cmd === "unstage_attachment").map((c) => c.args)).toEqual([{ id: "s1" }]));
  expect(screen.queryByText("receipt.png")).not.toBeInTheDocument();
});

test("after the file dialog closes, the text has focus again so Escape still dismisses", async () => {
  const calls = quickBackend();
  render(<QuickCapture />);
  box().blur();
  fireEvent.click(screen.getByRole("button", { name: "Attach files" }));
  await waitFor(() => expect(box()).toHaveFocus());
  await userEvent.keyboard("{Escape}");
  expect(count(calls, "dismiss_quick_capture")).toBe(1);
});

test("a failed capture keeps the draft and the error, and doesn't dismiss", async () => {
  const calls = quickBackend({ captureError: "disk full" });
  render(<QuickCapture />);
  await userEvent.type(box(), "milk{Enter}");
  expect(await screen.findByRole("alert")).toHaveTextContent("disk full");
  expect(box()).toHaveValue("milk");
  expect(count(calls, "dismiss_quick_capture")).toBe(0);
});

test("IME Enter and Escape don't act", async () => {
  const calls = quickBackend();
  render(<QuickCapture />);
  await userEvent.type(box(), "ni");
  fireEvent.keyDown(box(), { key: "Enter", keyCode: 229 });
  fireEvent.keyDown(box(), { key: "Escape", keyCode: 229 });
  fireEvent.keyDown(box(), { key: "Escape", isComposing: true });
  expect(count(calls, "capture") + count(calls, "dismiss_quick_capture")).toBe(0);
});

test("Escape with the Topic menu open only closes the menu", async () => {
  const calls = quickBackend({ topics: () => [topic("t1", "Gym")] });
  render(<QuickCapture />);
  await userEvent.click(picker());
  await userEvent.keyboard("{Escape}");
  expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  expect(count(calls, "dismiss_quick_capture")).toBe(0);
});

test("a chosen Topic that's archived or deleted falls back to the Inbox", async () => {
  let topics = [topic("t1", "Gym")];
  const calls = quickBackend({ topics: () => topics });
  render(<QuickCapture />);
  await waitFor(() => expect(count(calls, "list_topics")).toBe(1));
  await choose("Gym");
  topics = [topic("t1", "Gym", true)];
  await act(() => emit("items-changed"));
  await waitFor(() => expect(picker()).toHaveTextContent("Inbox"));
  await userEvent.type(box(), "x{Enter}");
  await waitFor(() => expect(calls.find((c) => c.cmd === "capture")?.args.target).toEqual({ kind: "inbox" }));
});

test("being shown focuses the text and reloads Topics", async () => {
  const calls = quickBackend();
  render(<QuickCapture />);
  await waitFor(() => expect(count(calls, "list_topics")).toBe(1));
  (document.activeElement as HTMLElement | null)?.blur();
  await act(() => emit("quick-capture-shown"));
  expect(box()).toHaveFocus();
  await waitFor(() => expect(count(calls, "list_topics")).toBe(2));
});

test("clicking the clear space around the box dismisses it", async () => {
  const calls = quickBackend();
  const { container } = render(<QuickCapture />);
  fireEvent.mouseDown(container.querySelector(".nb-quick")!);
  await waitFor(() => expect(count(calls, "dismiss_quick_capture")).toBe(1));
});

test("the quick box has autocorrect, spellcheck and writing suggestions off", () => {
  quickBackend();
  render(<QuickCapture />);
  expect(box()).toHaveAttribute("autocorrect", "off");
  expect(box()).toHaveAttribute("spellcheck", "false");
  expect(box()).toHaveAttribute("writingsuggestions", "false");
});


test("quick capture remembers the Tunnel switch, hides the picker, and sends to Tunnel", async () => {
  const calls = quickBackend({ topics: () => [topic("g", "Gym")] });
  const { unmount } = render(<QuickCapture />);
  await screen.findByRole("button", { name: "Topic" });
  await choose("Gym");
  await userEvent.click(screen.getByRole("switch", { name: "Tunnel" }));
  expect(screen.queryByRole("button", { name: "Topic" })).not.toBeInTheDocument();
  expect(box()).toHaveAttribute("placeholder", "Send to your other devices…");
  expect(box().closest(".nb-composer")).toHaveClass("is-tunnel");
  await userEvent.type(box(), "transfer{Enter}");
  await waitFor(() => expect(calls).toContainEqual({ cmd: "capture", args: { text: "transfer", attachmentIds: [], target: { kind: "tunnel" } } }));
  await act(() => emit("quick-capture-hidden"));
  await act(() => emit("quick-capture-shown"));
  expect(screen.getByRole("switch", { name: "Tunnel" })).toBeChecked();
  unmount();
  render(<QuickCapture />);
  expect(screen.getByRole("switch", { name: "Tunnel" })).toBeChecked();
  await userEvent.click(screen.getByRole("switch", { name: "Tunnel" }));
  expect(picker()).toHaveTextContent("Inbox");
  await userEvent.type(box(), "normal{Enter}");
  await waitFor(() => expect(calls).toContainEqual({ cmd: "capture", args: { text: "normal", attachmentIds: [], target: { kind: "inbox" } } }));
});




test("quick capture picks up a Tunnel switch changed in Home before it is shown", async () => {
  quickBackend();
  render(<QuickCapture />);
  expect(screen.getByRole("switch", { name: "Tunnel" })).not.toBeChecked();
  localStorage.setItem("tunnelSwitch", "true");
  await act(() => emit("quick-capture-shown"));
  expect(screen.getByRole("switch", { name: "Tunnel" })).toBeChecked();
});

test("hiding quick capture also closes its destination menu", async () => {
  quickBackend();
  render(<QuickCapture />);
  await userEvent.click(picker());
  expect(screen.getByRole("menu", { name: "Topic" })).toBeInTheDocument();
  await act(() => emit("quick-capture-hidden"));
  await act(() => emit("quick-capture-shown"));
  expect(screen.queryByRole("menu", { name: "Topic" })).not.toBeInTheDocument();
});
