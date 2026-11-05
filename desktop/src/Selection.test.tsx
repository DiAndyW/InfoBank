import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { SelectionBar, useItemSelection } from "./Selection";
import * as api from "./api";

vi.mock("./api", () => ({ prepareCopyItems: vi.fn(), finishCopyItems: vi.fn(), discardCopyItems: vi.fn(async () => {}), setItemsTrashed: vi.fn() }));

function Harness({ ids = ["a", "b", "c"], place = "tunnel", enabled = true, onNotice = vi.fn(), onError = vi.fn() }: {
  ids?: string[]; place?: string; enabled?: boolean; onNotice?: (...args: any[]) => void; onError?: (...args: any[]) => void;
}) {
  const selection = useItemSelection({ items: ids.map(id => ({ id, sync_error: null })), scope: place, enabled, onNotice, onError });
  return <>
    <button onClick={selection.enter}>Select</button>
    <button onClick={selection.clear}>Done</button>
    {ids.map(id => <button key={id} aria-pressed={selection.ids.has(id)} onClick={e => selection.pick(id, e)}>{id}</button>)}
    {selection.selecting && <SelectionBar selection={selection} tunnel={place === "tunnel"} trash={place === "trash"} />}
  </>;
}

test("modifier entry, plain-click toggle, range selection, and final deselection exit", () => {
  render(<Harness />);
  fireEvent.click(screen.getByText("a"));
  expect(screen.queryByText("1 Item selected")).not.toBeInTheDocument();
  fireEvent.click(screen.getByText("a"), { metaKey: true });
  expect(screen.getByText("1 Item selected")).toBeInTheDocument();
  fireEvent.click(screen.getByText("c"), { shiftKey: true });
  expect(screen.getByText("3 Items selected")).toBeInTheDocument();
  for (const id of ["a", "b", "c"]) fireEvent.click(screen.getByText(id));
  expect(screen.queryByRole("button", { name: "Copy & Trash" })).not.toBeInTheDocument();
});

test("refresh preserves valid IDs without selecting arrivals, and navigation clears selection", () => {
  const view = render(<Harness />);
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByText("b"));
  view.rerender(<Harness ids={["b", "c", "d"]} />);
  expect(screen.getByText("1 Item selected")).toBeInTheDocument();
  expect(screen.getByText("d")).toHaveAttribute("aria-pressed", "false");
  view.rerender(<Harness ids={["c", "d"]} />);
  expect(screen.queryByText("1 Item selected")).not.toBeInTheDocument();
  fireEvent.click(screen.getByText("c"), { ctrlKey: true });
  view.rerender(<Harness ids={["c", "d"]} place="inbox" />);
  expect(screen.queryByText("1 Item selected")).not.toBeInTheDocument();
});

test("Tunnel copies a complete ordered batch before Trash and exposes one whole-batch Undo", async () => {
  vi.mocked(api.prepareCopyItems).mockResolvedValue("prepared");
  vi.mocked(api.finishCopyItems).mockResolvedValue();
  vi.mocked(api.setItemsTrashed).mockResolvedValue();
  const onNotice = vi.fn();
  render(<Harness onNotice={onNotice} />);
  fireEvent.click(screen.getByText("c"), { metaKey: true });
  fireEvent.click(screen.getByText("a"));
  fireEvent.click(screen.getByRole("button", { name: "Copy & Trash" }));
  await waitFor(() => expect(onNotice).toHaveBeenCalled());
  expect(api.prepareCopyItems).toHaveBeenLastCalledWith(["a", "c"]);
  expect(api.finishCopyItems).toHaveBeenLastCalledWith("prepared");
  expect(api.setItemsTrashed).toHaveBeenLastCalledWith(["a", "c"], true);
  const [message, action] = onNotice.mock.lastCall!;
  expect(message).toBe("2 Items copied · moved to Trash");
  await action.onAction();
  expect(api.setItemsTrashed).toHaveBeenLastCalledWith(["a", "c"], false);
});

test("repeated Undo while restoration is pending submits only one batch", async () => {
  let finish!: () => void;
  const notice = vi.fn();
  vi.mocked(api.setItemsTrashed).mockResolvedValueOnce();
  render(<Harness onNotice={notice} />);
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByRole("button", { name: "Trash" }));
  await waitFor(() => expect(notice).toHaveBeenCalled());
  vi.mocked(api.setItemsTrashed).mockClear().mockImplementationOnce(() => new Promise(r => { finish = r; }));
  const undo = notice.mock.lastCall![1].onAction;
  const first = undo();
  await undo();
  expect(api.setItemsTrashed).toHaveBeenCalledTimes(1);
  await act(async () => finish());
  await first;
});

test("navigation during preparation discards the payload without writing or trashing", async () => {
  vi.mocked(api.finishCopyItems).mockClear();
  vi.mocked(api.setItemsTrashed).mockClear();
  let resolve!: (token: string) => void;
  vi.mocked(api.prepareCopyItems).mockImplementation(() => new Promise(r => { resolve = r; }));
  const view = render(<Harness />);
  fireEvent.click(screen.getByText("a"), { metaKey: true });
  fireEvent.click(screen.getByRole("button", { name: "Copy & Trash" }));
  view.rerender(<Harness enabled={false} />);
  await act(async () => resolve("late"));
  expect(api.discardCopyItems).toHaveBeenCalledWith("late");
  expect(api.finishCopyItems).not.toHaveBeenCalled();
  expect(api.setItemsTrashed).not.toHaveBeenCalled();
});

test("a removed selected Item cancels a pending copy and leaves the remaining selection usable", async () => {
  let resolve!: (token: string) => void;
  vi.mocked(api.prepareCopyItems).mockImplementationOnce(() => new Promise(r => { resolve = r; }));
  vi.mocked(api.finishCopyItems).mockClear();
  const view = render(<Harness />);
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByText("b"));
  fireEvent.click(screen.getByRole("button", { name: "Copy & Trash" }));
  view.rerender(<Harness ids={["b", "c"]} />);
  expect(screen.getByText("1 Item selected")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Copy & Trash" })).toBeEnabled();
  await act(async () => resolve("outdated"));
  expect(api.finishCopyItems).not.toHaveBeenCalled();
  expect(api.discardCopyItems).toHaveBeenCalledWith("outdated");
});

test("a clipboard failure keeps the selection and never trashes; Restore acts on the entire batch", async () => {
  const error = vi.fn(), notice = vi.fn();
  vi.mocked(api.prepareCopyItems).mockResolvedValueOnce("bad");
  vi.mocked(api.finishCopyItems).mockRejectedValueOnce("clipboard busy");
  vi.mocked(api.setItemsTrashed).mockClear();
  const view = render(<Harness onError={error} />);
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByRole("button", { name: "Copy & Trash" }));
  await waitFor(() => expect(error).toHaveBeenCalled());
  expect(screen.getByText("1 Item selected")).toBeInTheDocument();
  expect(api.setItemsTrashed).not.toHaveBeenCalled();
  view.rerender(<Harness place="trash" onNotice={notice} />);
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByText("b"));
  fireEvent.click(screen.getByRole("button", { name: "Restore" }));
  await waitFor(() => expect(notice).toHaveBeenCalledWith("2 Items restored", undefined));
  expect(api.setItemsTrashed).toHaveBeenLastCalledWith(["a", "b"], false);
});

test("failed batch Undo remains retryable, and Search Copy never trashes Tunnel results", async () => {
  const error = vi.fn(), notice = vi.fn();
  vi.mocked(api.prepareCopyItems).mockResolvedValue("ready");
  vi.mocked(api.finishCopyItems).mockResolvedValue();
  vi.mocked(api.setItemsTrashed).mockResolvedValue();
  render(<Harness place="search" onNotice={notice} onError={error} />);
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByRole("button", { name: "Trash" }));
  await waitFor(() => expect(notice).toHaveBeenCalled());
  vi.mocked(api.setItemsTrashed).mockRejectedValueOnce("offline local store");
  expect(await notice.mock.lastCall![1].onAction()).toBe(false);
  expect(error).toHaveBeenCalled();
  vi.mocked(api.setItemsTrashed).mockClear();
  fireEvent.click(screen.getByText("a"), { ctrlKey: true });
  fireEvent.click(screen.getByRole("button", { name: "Copy" }));
  await waitFor(() => expect(notice.mock.lastCall![0]).toBe("1 Item copied"));
  expect(api.setItemsTrashed).not.toHaveBeenCalled();
});
