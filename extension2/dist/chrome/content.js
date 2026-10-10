/* ── extraction ─────────────────────────────── */

const BLOCK_SELECTOR =
  "h1,h2,h3,h4,h5,h6,p,li,blockquote," +
  "figcaption,dt,dd,pre";
const SKIP_ANCESTORS =
  "nav,aside,footer,header,form," +
  "[role=navigation]";
const SENTENCE_BREAK = /(?<=[.!?;:])\s+/;

function toBlocks(candidates) {
  const seen = new Set();
  const elements = [];
  const blocks = [];
  for (const el of candidates) {
    if (seen.has(el)) continue;
    let dominated = false;
    for (const s of seen) {
      if (s.contains(el)) { dominated = true; break; }
    }
    if (dominated) continue;
    // remove ancestors already collected that el contains
    for (let i = elements.length - 1; i >= 0; i--) {
      if (el.contains(elements[i])) {
        seen.delete(elements[i]);
        elements.splice(i, 1);
        blocks.splice(i, 1);
      }
    }
    seen.add(el);
    let text = (el.innerText || "").trim()
      .replace(/\s+/g, " ");
    if (!text) continue;
    if (!/[.!?;:]$/.test(text)) text += ".";
    elements.push(el);
    blocks.push(text);
  }
  return { blocks, elements };
}

function extractXArticle() {
  const root = document.querySelector(
    "[data-testid=twitterArticleReadView]"
  );
  if (!root) return null;
  const divs = root.querySelectorAll(
    '[data-contents] [data-block]'
  );
  if (!divs.length) return null;
  return toBlocks(divs);
}

function extractGeneric() {
  const all = document.querySelectorAll(BLOCK_SELECTOR);
  const candidates = [];
  for (const el of all) {
    if (el.tagName === "PRE") continue;
    if (el.closest(SKIP_ANCESTORS)) continue;
    candidates.push(el);
  }
  return toBlocks(candidates);
}

function extractReadable() {
  return extractXArticle() || extractGeneric();
}

/* ── highlighting ──────────────────────────── */

let hl = {
  elements: [], sentences: [], rangeCache: new Map(),
  currentBlock: 0, lit: [], selectedKey: null,
  seekSeq: 0, latestEpoch: null, seekHoldEpoch: null
};

const HL_NAME = "voice-ml-sentence";
const BLOCK_TINT = "rgba(255,214,90,.18)";
const SENT_COLOR = "rgba(255,180,40,.55)";

// CSP-safe highlight style via adoptedStyleSheets
try {
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(
    `::highlight(${HL_NAME}){background:${SENT_COLOR}}`
  );
  document.adoptedStyleSheets =
    [...document.adoptedStyleSheets, sheet];
} catch (_) {
  // adoptedStyleSheets unsupported; highlight degrades
}

function clearHighlight() {
  for (const el of hl.lit)
    el.style.background = el.__vmBg ?? '';
  hl.lit = [];
  CSS.highlights?.delete(HL_NAME);
  hl.selectedKey = null;
  hl.elements = [];
  hl.sentences = [];
  hl.rangeCache = new Map();
  hl.currentBlock = 0;
  hl.latestEpoch = null;
  hl.seekHoldEpoch = null;
}

// invalidate range cache on DOM mutation
const hlObserver = new MutationObserver(muts => {
  for (const m of muts) {
    if (m.type === "attributes"
        && m.attributeName === "style") continue;
    if (m.target.closest?.("#voice-ml-overlay")) continue;
    hl.rangeCache.clear();
    return;
  }
});
if (document.body) {
  hlObserver.observe(document.body, {
    childList: true, subtree: true,
    characterData: true, attributes: true
  });
} else {
  document.addEventListener('DOMContentLoaded', () => {
    hlObserver.observe(document.body, {
      childList: true, subtree: true,
      characterData: true, attributes: true
    });
  }, { once: true });
}

function textNodesIn(el) {
  const nodes = [];
  const walker = document.createTreeWalker(
    el, NodeFilter.SHOW_TEXT
  );
  let n;
  while ((n = walker.nextNode())) nodes.push(n);
  return nodes;
}

function sentenceRange(i) {
  if (hl.rangeCache.has(i))
    return hl.rangeCache.get(i);
  let result = null;
  const el = hl.elements[i];
  const sentence = hl.sentences[i];
  if (el && sentence) {
    const nodes = textNodesIn(el);
    let raw = '';
    const entries = [];
    for (const node of nodes) {
      entries.push({ node, start: raw.length });
      raw += node.data;
    }
    let pat = sentence
      .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      .replace(/ /g, '[\\s\\u00a0]+');
    if (pat.endsWith('\\.'))
      pat = pat.slice(0, -2) + '\\.?';
    const m = raw.match(new RegExp(pat));
    if (m) {
      const start = m.index;
      const end = start + m[0].length;
      const range = new Range();
      for (const { node, start: ns } of entries) {
        const ne = ns + node.data.length;
        if (ns <= start && start < ne)
          range.setStart(node, start - ns);
        if (ns < end && end <= ne)
          range.setEnd(node, end - ns);
      }
      if (!range.collapsed) result = range;
    }
  }
  hl.rangeCache.set(i, result);
  return result;
}

function highlight(range, instant) {
  for (const el of hl.lit)
    el.style.background = el.__vmBg ?? '';
  hl.lit = [];
  if (CSS.highlights) CSS.highlights.delete(HL_NAME);
  hl.selectedKey = null;
  if (!range) return;
  const [lo, hi] = range;
  hl.currentBlock = lo;
  // collect unique elements in sentence range
  const want = [];
  for (let i = Math.max(0, lo);
       i <= hi && i < hl.elements.length; i++) {
    const el = hl.elements[i];
    if (el && !want.includes(el)) want.push(el);
  }
  for (const el of want) {
    el.__vmBg = el.style.background;
    el.style.background = BLOCK_TINT;
  }
  hl.lit = want;
  // sentence highlight via CSS Custom Highlight API
  const key = lo + ':' + hi;
  if (typeof Highlight !== 'undefined') {
    const ranges = [];
    for (let i = Math.max(0, lo);
         i <= hi && i < hl.sentences.length; i++) {
      const r = sentenceRange(i);
      if (r) ranges.push(r);
    }
    if (ranges.length)
      CSS.highlights.set(HL_NAME,
        new Highlight(...ranges));
    hl.selectedKey = key;
  }
  want[0]?.scrollIntoView({
    block: 'center',
    behavior: instant ? 'instant' : 'smooth',
  });
}

/* ── overlay widget ────────────────────────── */

let overlayEl = null;
let pollTimer = null;

function injectOverlay() {
  if (window.__voiceMlOverlay) {
    window.__voiceMlOverlay.reset();
    return;
  }

  overlayEl = document.createElement("div");
  overlayEl.id = "voice-ml-overlay";
  Object.assign(overlayEl.style, {
    position: "fixed", bottom: "16px", right: "16px",
    zIndex: "2147483647", fontFamily: "system-ui",
    fontSize: "13px"
  });
  const shadow = overlayEl.attachShadow({ mode: "closed" });

  const style = document.createElement("style");
  style.textContent = `
    :host{all:initial}
    .root{display:flex;align-items:center;gap:6px;
      padding:6px 10px;border-radius:8px;
      background:rgba(30,30,30,.95);color:#ddd;
      font:13px system-ui;user-select:none}
    button{background:none;border:none;color:#ddd;
      cursor:pointer;padding:2px 4px;font:inherit;
      display:flex;align-items:center}
    button:hover{color:#fff}
    .rate{min-width:36px;text-align:center}
    svg{width:14px;height:14px;fill:currentColor}
    .spin{display:inline-block;width:10px;height:10px;
      border:2px solid #666;border-top-color:#ddd;border-radius:50%;
      animation:vm-spin .8s linear infinite}
    @keyframes vm-spin{to{transform:rotate(360deg)}}
  `;
  shadow.appendChild(style);

  const root = document.createElement("div");
  root.className = "root";

  const spinnerHtml = `<span class="spin" title="loading speech"></span>`;

  const rateDown = document.createElement("button");
  rateDown.textContent = "−";
  rateDown.onclick = () => api.rateDelta(-1);

  const rateSpan = document.createElement("span");
  rateSpan.className = "rate";
  rateSpan.textContent = "1.00×";
  chrome.storage.sync.get({ rate: 1 }).then(({ rate }) => {
    rateSpan.textContent = rate.toFixed(2) + "×";
  });

  const rateUp = document.createElement("button");
  rateUp.textContent = "+";
  rateUp.onclick = () => api.rateDelta(1);

  const pauseBtn = document.createElement("button");
  const pauseSvg = `<svg viewBox="0 0 24 24">` +
    `<rect x="6" y="4" width="4" height="16"/>` +
    `<rect x="14" y="4" width="4" height="16"/></svg>`;
  const playSvg = `<svg viewBox="0 0 24 24">` +
    `<polygon points="6,4 20,12 6,20"/></svg>`;
  pauseBtn.innerHTML = pauseSvg;
  pauseBtn.onclick = () => api.togglePause();

  const stopBtn = document.createElement("button");
  stopBtn.innerHTML = `<svg viewBox="0 0 24 24">` +
    `<rect x="5" y="5" width="14" height="14"/></svg>`;
  stopBtn.onclick = () => api.stop();

  root.append(rateDown, rateSpan, rateUp, pauseBtn, stopBtn);
  shadow.appendChild(root);
  document.body.appendChild(overlayEl);

  let idlePolls = 0;

  let shown = "pause";
  function updateDisplay() {
    const cs = window.__voiceMlClientState;
    if (cs.rate != null) rateSpan.textContent = cs.rate.toFixed(2) + "×";
    // The button shows the action it performs, or a spinner while
    // speech for a new position is still being synthesized.
    const want = hl.seekHoldEpoch != null ? "load"
      : cs.paused ? "play" : "pause";
    if (want === shown) return;
    shown = want;
    pauseBtn.innerHTML = want === "load" ? spinnerHtml
      : want === "play" ? playSvg : pauseSvg;
  }

  function poll() {
    chrome.runtime.sendMessage(
      { path: "/health" },
      resp => {
        if (chrome.runtime.lastError) return;
        const ch = resp?.channels?.extension;
        if (!ch || !(ch.active ?? (ch.speaking || ch.pending > 0))) {
          idlePolls++;
          if (idlePolls >= 6) removeOverlay();
        } else {
          idlePolls = 0;
        }
        updateDisplay();
      }
    );
  }

  function removeOverlay() {
    clearInterval(pollTimer);
    pollTimer = null;
    overlayEl?.remove();
    overlayEl = null;
    clearHighlight();
    window.__voiceMlOverlay = null;
    window.__voiceMlClientState.playing = false;
    window.__voiceMlClientState.paused = false;
  }

  const api = {
    reset() { idlePolls = 0; },
    poll,
    updateDisplay,
    togglePause() {
      const cs = window.__voiceMlClientState;
      cs.paused = !cs.paused;
      hl.togglePending = true;
      updateDisplay();
      chrome.runtime.sendMessage({ cmd: "player-toggle" }, r => {
        hl.togglePending = false;
        if (r?.paused != null) cs.paused = r.paused;
        updateDisplay();
      });
    },
    stop() {
      chrome.runtime.sendMessage(
        { cmd: "player", action: "stop" }
      );
      chrome.runtime.sendMessage({ path: "/stop" });
      removeOverlay();
    },
    rateDelta(dir) {
      chrome.runtime.sendMessage(
        { cmd: "player", action: "rate", delta: dir * 0.05 }
      );
    }
  };

  window.__voiceMlOverlay = api;
  pollTimer = setInterval(poll, 500);
  poll();
}

window.__voiceMlInjectOverlay = injectOverlay;

/* ── keybinds & messaging ──────────────────── */

window.__voiceMlClientState = {
  playing: false, paused: false
};
window.__voiceMlReader = { highlight };

function readPage(fromSelection) {
  const { blocks, elements } = extractReadable();
  if (!blocks.length) return;
  highlight(null);
  const sentences = [];
  const sentElements = [];
  hl.rangeCache = new Map();
  blocks.forEach((block, i) => {
    for (const s of block.split(SENTENCE_BREAK)) {
      if (!s.trim()) continue;
      sentences.push(s);
      sentElements.push(elements[i]);
    }
  });
  if (fromSelection) {
    const node = window.getSelection()?.anchorNode;
    const start = node
      ? sentElements.findIndex(el => el.contains(node))
      : -1;
    if (start > 0) {
      sentences.splice(0, start);
      sentElements.splice(0, start);
    }
  }
  hl.elements = sentElements;
  hl.sentences = sentences;
  hl.currentBlock = 0;
  hl.seekHoldEpoch = hl.latestEpoch ?? -1;
  injectOverlay();
  window.__voiceMlClientState.playing = true;
  window.__voiceMlOverlay?.updateDisplay();
  chrome.runtime.sendMessage(
    { path: '/speak', body: { blocks: sentences } }
  ).then(r => { if (r?.error) endLoading(); }, endLoading);
}

function endLoading() {
  hl.seekHoldEpoch = null;
  window.__voiceMlOverlay?.updateDisplay();
}

let seekSequence = 0;
async function seek(block) {
  const seq = ++seekSequence;
  // Move the highlight and silence old audio now; the voice follows when
  // the server has synthesized from the new block.
  hl.seekHoldEpoch ??= hl.latestEpoch ?? -1;
  highlight([block, block], true);
  window.__voiceMlOverlay?.updateDisplay();
  chrome.runtime.sendMessage(
    { cmd: 'player', action: 'flush' }).catch(() => {});
  const r = await chrome.runtime.sendMessage(
    { path: '/seek', body: { block } }).catch(() => null);
  if (seq !== seekSequence) return;
  if (!r?.ok) {
    endLoading();
    return;
  }
  window.__voiceMlOverlay?.poll();
}

function seekBase() {
  return Math.min(Math.max(hl.currentBlock, 0), hl.elements.length - 1);
}

function sentenceSeek(dir) {
  if (!hl.elements.length) return;
  seek(Math.min(Math.max(seekBase() + dir, 0),
    hl.elements.length - 1));
}

function paragraphSeek(dir) {
  if (!hl.elements.length) return;
  const cur = seekBase();
  const el = hl.elements[cur];
  let target = null;
  if (dir > 0) {
    for (let i = cur + 1; i < hl.elements.length; i++)
      if (hl.elements[i] !== el) { target = i; break; }
    if (target === null)
      target = hl.elements.length - 1;
  } else {
    let first = cur;
    while (first > 0 && hl.elements[first - 1] === el)
      first--;
    if (first === 0) target = 0;
    else {
      const prevEl = hl.elements[first - 1];
      target = first - 1;
      while (target > 0
             && hl.elements[target - 1] === prevEl)
        target--;
    }
  }
  seek(target);
}

document.addEventListener("keydown", e => {
  const t = e.composedPath()[0] || e.target;
  if (t.isContentEditable
      || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
    return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  switch (e.key) {
    case "i": {
      const sel = window.getSelection()?.toString().trim();
      if (!sel) break;
      e.preventDefault();
      chrome.runtime.sendMessage(
        { path: '/speak', body: { text: sel } });
      break;
    }
    case "p":
      e.preventDefault();
      if (window.getSelection()?.toString().trim()) {
        readPage(true);
      } else if (window.__voiceMlOverlay) {
        window.__voiceMlOverlay.togglePause();
      } else {
        readPage();
      }
      break;
    case "o":
      if (window.__voiceMlOverlay) {
        e.preventDefault();
        window.__voiceMlOverlay.stop();
      }
      break;
    case "j":
      e.preventDefault();
      sentenceSeek(-1);
      break;
    case "k":
      e.preventDefault();
      sentenceSeek(1);
      break;
    case "J":
      e.preventDefault();
      paragraphSeek(-1);
      break;
    case "K":
      e.preventDefault();
      paragraphSeek(1);
      break;
    case "<":
      e.preventDefault();
      window.__voiceMlOverlay?.rateDelta(-1);
      break;
    case ">":
      e.preventDefault();
      window.__voiceMlOverlay?.rateDelta(1);
      break;
  }
}, true);

chrome.runtime.onMessage.addListener((msg, _, reply) => {
  if (msg.cmd === 'read-page') {
    readPage();
    reply({ ok: true });
  } else if (msg.cmd === 'position') {
    const epoch = msg.epoch;
    if (epoch != null) {
      if (hl.latestEpoch !== null
          && epoch < hl.latestEpoch) return;
      hl.latestEpoch = epoch;
    }
    window.__voiceMlClientState = {
      playing: msg.playing,
      // A position sent before the toggle landed would flip the button back.
      paused: hl.togglePending
        ? window.__voiceMlClientState.paused : msg.paused,
      rate: msg.rate,
      epoch,
    };
    const held = hl.seekHoldEpoch != null
      && (epoch == null || epoch <= hl.seekHoldEpoch);
    if (!held) hl.seekHoldEpoch = null;
    window.__voiceMlOverlay?.updateDisplay();
    if (!held && msg.block) highlight(msg.block);
  } else if (msg.cmd === 'inject-overlay') {
    injectOverlay();
    reply({ ok: true });
  }
  return false;
});
