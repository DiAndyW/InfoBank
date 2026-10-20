import { expect, test } from "vitest";
import { diffWords } from "./ConflictDialog";

test("diffWords marks only the words that differ", () => {
  const [theirs, mine] = diffWords("the blue jacket", "the green jacket");
  expect(theirs.filter((p) => p.changed).map((p) => p.text)).toEqual(["blue"]);
  expect(mine.filter((p) => p.changed).map((p) => p.text)).toEqual(["green"]);
  expect(theirs.map((p) => p.text).join("")).toBe("the blue jacket");
  expect(mine.map((p) => p.text).join("")).toBe("the green jacket");
});

test("diffWords leaves texts too large to compare untinted", () => {
  const words = (prefix: string) => Array.from({ length: 3000 }, (_, i) => `${prefix}${i}`).join(" ");
  const [theirs, mine] = diffWords(words("a"), words("b"));
  for (const [parts, text] of [[theirs, words("a")], [mine, words("b")]] as const) {
    expect(parts).toHaveLength(1);
    expect(parts[0]).toEqual({ text, changed: false });
  }
});
