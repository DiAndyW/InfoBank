export function failure(headline: string, err: unknown): string {
  if (typeof err === "string") return err && err !== "Something went wrong. Try again." ? `${headline} ${err}` : headline;
  console.error("Failure type:", err instanceof Error ? err.constructor.name : typeof err);
  return headline;
}
