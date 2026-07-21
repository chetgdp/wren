// Service worker: proxies daemon calls for content scripts, owns the
// context menus, and manages the offscreen audio player used when the
// daemon runs with --playback client (e.g. a remote CUDA box).

const DEFAULTS = { base: "http://127.0.0.1:8765", token: "", rate: 1 };

const config = () => chrome.storage.sync.get(DEFAULTS);

async function call(path, body) {
  const { base, token } = await config();
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

// --- client playback (daemon started with --playback client) ---
// An offscreen document fetches /segment and plays through Web Audio; the
// service worker can't play audio and in-page playback would hit autoplay
// blocking on context-menu speaks (no user gesture in the page).

async function ensureClientPlayback(flush) {
  let health;
  try {
    health = await call("/health");
  } catch {
    return;
  }
  if (health.playback !== "client") return;
  const { base, token, rate } = await config();
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
  // flush cuts audio already scheduled locally: a preempting /speak already
  // invalidated it server-side, but the player only notices the epoch bump
  // when the next segment arrives.
  chrome.runtime
    .sendMessage({ cmd: "player", action: "start", base, token, rate, flush })
    .catch(() => {});
}

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

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "read-page") {
    if (tab?.id == null) return;
    // The content script extracts and speaks via the message path below.
    chrome.tabs
      .sendMessage(tab.id, { cmd: "read-page" })
      .catch(() => console.warn("voice-ml: no content script (refresh tab?)"));
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
  if (msg.cmd === "player-toggle") {
    togglePlayer()
      .catch((err) => {
        console.warn("voice-ml toggle:", err.message);
        return null;
      })
      .then(sendResponse);
    return true; // async response
  }
  if (msg.cmd === "player") return; // overlay/self -> offscreen; not for us
  if (!msg.path) return;
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
