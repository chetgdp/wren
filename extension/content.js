// Persistent keybinds on every page: p with a selection speaks it, p
// without toggles pause on the active overlay, o stops. The overlay
// (injected by the background worker after a speak) shares this isolated
// world and exposes its controls on window.__voiceMlOverlay.

// --- read mode: extract the page's readable blocks in document order ---

const BLOCK_SELECTOR =
  "h1, h2, h3, h4, h5, h6, p, li, blockquote, figcaption, dt, dd, pre";
const SKIP_ANCESTORS = "nav, aside, footer, header, form, [role=navigation]";


function extractReadable() {
  const root = document.body;
  const collected = [];
  const blocks = [];
  for (const el of root.querySelectorAll(BLOCK_SELECTOR)) {
    if (el.tagName === "PRE") continue; // code: server drops fences, we drop pre
    if (el.closest(SKIP_ANCESTORS)) continue;
    if (collected.some((a) => a.contains(el))) continue; // e.g. p inside li
    const text = el.innerText.replace(/\s+/g, " ").trim();
    if (text.length < 2) continue;
    collected.push(el);
    // Headings and bullets often lack terminal punctuation; without it the
    // server's chunker merges them into the next sentence with no pause.
    blocks.push(/[.!?:;,]$/.test(text) ? text : text + ".");
  }
  return { blocks, elements: collected };
}

// --- highlight of the block range currently being spoken ---
// Two layers: a light tint on the containing element(s), and a stronger
// mark on the exact sentence(s) via the CSS Custom Highlight API (no DOM
// mutation; adoptedStyleSheets dodges page CSP like the inline styles do).

let readElements = []; // element per block index of the last read-page
let readSentences = []; // sentence text per block index
let rangeCache = new Map(); // block index -> Range | null
let currentBlock = 0; // start of the last painted range (paragraph jumps)
let lit = [];

const sentenceHl = typeof Highlight === "undefined" ? null : new Highlight();
let hlStyleReady = false;

function ensureSentenceStyle() {
  if (hlStyleReady || !sentenceHl) return;
  CSS.highlights.set("voice-ml-sentence", sentenceHl);
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(
    "::highlight(voice-ml-sentence){background-color:rgba(255,180,40,.55)}"
  );
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  hlStyleReady = true;
}

// Locate the sentence's text inside its element as a Range. The sentence
// string was whitespace-normalized and may have a period we appended, so
// match whitespace loosely and make the final period optional.
function sentenceRange(i) {
  if (rangeCache.has(i)) return rangeCache.get(i);
  let result = null;
  const el = readElements[i];
  const sentence = readSentences[i];
  if (el && sentence) {
    const nodes = [];
    let raw = "";
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      nodes.push({ node: walker.currentNode, start: raw.length });
      raw += walker.currentNode.data;
    }
    let pat = sentence
      .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
      .replace(/ /g, "[\\s\\u00a0]+");
    if (pat.endsWith("\\.")) pat = pat.slice(0, -2) + "\\.?";
    const m = raw.match(new RegExp(pat));
    if (m) {
      const start = m.index;
      const end = start + m[0].length;
      const range = new Range();
      for (const { node, start: ns } of nodes) {
        const ne = ns + node.data.length;
        if (ns <= start && start < ne) range.setStart(node, start - ns);
        if (ns < end && end <= ne) range.setEnd(node, end - ns);
      }
      if (!range.collapsed) result = range;
    }
  }
  rangeCache.set(i, result);
  return result;
}

function highlight(range) {
  let want = [];
  if (range) currentBlock = range[0];
  if (range && readElements.length) {
    const [lo, hi] = range;
    for (let i = lo; i <= hi && i < readElements.length; i++)
      if (i >= 0) want.push(readElements[i]);
    want = [...new Set(want)]; // sentences share elements; style once
  }
  if (sentenceHl) {
    ensureSentenceStyle();
    sentenceHl.clear();
    if (range) {
      const [lo, hi] = range;
      for (let i = Math.max(0, lo); i <= hi && i < readSentences.length; i++) {
        const r = sentenceRange(i);
        if (r) sentenceHl.add(r);
      }
    }
  }
  if (want.length === lit.length && want.every((el, i) => el === lit[i]))
    return;
  // Inline styles via CSSOM dodge strict style-src CSP that would block an
  // injected <style> tag.
  for (const el of lit) el.style.background = el.__vmBg ?? "";
  for (const el of want) {
    el.__vmBg = el.style.background;
    el.style.background = "rgba(255, 214, 90, 0.18)";
  }
  lit = want;
  lit[0]?.scrollIntoView({ block: "center", behavior: "smooth" });
}

// The overlay drives this from its /health poll.
window.__voiceMlReader = { highlight };

// Sentence-level blocks so /seek skips by sentence; several block indices
// map back to the same DOM element for highlighting. Same break rule as the
// server's chunker.
const SENTENCE_BREAK = /(?<=[.!?;:])\s+/;

function readPage() {
  const { blocks, elements } = extractReadable();
  if (blocks.length === 0) return;
  highlight(null);
  const sentences = [];
  readElements = [];
  rangeCache = new Map();
  blocks.forEach((block, i) => {
    for (const s of block.split(SENTENCE_BREAK)) {
      if (!s.trim()) continue;
      sentences.push(s);
      readElements.push(elements[i]);
    }
  });
  readSentences = sentences;
  chrome.runtime.sendMessage({ path: "/speak", body: { blocks: sentences } });
}

async function seek(body) {
  const r = await chrome.runtime.sendMessage({ path: "/seek", body });
  if (r && r.ok) {
    // Client playback: the server already dropped its buffer, but audio
    // scheduled in the offscreen player would keep playing until the first
    // post-seek segment arrives; cut it now.
    chrome.runtime
      .sendMessage({ cmd: "player", action: "flush" })
      .catch(() => {});
    highlight([r.block, r.block]);
    // A /health response captured before the seek can land after this
    // paint; hold off poll-driven highlights so it can't rubber-band back.
    window.__voiceMlSeekHold = performance.now() + 1200;
  }
}

// Paragraph jumps: first sentence of the next/previous element relative to
// the last painted position.
function paragraphSeek(dir) {
  if (!readElements.length) return;
  const cur = Math.min(Math.max(currentBlock, 0), readElements.length - 1);
  const el = readElements[cur];
  let target = null;
  if (dir > 0) {
    for (let i = cur + 1; i < readElements.length; i++)
      if (readElements[i] !== el) { target = i; break; }
    if (target === null) target = readElements.length - 1;
  } else {
    let first = cur;
    while (first > 0 && readElements[first - 1] === el) first--;
    if (first === 0) target = 0;
    else {
      const prevEl = readElements[first - 1];
      target = first - 1;
      while (target > 0 && readElements[target - 1] === prevEl) target--;
    }
  }
  seek({ block: target });
}

// Playhead state pushed by the offscreen player (client-playback daemons),
// forwarded here by the background worker. The overlay reads it instead of
// /health's block/paused, which only reflect server-side playback.
window.__voiceMlClientState = { playing: false, paused: false };

chrome.runtime.onMessage.addListener((msg) => {
  if (msg.cmd === "read-page") readPage();
  else if (msg.cmd === "position") {
    window.__voiceMlClientState = { playing: msg.playing, paused: msg.paused };
    if (msg.block && !(window.__voiceMlSeekHold > performance.now()))
      highlight(msg.block);
  }
});
document.addEventListener(
  "keydown",
  (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.composedPath()[0];
    if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
      return; // don't hijack typing
    if (e.key === "p") {
      const sel = window.getSelection().toString().trim();
      if (sel) chrome.runtime.sendMessage({ path: "/speak", body: { text: sel } });
      else if (window.__voiceMlOverlay) window.__voiceMlOverlay.togglePause();
      else readPage();
    } else if (e.key === "o") {
      if (!window.__voiceMlOverlay) return;
      window.__voiceMlOverlay.stop();
    } else if (e.key === "j" || e.key === "k") {
      if (!window.__voiceMlOverlay) return;
      seek({ delta: e.key === "j" ? -1 : 1 });
    } else if (e.key === "J" || e.key === "K") {
      if (!window.__voiceMlOverlay) return;
      paragraphSeek(e.key === "J" ? -1 : 1);
    } else return;
    e.preventDefault();
    e.stopPropagation();
  },
  true
);
