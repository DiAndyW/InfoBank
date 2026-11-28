import { fireEvent, render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { behaviourTest } from "./behaviour-test";
import { Attachments } from "./attachments";
import { openAttachment } from "./api";
import { attachmentFailure } from "./failure";
import ImageViewer from "./ImageViewer";
vi.mock("./api", () => ({ thumbnail: vi.fn(async () => { throw new Error("private thumbnail"); }), attachmentStored: vi.fn(async () => true), attachmentOriginal: vi.fn(async () => { throw new Error("https://private/?secret=credential"); }), openAttachment: vi.fn() }));
behaviourTest("failure.attachment_preview", async expected => {
  render(<ImageViewer images={[{ id: "image", filename: "photo.png" }]} selected="image" onSelect={() => {}} onClose={() => {}} />);
  const message = await screen.findByText(expected.message!);
  const retry = screen.getByRole("button", { name: "Retry" });
  expect(message.closest(".nb-viewer-stage")).toContainElement(retry);
  expect(document.body.textContent).not.toContain("credential");
});

test("attachment failures hide raw strings and preserve authored download statuses", () => {
  expect(attachmentFailure("https://private/?secret=credential")).toBe("Attachment failed to open.");
  expect(attachmentFailure("Can't download while offline")).toBe("Attachment failed to open. Can't download while offline");
  expect(attachmentFailure("Not uploaded yet")).toBe("Attachment failed to open. Not uploaded yet");
});

test.each([new Error("private credential"), "private credential"])("file opening hides technical errors: %s", async error => {
  vi.mocked(openAttachment).mockRejectedValueOnce(error);
  render(<Attachments list={[{ id: "file", filename: "file.pdf", mime_type: "application/pdf", size_bytes: 10, uploaded: true, has_thumbnail: false, runnable: false }]} onView={() => {}} onNotice={() => 1} onDismissNotice={() => {}} closedCount={0} />);
  fireEvent.click(screen.getByRole("button", { name: "Open file.pdf" }));
  expect(await screen.findByText("Attachment failed to open.")).toBeVisible();
  expect(document.body.textContent).not.toContain("private credential");
});
