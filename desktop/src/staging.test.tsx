import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, expect, vi } from "vitest";
import { behaviourTest } from "./behaviour-test";
import { mockConvertFileSrc } from "@tauri-apps/api/mocks";
import { thumbnail, attachmentOriginal, attachmentStored, openAttachment, openStagedAttachment } from "./api";
import { Chips } from "./staging";
vi.mock("@tauri-apps/api/path", () => ({ appDataDir: async () => "/app", join: async (...parts: string[]) => parts.join("/") }));
vi.mock("./api", () => ({ openAttachment: vi.fn(async () => {}), openStagedAttachment: vi.fn(async () => {}), thumbnail: vi.fn(async () => "/thumb"), attachmentStored: vi.fn(async () => true), attachmentOriginal: vi.fn(async () => "/original") }));
beforeEach(() => { mockConvertFileSrc("macos"); vi.clearAllMocks(); });
afterEach(cleanup);
behaviourTest("editor.attachment_preview", async expected => {
  const remove = vi.fn();
  render(<Chips label="Other box" list={[{ id: "outside", filename: "outside.png", mime_type: "image/png", size_bytes: 1 }]} onRemove={() => {}} />);
  render(<Chips label="Attachments" list={[
    { id: "one", filename: "one.png", mime_type: "image/png", size_bytes: 10 },
    { id: "two", filename: "two.jpg", mime_type: "image/jpeg", size_bytes: 20 },
    { id: "clip", filename: "clip.mp4", mime_type: "video/mp4", size_bytes: 30 },
    { id: "doc", filename: "doc.txt", mime_type: "text/plain", size_bytes: 40 },
  ]} onRemove={remove} />);
  expect(expected.actions).toEqual(["image", "video", "file"]);
  fireEvent.click(screen.getByRole("button", { name: "one.png" }));
  const viewer = await screen.findByRole("dialog", { name: "one.png" });
  await waitFor(() => expect(viewer.querySelector("img")?.getAttribute("src")).toContain("files%2Fone%2Fone.png"));
  expect(within(viewer).queryByRole("button", { name: "Open original" })).toBeNull();
  expect(viewer.querySelector(".nb-viewer-title")).toHaveTextContent("one.png");
  expect(viewer.querySelector(".nb-viewer-actions-end")).toBeEmptyDOMElement();
  expect(attachmentOriginal).not.toHaveBeenCalled();
  expect(attachmentStored).not.toHaveBeenCalled();
  expect(within(viewer).getByText("1 of 2")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Next image" }));
  expect(screen.getByRole("dialog", { name: "two.jpg" })).toBeTruthy();
  await waitFor(() => expect(viewer.querySelector("img")?.getAttribute("src")).toContain("files%2Ftwo%2Ftwo.jpg"));
  expect(screen.getByRole("button", { name: "Next image" })).toBeDisabled();
  expect(within(viewer).getByText("2 of 2")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Close image" }));
  expect(screen.getByRole("button", { name: "Play clip.mp4" })).toBeTruthy();
  expect(screen.getByText("doc.txt")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Remove one.png" }));
  expect(remove).toHaveBeenCalledWith("one");
});

behaviourTest("editor.attachment_preview", async () => {
  render(<Chips label="Attachments" keptIds={["kept", "video"]} onRemove={() => {}} list={[
    { id: "kept", filename: "kept.png", mime_type: "image/png", size_bytes: 1, has_thumbnail: true },
    { id: "staged", filename: "staged.png", mime_type: "image/png", size_bytes: 1 },
    { id: "video", filename: "kept.mp4", mime_type: "video/mp4", size_bytes: 1, has_thumbnail: true },
    { id: "unsent", filename: "unsent.mp4", mime_type: "video/mp4", size_bytes: 1 },
  ]} />);
  const kept = screen.getByRole("button", { name: "kept.png" });
  const staged = screen.getByRole("button", { name: "staged.png" });
  await waitFor(() => {
    expect(kept.querySelector("img")?.getAttribute("src")).toContain("thumb");
    expect(staged.querySelector("img")?.getAttribute("src")).toContain("files%2Fstaged%2Fstaged.png");
  });
  expect(thumbnail).toHaveBeenCalledWith("video");
  expect(thumbnail).not.toHaveBeenCalledWith("unsent");
  fireEvent.error(staged.querySelector("img")!);
  expect(staged.querySelector("img")).toBeNull();
  expect(staged.querySelector("svg")).toBeTruthy();
});

behaviourTest("editor.attachment_preview", async expected => {
  render(<Chips label="Attachments" keptIds={["kept"]} onRemove={() => {}} list={[
    { id: "staged", filename: "local.mov", mime_type: "video/quicktime", size_bytes: 1 },
    { id: "kept", filename: "sent.mp4", mime_type: "video/mp4", size_bytes: 1, has_thumbnail: true },
  ]} />);
  fireEvent.click(screen.getByRole("button", { name: expected.label!.replace("{filename}", "local.mov") }));
  await waitFor(() => expect(openStagedAttachment).toHaveBeenCalledWith("staged"));
  fireEvent.click(screen.getByRole("button", { name: "Play sent.mp4" }));
  await waitFor(() => expect(openAttachment).toHaveBeenCalledWith("kept"));
  expect(screen.queryByRole("dialog")).toBeNull();
});

behaviourTest("editor.attachment_preview", async () => {
  vi.mocked(openStagedAttachment).mockRejectedValueOnce("An attachment is missing; add it again");
  render(<Chips label="Attachments" onRemove={() => {}} list={[
    { id: "missing", filename: "clip.mov", mime_type: "video/quicktime", size_bytes: 1 },
  ]} />);
  fireEvent.click(screen.getByRole("button", { name: "Play clip.mov" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("clip.mov failed to open. An attachment is missing; add it again");
  vi.mocked(openStagedAttachment).mockRejectedValueOnce(new Error("secret URL"));
  fireEvent.click(screen.getByRole("button", { name: "Play clip.mov" }));
  await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent(/^clip.mov failed to open\.$/));
});

behaviourTest("editor.attachment_preview", async () => {
  const file = { id: "loading", filename: "loading.png", mime_type: "image/png", size_bytes: 1 };
  const remove = vi.fn();
  const view = render(<Chips label="Loading attachments" list={[file]} onRemove={remove} />);
  const button = screen.getByRole("button", { name: "loading.png" });
  await waitFor(() => expect(button.querySelector("img")).toBeTruthy());
  expect(button.querySelector('[role="progressbar"]')).toBeTruthy();
  const img = button.querySelector("img")!;
  view.rerender(<Chips label="Loading attachments" list={[{ ...file }]} onRemove={remove} />);
  expect(button.querySelector("img")).toBe(img);
  fireEvent.load(img);
  expect(button.querySelector('[role="progressbar"]')).toBeNull();
  fireEvent.error(img);
  expect(button.querySelector('[role="progressbar"]')).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Remove loading.png" }));
  expect(remove).toHaveBeenCalledWith("loading");
  fireEvent.click(button);
  expect(await screen.findByRole("dialog", { name: "loading.png" })).toBeTruthy();
});

behaviourTest("editor.attachment_preview", async () => {
  render(<Chips label="Decode attachments" list={[{ id: "decode", filename: "decode.png", mime_type: "image/png", size_bytes: 1 }]} onRemove={() => {}} />);
  const button = screen.getByRole("button", { name: "decode.png" });
  await waitFor(() => expect(button.querySelector("img")).toBeTruthy());
  const image = button.querySelector("img")!;
  let fail!: () => void;
  image.decode = () => new Promise<void>((_, reject) => { fail = () => reject(new Error("decode")); });
  fireEvent.load(image);
  expect(button.querySelector('[role="progressbar"]')).toBeTruthy();
  await act(async () => fail());
  expect(button.querySelector('[role="progressbar"]')).toBeNull();
  expect(button.querySelector("img")).toBeNull();
  expect(screen.getByRole("button", { name: "Remove decode.png" })).toBeEnabled();
  fireEvent.click(button);
  expect(await screen.findByRole("dialog", { name: "decode.png" })).toBeTruthy();
});
