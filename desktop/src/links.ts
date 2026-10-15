export type Part = string | { url: string };

const URL_PATTERN = /https?:\/\/[^\s<>"]+/g;
// Punctuation right after a link almost always ends the sentence, not the URL.
const TRAILING_PUNCTUATION = /[.,;:!?)\]}'"]+$/;

export function linkify(text: string): Part[] {
  const parts: Part[] = [];
  let end = 0;
  for (const match of text.matchAll(URL_PATTERN)) {
    const url = match[0].replace(TRAILING_PUNCTUATION, "");
    if (match.index > end) parts.push(text.slice(end, match.index));
    parts.push({ url });
    end = match.index + url.length;
  }
  if (end < text.length) parts.push(text.slice(end));
  return parts;
}
