export function failure(headline: string, err: unknown): string {
  if (typeof err === "string") return err && err !== "Something went wrong. Try again." ? `${headline} ${err}` : headline;
  console.error("Failure type:", err instanceof Error ? err.constructor.name : typeof err);
  return headline;
}

export function attachmentFailure(err: unknown, headline = "Attachment failed to open."): string {
  const authored = ["Can't download while offline", "The Server sent more than expected", "Not on the Server yet", "The Server rejected the secret", "Not uploaded yet", "Unknown attachment", "Couldn't save the download", "The download was incomplete", "Couldn't reach the Server.", "NoteBank couldn't access that file.", "NoteBank couldn't read or save its data. Try again."];
  return typeof err === "string" && authored.includes(err) ? `${headline} ${err}` : headline;
}
