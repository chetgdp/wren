// Offscreen audio player for --playback client daemons: long-polls
// GET /segment, decodes each wav, and schedules it gaplessly on one
// AudioContext. An X-Epoch change means the server preempted (new /speak,
// /stop, /seek): drop everything scheduled locally.
//
// Reports the playhead (block range of the audible segment) to the
// background worker every 250ms; it forwards to the speaking tab for the
// read-mode highlight.

let ctx = null;
let base = null;
let token = "";
let running = false;
let lastSeq = 0;
let lastEpoch = null;
let nextTime = 0;
let scheduled = []; // [{source, start, end, block}]
let reportTimer = null;

const auth = () => (token ? { Authorization: `Bearer ${token}` } : {});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function flush() {
  for (const s of scheduled) {
    try {
      s.source.stop();
    } catch {}
  }
  scheduled = [];
  nextTime = 0;
}

function report() {
  const now = ctx.currentTime;
  scheduled = scheduled.filter((s) => s.end > now);
  const cur = scheduled.find((s) => s.start <= now);
  const playing = scheduled.length > 0;
  chrome.runtime
    .sendMessage({
      cmd: "position",
      block: cur?.block ?? null,
      playing,
      paused: ctx.state === "suspended",
    })
    .catch(() => {});
  if (!playing && reportTimer) {
    clearInterval(reportTimer);
    reportTimer = null;
  }
}

function schedule(buf, block) {
  const source = new AudioBufferSourceNode(ctx, { buffer: buf });
  source.connect(ctx.destination);
  const start = Math.max(ctx.currentTime, nextTime);
  source.start(start);
  nextTime = start + buf.duration;
  scheduled.push({ source, start, end: nextTime, block });
  if (!reportTimer) reportTimer = setInterval(report, 250);
}

async function loop() {
  if (running) return;
  running = true;
  while (running) {
    let resp;
    try {
      resp = await fetch(`${base}/segment?after=${lastSeq}&timeout=20`, {
        headers: auth(),
      });
    } catch {
      await sleep(1000); // daemon restarting/unreachable; keep trying
      continue;
    }
    if (!resp.ok && resp.status !== 204) {
      // 401 bad token / 404 daemon switched to local playback: stop looping
      console.warn("voice-ml player:", resp.status);
      flush();
      running = false;
      return;
    }
    const epoch = Number(resp.headers.get("X-Epoch"));
    if (lastEpoch !== null && epoch !== lastEpoch) flush(); // preempted
    lastEpoch = epoch;
    if (resp.status === 204) continue; // long-poll timeout; poll again
    lastSeq = Number(resp.headers.get("X-Seq"));
    const blockHdr = resp.headers.get("X-Block");
    const block = blockHdr ? blockHdr.split(",").map(Number) : null;
    try {
      schedule(await ctx.decodeAudioData(await resp.arrayBuffer()), block);
    } catch (e) {
      console.warn("voice-ml player: bad segment,", e.message);
    }
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.cmd !== "player") return;
  if (msg.action === "start") {
    base = msg.base;
    token = msg.token;
    if (!ctx) ctx = new AudioContext();
    if (msg.flush) flush();
    if (ctx.state === "suspended") ctx.resume();
    loop();
    sendResponse({ ok: true });
  } else if (msg.action === "toggle") {
    if (!ctx) {
      sendResponse({ paused: false });
      return;
    }
    (ctx.state === "suspended" ? ctx.resume() : ctx.suspend()).then(() =>
      sendResponse({ paused: ctx.state === "suspended" })
    );
    return true; // async response
  } else if (msg.action === "flush" || msg.action === "stop") {
    flush();
    if (ctx?.state === "suspended") ctx.resume(); // don't sit paused on new audio
    sendResponse({ ok: true });
  }
});
