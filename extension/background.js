// Service worker: proxies daemon calls for content scripts, owns the
// context menus, and manages the offscreen audio player. The extension is
// its own daemon channel: every request it makes carries
// channel "extension" and its audio always streams back via GET /segment,
// regardless of how the daemon plays the local channel.

const DEFAULTS = { base: "http://127.0.0.1:8765", token: "", rate: 1 };
const CHANNEL = "extension";
// Calls that act on a channel; keeping them on the extension's own channel
// means its pause/stop buttons never silence other channels' speech.
const CHANNEL_PATHS = ["/speak", "/stop", "/pause", "/resume", "/seek"];

const config = () => chrome.storage.sync.get(DEFAULTS);

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
  try {
    if (!(await chrome.offscreen.hasDocument()))
      await chrome.offscreen.createDocument({
        url: "offscreen.html",
        reasons: ["AUDIO_PLAYBACK"],
        justification: "Play TTS audio fetched from the voice-ml daemon",
      });
  } catch (e) {
    if (!e.message?.includes("single offscreen")) throw e; // create race
  }
}

async function ensureClientPlayback(flush) {
  const { base, token, rate } = await config();
  await ensureOffscreenDocument();
  // Chrome reaps AUDIO_PLAYBACK documents after ~30s without audio, and
  // waiting for the machine queue's turn is silent by design; the alarm
  // rebuilds the player so an interrupted page read resumes instead of
  // dying (see onAlarm below).
  chrome.alarms.create("player-keepalive", { periodInMinutes: 0.5 });
  // The stream cursor survives document teardown here (offscreen docs get
  // no chrome.storage); a rebuilt player resumes after what it already
  // played instead of replaying the server's buffer. A preempting speak
  // invalidated the buffer server-side, so a flush start needs no cursor
  // (and skipping it lets a fresh document track a restarted daemon).
  const { playerCursor } = await chrome.storage.session.get("playerCursor");
  chrome.runtime
    .sendMessage({ cmd: "player", action: "start", base, token, rate, flush,
                   cursor: flush ? null : playerCursor })
    .catch(() => {});
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== "player-keepalive") return;
  if (await chrome.offscreen.hasDocument()) return;
  let health;
  try {
    health = await call("/health");
  } catch {
    return; // transient daemon hiccup: stay armed, retry next period
  }
  const ch = health.channels?.[CHANNEL];
  if (ch?.paused) return; // togglePlayer rebuilds on resume, not before
  // "active" covers what pending/speaking miss: a channel parked waiting
  // for its machine-queue turn holds a mid-utterance batch with pending 0,
  // and clearing here would strand the rest of the read.
  if (ch?.active) await ensureClientPlayback(false);
  else chrome.alarms.clear("player-keepalive"); // session over; let it rest
});

// Pause/resume of client playback routes through here rather than straight
// to the offscreen player: a suspended AudioContext produces no audio, so
// Chrome closes the AUDIO_PLAYBACK document ~30s into a pause. Resume must
// then rebuild - /seek the daemon back to the paused block (seek preempts
// and resumes server-side) and recreate the player document.
let lastBlock = null; // most recent audible block, from position messages

async function togglePlayer() {
  if (await chrome.offscreen.hasDocument()) {
    const r = await chrome.runtime
      .sendMessage({ cmd: "player", action: "toggle" })
      .catch(() => null);
    if (r) {
      if (r.paused)
        chrome.storage.session.set({ pausedBlock: r.block ?? lastBlock });
      else chrome.storage.session.remove("pausedBlock");
      await post(r.paused ? "/pause" : "/resume");
      return r;
    }
  }
  // No player document: Chrome closed it during a long pause, taking the
  // scheduled audio with it. Requeue server-side from the paused block;
  // plain-text speaks aren't seekable, so /resume is the fallback (the
  // daemon un-gates and synthesis continues from its queue).
  const { pausedBlock } = await chrome.storage.session.get("pausedBlock");
  chrome.storage.session.remove("pausedBlock");
  let res = null;
  if (pausedBlock != null) res = await post("/seek", { block: pausedBlock });
  if (!res?.ok) await post("/resume");
  await ensureClientPlayback(false);
  return { paused: false };
}

// Cached copy of speakTabId: position messages arrive every 250ms and a
// storage.session read on each hop adds latency to the highlight. Session
// storage stays the durable copy for service-worker restarts.
let speakTabId = null;

function afterSpeak(res, tabId, append) {
  if (!res || !(res.queued > 0)) return;
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
      /^chrome-extension:.*pdfviewer\.html/i.test(url)) {
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
    if (msg.block) lastBlock = msg.block[0];
    if (speakTabId != null) {
      chrome.tabs.sendMessage(speakTabId, msg).catch(() => {});
      return;
    }
    chrome.storage.session.get("speakTabId").then((stored) => {
      if (stored.speakTabId == null) return;
      speakTabId = stored.speakTabId;
      chrome.tabs.sendMessage(speakTabId, msg).catch(() => {});
    });
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
  if (msg.cmd === "player") return; // overlay/self -> offscreen; not for us
  if (!msg.path) return;
  if (msg.path === "/stop") chrome.alarms.clear("player-keepalive");
  // Content scripts proxy daemon calls through here (they hit CORS directly).
  // A successful /speak also injects the overlay into the sending tab.
  call(msg.path, msg.body)
    .then((res) => {
      if (msg.path === "/speak")
        afterSpeak(res, sender.tab?.id, !!msg.body?.append);
      sendResponse(res);
    })
    .catch((err) => sendResponse({ error: err.message }));
  return true; // async response
});
