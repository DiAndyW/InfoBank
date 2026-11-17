import { useState } from "react";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, expect, test, vi } from "vitest";
import { mockWindows, mockIPC, mockConvertFileSrc } from "@tauri-apps/api/mocks";
import { emit } from "@tauri-apps/api/event";
import { behaviourTest } from "./behaviour-test";
import { Chips, useStaging } from "./staging";
import { pickFiles, stageBytes, unstage, type Staged } from "./api";
vi.mock("./api", () => ({ MAX_ATTACHMENT_BYTES: 100000000, pickFiles: vi.fn(), stageBytes: vi.fn(), unstage: vi.fn(async () => {}), thumbnail: vi.fn(), openAttachment: vi.fn(), openStagedAttachment: vi.fn() }));
vi.mock("@tauri-apps/api/path", () => ({ appDataDir: async () => "/fixture", join: async (...p: string[]) => p.join("/") }));
afterEach(cleanup);
const file = (id: string): Staged => ({ id, filename: id + ".txt", mime_type: "text/plain", size_bytes: 1 });
function gate<T>() { let resolve!: (v: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
function Host() {
  const [staged, setStaged] = useState([file("existing")]);
  const s = useStaging({ acceptsDrops: true, state: { staged, setStaged } });
  return <><textarea aria-label="paste" onPaste={s.onPaste} /><button onClick={s.pick}>pick</button><button onClick={s.retire}>retire</button><Chips list={staged} label="Attachments" onRemove={s.remove} pendingImportCount={s.pendingImportCount} /></>;
}
test.each(["paste", "drop"])("a rejected middle picker keeps later %s behind the first import", async next => {
  mockWindows("main");
  mockConvertFileSrc("macos");
  mockIPC(() => {}, { shouldMockEvents: true });
  const first = gate<Staged>();
  vi.mocked(stageBytes).mockImplementation(name => name === "first.txt" ? first.promise : Promise.resolve(file("last")));
  vi.mocked(pickFiles).mockRejectedValue("Picker unavailable");
  render(<Host />);
  const pasted = (name: string) => ({ name: name + ".txt", size: 1, arrayBuffer: async () => new ArrayBuffer(1) });
  fireEvent.paste(screen.getByLabelText("paste"), { clipboardData: { files: [pasted("first")], getData: () => "" } });
  fireEvent.click(screen.getByText("pick"));
  await act(async () => {});
  if (next === "paste") {
    fireEvent.paste(screen.getByLabelText("paste"), { clipboardData: { files: [pasted("last")], getData: () => "" } });
  } else {
    await act(() => emit("attachments-staging", "last-drop"));
    await act(() => emit("attachments-staged", { drop_id: "last-drop", staged: [file("last")], errors: [] }));
  }
  await act(async () => {});
  expect([...screen.getByLabelText("Attachments").querySelectorAll(".nb-file-name")].map(node => node.textContent)).toEqual(["existing.txt"]);
  await act(async () => first.resolve(file("first")));
  expect([...screen.getByLabelText("Attachments").querySelectorAll(".nb-file-name")].map(node => node.textContent)).toEqual(["existing.txt", "first.txt", "last.txt"]);
  expect(screen.queryByLabelText("1 import pending")).toBeNull();
});

behaviourTest("composer.attachment_order", async expected => {
  mockWindows("main");
  mockConvertFileSrc("macos");
  mockIPC(() => {}, { shouldMockEvents: true });
  const picker = gate<{ staged: Staged[]; errors: string[] }>();
  vi.mocked(pickFiles).mockReturnValue(picker.promise);
  const first = gate<Staged>(), second = gate<Staged>();
  vi.mocked(stageBytes).mockImplementation(name => name === "first.txt" ? first.promise : second.promise);
  render(<Host />);
  fireEvent.click(screen.getByText("pick"));
  const files = ["first", "second"].map(n => ({ name: n + ".txt", size: 1, arrayBuffer: async () => new ArrayBuffer(1) }));
  fireEvent.paste(screen.getByLabelText("paste"), { clipboardData: { files, getData: () => "" } });
  await act(() => emit("attachments-staging", "drop"));
  await act(() => emit("attachments-staged", { drop_id: "drop", staged: [file("drop")], errors: [] }));
  await act(async () => { second.resolve(file("second")); first.resolve(file("first")); });
  await act(async () => picker.resolve({ staged: [file("picked" )], errors: ["One file failed to attach."] }));
  expect(expected.order).toBe("input");
  expect([...screen.getByLabelText("Attachments").querySelectorAll(".nb-file-name")].map(n => n.textContent)).toEqual(["existing.txt", "picked.txt", "first.txt", "second.txt", "drop.txt"]);
  expect(screen.queryByLabelText("1 import pending")).toBeNull();
});

behaviourTest("composer.pending_imports", async expected => {
  mockWindows("main"); mockConvertFileSrc("macos"); mockIPC(() => {}, { shouldMockEvents: true });
  const first = gate<{ staged: Staged[]; errors: string[] }>();
  vi.mocked(pickFiles).mockReturnValueOnce(first.promise).mockResolvedValueOnce({ staged: [file("second")], errors: [] });
  render(<Host />);
  fireEvent.click(screen.getByText("pick"));
  expect(screen.getByLabelText(expected.label!)).toHaveTextContent(expected.label!);
  fireEvent.click(screen.getByText("pick")); await act(async () => {});
  expect(screen.getByLabelText(expected.message!.replace("{count}", "2"))).toHaveTextContent("2 imports pending");
  expect(screen.queryByText("second.txt")).toBeNull();
  await act(async () => first.resolve({ staged: [file("first")], errors: [] }));
  expect([...screen.getByLabelText("Attachments").querySelectorAll(".nb-file-name")].map(n => n.textContent)).toEqual(["existing.txt", "first.txt", "second.txt"]);
  expect(screen.queryByText("2 imports pending")).toBeNull();
});

test("retiring a partial paste deletes bytes ready before Clear and bytes ready afterward", async () => {
  mockWindows("main"); mockConvertFileSrc("macos"); mockIPC(() => {}, { shouldMockEvents: true });
  vi.mocked(unstage).mockClear();
  const late = gate<Staged>();
  vi.mocked(stageBytes).mockImplementation(name => name === "early.txt" ? Promise.resolve(file("early")) : late.promise);
  render(<Host />);
  fireEvent.paste(screen.getByLabelText("paste"), { clipboardData: { files: ["early", "late"].map(name => ({ name: name + ".txt", size: 1, arrayBuffer: async () => new ArrayBuffer(1) })), getData: () => "" } });
  await act(async () => {});
  fireEvent.click(screen.getByText("retire"));
  await act(async () => late.resolve(file("late")));
  expect(vi.mocked(unstage).mock.calls.map(args => args[0]).sort()).toEqual(["early", "late"]);
  expect(screen.queryByText("early.txt")).toBeNull();
});
