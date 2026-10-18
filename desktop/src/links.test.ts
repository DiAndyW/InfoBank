import { expect, test } from "vitest";
import { linkify } from "./links";

test("plain text has no links", () => {
  expect(linkify("call dentist")).toEqual(["call dentist"]);
});

test("trailing punctuation stays outside the link", () => {
  expect(linkify("read https://example.com/x. later")).toEqual([
    "read ",
    { url: "https://example.com/x" },
    ". later",
  ]);
  expect(linkify("(see http://a.io/b)")).toEqual(["(see ", { url: "http://a.io/b" }, ")"]);
});

test("several links", () => {
  expect(linkify("https://a.com and https://b.com")).toEqual([
    { url: "https://a.com" },
    " and ",
    { url: "https://b.com" },
  ]);
});

test("only http and https become links", () => {
  for (const text of ["javascript:alert(1)", "ftp://files.example.com", "file:///etc/passwd", "mailto:a@b.c"]) {
    expect(linkify(text)).toEqual([text]);
  }
});

test("a closing parenthesis stays when the link opened one", () => {
  expect(linkify("https://en.wikipedia.org/wiki/Heat_(1995_film)")).toEqual([{ url: "https://en.wikipedia.org/wiki/Heat_(1995_film)" }]);
  expect(linkify("(see https://en.wikipedia.org/wiki/Heat_(1995_film)).")).toEqual([
    "(see ",
    { url: "https://en.wikipedia.org/wiki/Heat_(1995_film)" },
    ").",
  ]);
});
