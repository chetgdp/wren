// Service worker: proxies daemon calls for content scripts, owns the
// context menus, and manages the offscreen audio player used when the
// daemon runs with --playback client (e.g. a remote CUDA box).

const DEFAULTS = { base: "http://127.0.0.1:8765", token: "" };

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
  const { base, token } = await config();
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
    .sendMessage({ cmd: "player", action: "start", base, token, flush })
    .catch(() => {});
}

function afterSpeak(res, tabId, append) {
  if (!res || !(res.queued > 0)) return;
  if (tabId != null) {
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
    chrome.storage.session.get("speakTabId").then(({ speakTabId }) => {
      if (speakTabId != null)
        chrome.tabs.sendMessage(speakTabId, msg).catch(() => {});
    });
    return;
  }
  if (msg.cmd === "player") return; // overlay -> offscreen; not for us
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
