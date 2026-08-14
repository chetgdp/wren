// Service worker: proxies daemon calls for content scripts, owns the
// context menus, and manages the offscreen audio player. The extension is
// its own daemon channel: every request it makes carries
// channel "extension" and its audio always streams back via GET /segment,
// regardless of how the daemon plays the local channel.

const IS_OFFSCREEN = typeof chrome.offscreen !== "undefined";

let audioModule = null;
const audioModuleReady = IS_OFFSCREEN
  ? Promise.resolve(null)
  : import("./audio.js").then((module) => {
    audioModule = module;
    return module;
  });
const DEFAULTS = { base: "http://127.0.0.1:8765", token: "", rate: 1 };
const CHANNEL = "extension";
// Calls that act on a channel; keeping them on the extension's own channel
// means its pause/stop buttons never silence other channels' speech.
const CHANNEL_PATHS = ["/speak", "/stop", "/pause", "/resume", "/seek"];

let cachedConfig = { ...DEFAULTS };
let configReady = false;
let configInitPromise = chrome.storage.sync.get(DEFAULTS).then((stored) => {
  if (!configReady) cachedConfig = { ...DEFAULTS, ...stored };
  configReady = true;
}).catch((err) => {
  console.warn("voice-ml config:", err.message);
  configReady = true;
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "sync") return;
  for (const key of Object.keys(DEFAULTS)) {
    if (changes[key]) cachedConfig[key] =
      changes[key].newValue ?? DEFAULTS[key];
  }
  configReady = true;
});

const config = () => configInitPromise.then(() => cachedConfig);

async function call(path, body) {
  const { base, token } = await config();
  if (CHANNEL_PATHS.includes(path)) body = { channel: CHANNEL, ...body };
  const res = await fetch(base + path, {
    method: path === "/health" ? "GET" : "POST",
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || res.status);
  return data;
}

async function post(path, body) {
  try {
    return await call(path, body);
  } catch (err) {
    // 503 = model loading, 401 = bad token, network error = daemon not running
    chrome.action.setBadgeText({ text: "err" });
    chrome.action.setBadgeBackgroundColor({ color: "#c0392b" });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 3000);
    console.warn("voice-ml:", err.message);
    return null;
  }
}

// --- client playback of the extension channel ---
// An offscreen document fetches /segment and plays through Web Audio; the
// service worker can't play audio and in-page playback would hit autoplay
// blocking on context-menu speaks (no user gesture in the page).

async function ensureOffscreenDocument() {
  if (!IS_OFFSCREEN) return;
  try {
    if (!(await chrome.offscreen.hasDocument()))
      await chrome.offscreen.createDocument({
        url: "offscreen.html",
        reasons: ["AUDIO_PLAYBACK"],
        justification: "Play TTS audio fetched from the voice-ml daemon",
      });
  } catch (e) {
    if (!/single offscreen|already exists/i.test(e?.message || "")) throw e;
  }
}

async function ensureClientPlayback(flush) {
  const { base, token, rate } = await config();
  await ensureOffscreenDocument();
  if (IS_OFFSCREEN) {
    chrome.alarms.create("player-keepalive", {
      periodInMinutes: 0.5,
    });
    const { playerCursor } =
      await chrome.storage.session.get("playerCursor");
    chrome.runtime
      .sendMessage({
        cmd: "player", action: "start",
        base, token, rate, flush,
        cursor: flush ? null : playerCursor,
      })
      .catch(() => {});
  } else {
    const module = await audioModuleReady;
    const { playerCursor } =
      await chrome.storage.session.get("playerCursor");
    module.start({
      base, token, rate, flush,
      cursor: flush ? null : playerCursor,
      onPosition: (pos) => sendPosition(pos),
      onCursor: (cur) => {
        chrome.storage.session.set({
          playerCursor: {
            seq: cur.seq, played: cur.played,
          },
        });
      },
    });
  }
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== "player-keepalive") return;
  if (!IS_OFFSCREEN) return;
  if (await chrome.offscreen.hasDocument()) return;
  let health;
  try {
    health = await call("/health");
  } catch {
    return;
  }
  const ch = health.channels?.[CHANNEL];
  if (ch?.paused) return;
  if (ch?.active) await ensureClientPlayback(false);
  else chrome.alarms.clear("player-keepalive");
});

let lastBlock = null;

async function togglePlayer() {
  if (IS_OFFSCREEN) {
    if (await chrome.offscreen.hasDocument()) {
      const r = await chrome.runtime
        .sendMessage({ cmd: "player", action: "toggle" })
        .catch(() => null);
      if (r) {
        if (r.paused)
          chrome.storage.session.set({
            pausedBlock: r.block ?? lastBlock,
          });
        else chrome.storage.session.remove("pausedBlock");
        await post(r.paused ? "/pause" : "/resume");
        return r;
      }
    }
  } else {
    const module = await audioModuleReady;
    const r = await module.toggle();
    if (r.paused)
      chrome.storage.session.set({
        pausedBlock: r.block ?? lastBlock,
      });
    else chrome.storage.session.remove("pausedBlock");
    await post(r.paused ? "/pause" : "/resume");
    return r;
  }
  const { pausedBlock } =
    await chrome.storage.session.get("pausedBlock");
  chrome.storage.session.remove("pausedBlock");
  let res = null;
  if (pausedBlock != null)
    res = await post("/seek", { block: pausedBlock });
  if (!res?.ok) await post("/resume");
  await ensureClientPlayback(false);
  return { paused: false };
}

// Cached copy of speakTabId: position messages arrive every 250ms and a
// storage.session read on each hop adds latency to the highlight. Session
// storage stays the durable copy for service-worker restarts.
let speakTabId = null;
let speakTabReady = false;
const speakTabInitPromise = chrome.storage.session.get("speakTabId")
  .then((stored) => {
    if (speakTabId == null && stored.speakTabId != null)
      speakTabId = stored.speakTabId;
    speakTabReady = true;
  })
  .catch(() => {
    speakTabReady = true;
  });

function sendPosition(pos) {
  if (pos.block) lastBlock = pos.block[0];
  const send = () => {
    if (speakTabId != null)
      chrome.tabs.sendMessage(speakTabId, {
        cmd: "position", ...pos,
      }).catch(() => {});
  };
  if (speakTabReady) send();
  else speakTabInitPromise.then(send);
}

function afterSpeak(res, tabId, append) {
  if (!append) {
    // A preempting speak invalidates any position saved by an earlier pause.
    lastBlock = null;
    chrome.storage.session.remove("pausedBlock");
  }
  if (tabId != null) {
    speakTabId = tabId;
    chrome.storage.session.set({ speakTabId: tabId });
    chrome.scripting
      .executeScript({ target: { tabId }, files: ["overlay.js"] })
      .catch((e) => console.warn("voice-ml overlay:", e.message));
  }
  ensureClientPlayback(!append);
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "speak",
    title: "Speak selection",
    contexts: ["selection"],
  });
  chrome.contextMenus.create({
    id: "speak-append",
    title: "Speak selection (queue after current)",
    contexts: ["selection"],
  });
  chrome.contextMenus.create({
    id: "read-page",
    title: "Read page",
    contexts: ["page"],
  });
});

// PDF path: Chrome's PDF viewer never runs content scripts. Instead of
// extracting in the offscreen document, open a dedicated PDF.js viewer
// tab that renders the PDF with a text layer for sentence highlighting.
async function readPdfTab(url) {
  if (!IS_OFFSCREEN) return;
  const viewerUrl =
    chrome.runtime.getURL("pdfviewer.html") +
    "?url=" + encodeURIComponent(url);
  chrome.tabs.create({ url: viewerUrl });
}

async function readTab(tab) {
  if (tab?.id == null) return;
  const url = tab.url ?? "";
  // PDF URLs: go straight to the viewer (content script finds nothing
  // useful inside Chrome's PDF embed).
  if (/\.pdf(\?[^#]*)?(#.*)?$/i.test(url) ||
      /^(chrome|moz)-extension:.*pdfviewer\.html/i.test(url)) {
    if (/^https?:/.test(url)) readPdfTab(url);
    return;
  }
  try {
    await chrome.tabs.sendMessage(tab.id, { cmd: "read-page" });
  } catch {
    if (/^https?:/.test(url)) readPdfTab(url);
    else console.warn("voice-ml: no content script (refresh tab?)");
  }
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "read-page") {
    readTab(tab);
    return;
  }
  if (!info.selectionText) return;
  const append = info.menuItemId === "speak-append";
  const res = await post("/speak", { text: info.selectionText, append });
  afterSpeak(res, tab?.id, append);
});

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Playhead updates from the offscreen player -> content script of the
  // tab that last spoke (runtime.sendMessage can't reach content scripts).
  if (msg.cmd === "position") {
    sendPosition(msg);
    return;
  }
  if (msg.cmd === "read-tab") {
    // Popup trigger: the context menu is unreliable inside Chrome's PDF
    // viewer, so the popup asks for the active tab to be read.
    chrome.tabs
      .query({ active: true, currentWindow: true })
      .then(([tab]) => readTab(tab));
    return;
  }
  if (msg.cmd === "player-toggle") {
    togglePlayer()
      .catch((err) => {
        console.warn("voice-ml toggle:", err.message);
        return null;
      })
      .then(sendResponse);
    return true; // async response
  }
  if (msg.cmd === "cursor") {
    // The offscreen player's stream position, persisted so a rebuilt
    // document resumes where the reaped one left off.
    chrome.storage.session.set({
      playerCursor: { seq: msg.seq, played: msg.played },
    });
    return;
  }
  if (msg.cmd === "player") {
    if (!IS_OFFSCREEN) {
      audioModuleReady.then((module) => {
        if (msg.action === "flush") module.flush();
        else if (msg.action === "stop") module.stop();
        else if (msg.action === "rate") {
          sendResponse(
            module.setRate({
              value: msg.value, delta: msg.delta,
            })
          );
        }
      }).catch(() => {});
      if (msg.action === "rate") return true;
    }
    return;
  }
  if (!msg.path) return;
  if (msg.path === "/stop") chrome.alarms.clear("player-keepalive");
  // Content scripts proxy daemon calls through here (they hit CORS directly).
  // A successful /speak also injects the overlay into the sending tab.
  call(msg.path, msg.body)
    .then((res) => {
      if (msg.path === "/speak")
        afterSpeak(res, sender.tab?.id, !!msg.body?.append);
      if (msg.path === "/seek" && res?.ok && res.block != null)
        lastBlock = res.block;
      sendResponse(res);
    })
    .catch((err) => sendResponse({ error: err.message }));
  return true; // async response
});
