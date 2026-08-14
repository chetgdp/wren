import { getDocument, GlobalWorkerOptions, TextLayer }
  from "./vendor/pdfjs/pdf.min.mjs";

// Relative path resolves from the extension page origin for both the
// real Worker and the fake-worker fallback (dynamic import).
GlobalWorkerOptions.workerSrc =
  new URL("./vendor/pdfjs/pdf.worker.min.mjs", import.meta.url).href;
console.log("[pdf-viewer] workerSrc:", GlobalWorkerOptions.workerSrc);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SCALE = 1.5;
const SENTENCE_BREAK = /(?<=[.!?;:])\s+/;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let pdfDoc = null;
const pageInfo = [];       // per-page render state
const sentences = [];      // flat sentence strings sent to /speak
const sentencePages = [];  // page index (0-based) for each sentence
let isActive = false;
let paused = false;
let currentBlock = -1;
let seekHold = 0;

// CSS Custom Highlight for sentence-level painting
const sentenceHl =
  typeof Highlight !== "undefined" ? new Highlight() : null;
if (sentenceHl) CSS.highlights.set("voice-ml-sentence", sentenceHl);

// Range cache so repeated highlights of the same sentence are instant
const rangeCache = new Map();

// ---------------------------------------------------------------------------
// DOM refs
// ---------------------------------------------------------------------------

const statusEl = document.getElementById("status");
const container = document.getElementById("container");
const controls = document.getElementById("controls");
const ctlStatus = document.getElementById("ctlStatus");
const pauseBtn = document.getElementById("pauseBtn");
const rateVal = document.getElementById("rateVal");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function showError(msg) {
  statusEl.textContent = msg;
  statusEl.classList.add("error");
}

async function rpc(path, body) {
  return chrome.runtime.sendMessage({ path, body });
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

const url = new URLSearchParams(location.search).get("url");
console.log("[pdf-viewer] url:", url);
if (!url) showError("No URL provided.");
else init(url);

async function init(pdfUrl) {
  console.log("[pdf-viewer] loading PDF...");
  try {
    pdfDoc = await getDocument({
      url: pdfUrl,
      withCredentials: true,
    }).promise;
  } catch (e) {
    console.error("[pdf-viewer] load failed:", e);
    showError("Failed to load PDF: " + e.message);
    return;
  }
  console.log("[pdf-viewer] loaded, pages:", pdfDoc.numPages);

  statusEl.style.display = "none";
  pdfDoc.getMetadata().then(({ info }) => {
    if (info?.Title) document.title = info.Title;
  }).catch(() => {});

  // Create page containers with correct dimensions (scrollbar works
  // immediately), but defer heavy canvas rendering to IntersectionObserver.
  for (let i = 0; i < pdfDoc.numPages; i++) {
    const page = await pdfDoc.getPage(i + 1);
    const viewport = page.getViewport({ scale: SCALE });

    const div = document.createElement("div");
    div.className = "page";
    div.style.width = viewport.width + "px";
    div.style.height = viewport.height + "px";
    div.style.setProperty("--total-scale-factor", String(SCALE));
    div.style.setProperty("--scale-round-x", "1px");
    div.style.setProperty("--scale-round-y", "1px");
    container.appendChild(div);

    pageInfo.push({
      page,
      viewport,
      div,
      canvasRendered: false,
      textLayerEl: null,
      textContent: null,
    });
  }

  // Render text layers for all pages (cheap: just DOM spans) so
  // highlighting works before the user scrolls to a page.
  console.log("[pdf-viewer] building text layers...");
  await buildTextLayers();

  buildSentences();
  console.log("[pdf-viewer] sentences:", sentences.length,
    "sample:", sentences.slice(0, 3));

  if (!sentences.length) {
    showError("No readable text found in this PDF.");
    return;
  }

  // Lazy-render canvases for visible pages.
  setupLazyCanvas();

  // Speak.
  console.log("[pdf-viewer] sending /speak...");
  const res = await rpc("/speak", { blocks: sentences });
  console.log("[pdf-viewer] /speak response:", res);
  if (res?.queued > 0) {
    isActive = true;
    controls.style.display = "block";
  }
}

// ---------------------------------------------------------------------------
// Text layer extraction
// ---------------------------------------------------------------------------

async function buildTextLayers() {
  for (const info of pageInfo) {
    const content = await info.page.getTextContent();
    info.textContent = content;

    const tlDiv = document.createElement("div");
    tlDiv.className = "textLayer";
    info.div.appendChild(tlDiv);

    const tl = new TextLayer({
      textContentSource: content,
      container: tlDiv,
      viewport: info.viewport,
    });
    await tl.render();
    info.textLayerEl = tlDiv;
    console.log("[pdf-viewer] text layer rendered, spans:",
      tlDiv.querySelectorAll("span").length);
  }
}

// ---------------------------------------------------------------------------
// Sentence building
// ---------------------------------------------------------------------------

function buildSentences() {
  for (let pi = 0; pi < pageInfo.length; pi++) {
    const items = pageInfo[pi].textContent.items;
    // Group items into paragraphs using Y-position gaps.
    const paragraphs = [];
    let para = [];
    let prevY = null;

    for (const item of items) {
      if (!item.str) continue;
      const y = item.transform ? item.transform[5] : null;
      const h = item.height || 12;
      if (prevY !== null && y !== null && Math.abs(y - prevY) > h * 1.3) {
        if (para.length) paragraphs.push(para);
        para = [];
      }
      para.push(item.str);
      if (y !== null) prevY = y;
      if (item.hasEOL) {
        // An EOL without a large Y gap is a soft line break within the
        // same paragraph; just add a space.
      }
    }
    if (para.length) paragraphs.push(para);

    for (const p of paragraphs) {
      const text = p.join(" ").replace(/\s+/g, " ").trim();
      if (text.length < 2) continue;
      const block = /[.!?:;,]$/.test(text) ? text : text + ".";
      for (const s of block.split(SENTENCE_BREAK)) {
        if (!s.trim()) continue;
        sentences.push(s);
        sentencePages.push(pi);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Lazy canvas rendering
// ---------------------------------------------------------------------------

function setupLazyCanvas() {
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const pi = pageInfo.findIndex((p) => p.div === entry.target);
        if (pi >= 0) renderCanvas(pi);
      }
    },
    { rootMargin: "200px" },
  );
  for (const info of pageInfo) io.observe(info.div);
}

function renderCanvas(pi) {
  const info = pageInfo[pi];
  if (info.canvasRendered) return;
  info.canvasRendered = true;

  const canvas = document.createElement("canvas");
  canvas.width = info.viewport.width;
  canvas.height = info.viewport.height;
  // Canvas goes before the text layer so text sits on top.
  info.div.insertBefore(canvas, info.textLayerEl);

  info.page.render({
    canvasContext: canvas.getContext("2d"),
    viewport: info.viewport,
  });
}

// ---------------------------------------------------------------------------
// Highlighting
// ---------------------------------------------------------------------------

function sentenceRange(idx) {
  if (rangeCache.has(idx)) return rangeCache.get(idx);

  const pi = sentencePages[idx];
  const info = pageInfo[pi];
  const sentence = sentences[idx];
  if (!info?.textLayerEl || !sentence) {
    rangeCache.set(idx, null);
    return null;
  }

  // Walk text nodes of the page's text layer and search for the sentence.
  const nodes = [];
  let raw = "";
  const walker = document.createTreeWalker(
    info.textLayerEl, NodeFilter.SHOW_TEXT,
  );
  while (walker.nextNode()) {
    nodes.push({ node: walker.currentNode, start: raw.length });
    raw += walker.currentNode.data;
  }

  let pat = sentence
    .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    .replace(/ /g, "[\\s\\u00a0]*");
  if (pat.endsWith("\\.")) pat = pat.slice(0, -2) + "\\.?";
  const m = raw.match(new RegExp(pat));
  let result = null;
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
  rangeCache.set(idx, result);
  return result;
}

function highlight(blockRange) {
  if (!sentenceHl) return;
  sentenceHl.clear();

  if (!blockRange) return;
  const [lo, hi] = blockRange;

  for (let i = Math.max(0, lo); i <= hi && i < sentences.length; i++) {
    const r = sentenceRange(i);
    if (r) sentenceHl.add(r);
  }

  // Scroll the first highlighted sentence into view and ensure its
  // canvas is rendered.
  const pi = sentencePages[lo];
  if (pi != null) {
    const info = pageInfo[pi];
    if (info && !info.canvasRendered) renderCanvas(pi);
    const r = sentenceRange(lo);
    if (r) {
      r.startContainer.parentElement?.scrollIntoView({
        block: "center",
        behavior: "smooth",
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Position messages (offscreen → all extension contexts via runtime)
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((msg) => {
  if (msg.cmd === "position")
    console.log("[pdf-viewer] position:", msg.block, "active:", isActive);
  if (!isActive) return;

  if (msg.cmd === "position") {
    paused = !!msg.paused;
    renderControls(msg);
    if (msg.block && !(seekHold > performance.now())) {
      currentBlock = msg.block[0];
      highlight(msg.block);
    }
  }
});

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

function renderControls(state) {
  pauseBtn.classList.toggle("paused", paused);
  pauseBtn.title = paused ? "Resume (p)" : "Pause (p)";
  ctlStatus.classList.toggle("paused", paused);
  ctlStatus.textContent = paused ? "paused" : "speaking";
  if (state?.rate)
    rateVal.textContent = Math.round(state.rate * 100) / 100 + "x";
}

async function togglePause() {
  const r = await chrome.runtime
    .sendMessage({ cmd: "player-toggle" })
    .catch(() => null);
  if (!r) return;
  paused = !!r.paused;
  renderControls(r);
}

async function stop() {
  chrome.runtime
    .sendMessage({ cmd: "player", action: "stop" })
    .catch(() => {});
  await rpc("/stop");
  isActive = false;
  controls.style.display = "none";
  highlight(null);
}

async function seek(body) {
  const r = await rpc("/seek", body);
  if (r?.ok) {
    chrome.runtime
      .sendMessage({ cmd: "player", action: "flush" })
      .catch(() => {});
    currentBlock = r.block;
    highlight([r.block, r.block]);
    seekHold = performance.now() + 1200;
  }
}

let persistTimer = null;
async function rateDelta(dir) {
  const r = await chrome.runtime
    .sendMessage({ cmd: "player", action: "rate", delta: dir })
    .catch(() => null);
  if (!r) return;
  rateVal.textContent = Math.round(r.rate * 100) / 100 + "x";
  clearTimeout(persistTimer);
  persistTimer = setTimeout(
    () => chrome.storage.sync.set({ rate: r.rate }),
    500,
  );
}

// Paragraph seek: jump to the first sentence on a different page or
// paragraph group.
function paragraphSeek(dir) {
  if (!sentences.length) return;
  const cur = Math.min(Math.max(currentBlock, 0), sentences.length - 1);
  const curPage = sentencePages[cur];
  let target = null;
  if (dir > 0) {
    for (let i = cur + 1; i < sentences.length; i++) {
      if (sentencePages[i] !== curPage) { target = i; break; }
    }
    if (target === null) target = sentences.length - 1;
  } else {
    let first = cur;
    while (first > 0 && sentencePages[first - 1] === curPage) first--;
    if (first === 0) target = 0;
    else {
      const prevPage = sentencePages[first - 1];
      target = first - 1;
      while (target > 0 && sentencePages[target - 1] === prevPage) target--;
    }
  }
  seek({ block: target });
}

// --- event wiring ---

pauseBtn.addEventListener("click", togglePause);
document.getElementById("stopBtn").addEventListener("click", stop);
document.getElementById("rdown").addEventListener("click", () => rateDelta(-1));
document.getElementById("rup").addEventListener("click", () => rateDelta(1));

document.addEventListener(
  "keydown",
  (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.composedPath()[0];
    if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
      return;
    if (!isActive && e.key !== "p") return;

    if (e.key === "p") togglePause();
    else if (e.key === "o") stop();
    else if (e.key === "j" || e.key === "k")
      seek({ delta: e.key === "j" ? -1 : 1 });
    else if (e.key === "J" || e.key === "K")
      paragraphSeek(e.key === "J" ? -1 : 1);
    else if (e.key === "<" || e.key === ">")
      rateDelta(e.key === ">" ? 1 : -1);
    else return;
    e.preventDefault();
    e.stopPropagation();
  },
  true,
);

// Idle detection: when the channel goes silent, hide controls.
let idlePolls = 0;
setInterval(async () => {
  if (!isActive) return;
  let h;
  try { h = await rpc("/health"); } catch { return; }
  if (!h || h.error) { stop(); return; }
  const ch = h.channels?.extension ?? h;
  const active = ch.active ?? (ch.speaking || ch.pending > 0);
  if (!paused && !active) idlePolls++;
  else idlePolls = 0;
  if (idlePolls >= 6) {
    isActive = false;
    controls.style.display = "none";
  }
}, 500);
