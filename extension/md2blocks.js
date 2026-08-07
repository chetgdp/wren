// Convert pdf-inspector markdown into the sentence blocks /speak expects.
// Mirrors content.js extraction: code blocks are dropped, every block gets
// terminal punctuation so the server's chunker pauses between them, and
// blocks are split into sentences so /seek moves by sentence.

// Same break rule as content.js and the server's chunker.
const SENTENCE_BREAK = /(?<=[.!?;:])\s+/;

const LIST_MARKER = /^\s*(?:[-*+]|\d{1,3}[.)]|[a-z][.)])\s+/;
const TABLE_SEPARATOR = /^\s*\|?[\s:|-]+\|?\s*$/;

function cleanInline(text) {
  return text
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "") // image placeholders: nothing to say
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__)(.+?)\1/g, "$2")
    .replace(/(\*|_)(.+?)\1/g, "$2")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/<!--[^>]*-->/g, "")
    .replace(/<\/?[a-z][^>]*>/gi, "") // pdf-inspector emits <u>/<sup> etc.
    .replace(/\s+/g, " ")
    .trim();
}

function pushBlock(blocks, text) {
  const clean = cleanInline(text);
  if (clean.length < 2) return;
  blocks.push(/[.!?:;,]$/.test(clean) ? clean : clean + ".");
}

export function mdToBlocks(markdown) {
  const blocks = [];
  let paragraph = [];
  let inFence = false;
  const flush = () => {
    if (paragraph.length) pushBlock(blocks, paragraph.join(" "));
    paragraph = [];
  };
  for (const rawLine of markdown.split("\n")) {
    const line = rawLine.trimEnd();
    if (/^\s*(```|~~~)/.test(line)) {
      flush();
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (!line.trim()) {
      flush();
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.*)/);
    if (heading) {
      flush();
      pushBlock(blocks, heading[2]);
      continue;
    }
    if (line.trim().startsWith("|")) {
      flush();
      if (TABLE_SEPARATOR.test(line)) continue;
      const cells = line
        .split("|")
        .map((c) => c.trim())
        .filter(Boolean);
      if (cells.length) pushBlock(blocks, cells.join(", "));
      continue;
    }
    if (LIST_MARKER.test(line)) {
      flush();
      pushBlock(blocks, line.replace(LIST_MARKER, ""));
      continue;
    }
    paragraph.push(line.replace(/^\s*>\s?/, "").trim());
  }
  flush();
  const sentences = [];
  for (const block of blocks)
    for (const s of block.split(SENTENCE_BREAK)) if (s.trim()) sentences.push(s);
  return sentences;
}
