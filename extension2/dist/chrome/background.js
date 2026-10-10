const IS_CHROME = typeof chrome.offscreen !== "undefined";
const DEFAULTS = {base: "http://127.0.0.1:8765", rate: 1};
let cfg = null, speakTabId = null, audioModule = null;

function config() {
  return cfg ? Promise.resolve(cfg)
    : chrome.storage.sync.get(DEFAULTS).then(v => (cfg = v));
}
chrome.storage.onChanged.addListener((ch, area) => {
  if (area === "sync")
    for (const [k, {newValue}] of Object.entries(ch))
      if (k in DEFAULTS) cfg[k] = newValue;
});

const CH = ["/speak","/stop","/pause","/resume","/seek"];

async function call(path, body) {
  const c = await config();
  const isGet = path === '/health';
  if (!isGet && CH.includes(path))
    body = {channel: 'extension', ...body};
  const opts = {method: isGet ? 'GET' : 'POST'};
  if (!isGet && body)
    opts.body = JSON.stringify(body);
  const res = await fetch(c.base + path, opts);
  const data = await res.json().catch(() => ({}));
  // Server errors are {error: {code, message}}; older daemons sent a string.
  if (!res.ok) {
    const e = data.error;
    throw new Error(e?.message || e?.code || (typeof e === "string" ? e : res.status));
  }
  return data;
}

async function post(path, body) {
  try { return await call(path, body); }
  catch {
    chrome.action.setBadgeBackgroundColor({color: "#c00"});
    chrome.action.setBadgeText({text: "err"});
    setTimeout(
      () => chrome.action.setBadgeText({text: ""}), 3000);
  }
}

async function ensureOffscreen() {
  if (!(await chrome.offscreen.hasDocument()))
    await chrome.offscreen.createDocument({
      url: "offscreen.html",
      reasons: ["AUDIO_PLAYBACK"],
      justification: "audio playback with pitch control"
    });
}

function sendPosition(pos) {
  // The player owns the rate; persisting here covers every input path.
  if (cfg && pos.rate != null && pos.rate !== cfg.rate)
    chrome.storage.sync.set({rate: pos.rate});
  if (speakTabId)
    chrome.tabs.sendMessage(speakTabId,
      {cmd: 'position', ...pos}).catch(() => {});
}
function onCursor(cursor) {
  chrome.storage.session.set({cursor});
}

async function ensureClientPlayback(flush) {
  const c = await config();
  const {cursor} = await chrome.storage.session.get("cursor");
  if (IS_CHROME) {
    await ensureOffscreen();
    chrome.runtime.sendMessage({cmd: "player",
      action: "start", base: c.base,
      rate: c.rate, flush, cursor});
  } else {
    if (!audioModule) audioModule = await import("./audio.js");
    audioModule.start({base: c.base,
      rate: c.rate, flush, cursor,
      onPosition: sendPosition, onCursor});
  }
}

if (IS_CHROME) {
  chrome.alarms.create("keepalive", {periodInMinutes: 0.5});
  chrome.alarms.onAlarm.addListener(async a => {
    if (a.name !== "keepalive") return;
    const all = await chrome.offscreen.listAllContexts?.()
      || [];
    if (!all.length && speakTabId) ensureClientPlayback(false);
  });
}

async function togglePlayer() {
  let r;
  if (IS_CHROME) {
    if (!(await chrome.offscreen.hasDocument()))
      return ensureClientPlayback(false);
    r = await chrome.runtime.sendMessage(
      {cmd: 'player', action: 'toggle'}).catch(() => null);
  } else {
    if (!audioModule) return;
    r = await audioModule.toggle();
  }
  if (!r) return;
  if (r.paused) {
    post('/pause');
    chrome.storage.session.set({pausedBlock: r.block});
  } else {
    post('/resume');
    chrome.storage.session.remove('pausedBlock');
  }
  return r;
}

async function afterSpeak(res, tabId, append) {
  if (!tabId) return;
  speakTabId = tabId;
  chrome.storage.session.set({speakTabId});
  chrome.tabs.sendMessage(tabId,
    {cmd: "inject-overlay"}).catch(() => {});
  await ensureClientPlayback(!append);
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create(
    {id: "speak", title: "Read selection",
     contexts: ["selection"]});
  chrome.contextMenus.create(
    {id: "speak-append", title: "Append selection",
     contexts: ["selection"]});
  chrome.contextMenus.create(
    {id: "read-page", title: "Read page",
     contexts: ["page"]});
});

chrome.contextMenus.onClicked.addListener(
  async (info, tab) => {
    if (info.menuItemId === "read-page") {
      chrome.tabs.sendMessage(tab.id, {cmd: "read-page"});
      return;
    }
    const append = info.menuItemId === "speak-append";
    const res = await post("/speak",
      {text: info.selectionText});
    if (res) afterSpeak(res, tab.id, append);
  });

chrome.runtime.onMessage.addListener(
  (msg, sender, reply) => {
    if (msg.cmd === "position") return sendPosition(msg);
    if (msg.cmd === "cursor") return onCursor(msg);
    if (msg.cmd === "read-tab") {
      chrome.tabs.query({active: true, currentWindow: true},
        ([t]) => t && chrome.tabs.sendMessage(
          t.id, {cmd: "read-page"}));
      return;
    }
    if (msg.cmd === 'player-toggle') {
      togglePlayer()
        .catch(() => null)
        .then(reply);
      return true;
    }
    if (msg.cmd === "player") {
      if (IS_CHROME) {
        ensureOffscreen()
          .then(() => chrome.runtime.sendMessage(msg))
          .catch(() => null)
          .then(reply);
        return true;
      }
      if (audioModule) {
        const a = msg.action;
        if (a === "start") audioModule.start({...msg,
          onPosition: sendPosition, onCursor});
        else if (a === "stop") audioModule.stop();
        else if (a === "toggle") audioModule.toggle().then(reply);
        else if (a === "rate") reply(audioModule.setRate(msg));
        else if (a === "flush") audioModule.flush();
        return a === "toggle";
      }
      return;
    }
    if (msg.path) {
      (async () => {
        try {
          const res = await call(msg.path, msg.body);
          if (msg.path === '/speak')
            afterSpeak(res, sender.tab?.id,
              !!msg.body?.append);
          if (msg.path === '/seek' && msg.body?.block != null)
            chrome.storage.session.set(
              {lastBlock: msg.body.block});
          reply(res);
        } catch (e) {
          reply({error: e.message});
        }
      })();
      return true;
    }
  });

chrome.storage.session.get("speakTabId").then(v => {
  if (v.speakTabId) speakTabId = v.speakTabId;
});
