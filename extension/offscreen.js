// Offscreen audio player for --playback client daemons: long-polls
// GET /segment, decodes each wav, and schedules it gaplessly on one
// AudioContext. An X-Epoch change means the server preempted (new /speak,
// /stop, /seek): drop everything scheduled locally.
//
// Reports the playhead (block range of the audible segment) to the
// background worker every 250ms; it forwards to the speaking tab for the
// read-mode highlight.
//
// Playback speed is pitch-preserving: segments are time-stretched offline
// with soundtouch (WSOLA) before scheduling; AudioBufferSourceNode's
// playbackRate resamples and chipmunks the voice, kept only as a fallback.

import { SimpleFilter, SoundTouch, WebAudioBufferSource } from "./soundtouch.js";

let ctx = null;
let base = null;
let token = "";
let running = false;
let lastSeq = 0;
let lastEpoch = null;
let nextTime = 0;
let scheduled = []; // [{source, gain, raw, rate, offset, start, end, block}]
let reportTimer = null;
// Offscreen documents can only use chrome.runtime messaging, so the rate
// arrives with the "start" message (background reads storage) and changes
// are persisted by the overlay, not here.
let rate = 1;

const clampRate = (r) => Math.min(3, Math.max(0.5, Math.round(r * 4) / 4));

// Time-stretch raw's content from fromSec to the end by tempo (>1 = faster),
// preserving pitch. soundtouch's pipeline sits on up to 16384 input frames
// until more arrive, so the source is padded with a second of silence to
// push the real tail through, and the output trimmed back to the expected
// stretched length.
function stretchBuffer(raw, tempo, fromSec) {
  const sr = raw.sampleRate;
  const startFrame = Math.round(fromSec * sr);
  const remain = raw.length - startFrame;
  if (remain <= 0) return null;
  const channels = Math.min(raw.numberOfChannels, 2);
  const padded = new AudioBuffer({
    length: raw.length + sr,
    sampleRate: sr,
    numberOfChannels: channels,
  });
  for (let c = 0; c < channels; c++)
    padded.copyToChannel(raw.getChannelData(c), c);
  const st = new SoundTouch();
  st.tempo = tempo;
  const filter = new SimpleFilter(new WebAudioBufferSource(padded), st);
  if (startFrame) filter.sourcePosition = startFrame;
  const CHUNK = 16384;
  const tmp = new Float32Array(CHUNK * 2); // soundtouch is interleaved stereo
  const parts = [];
  let total = 0;
  while (true) {
    const n = filter.extract(tmp, CHUNK);
    if (!n) break;
    parts.push(tmp.slice(0, n * 2));
    total += n;
  }
  // WSOLA drifts off the nominal ratio by up to ~75ms, so the content end
  // is not exactly at `expected` frames and trimming there either cuts
  // real speech or keeps pad silence. Instead find the last non-silent
  // output sample and keep it plus the segment's own trailing silence
  // (stretched), so genuine pauses survive but pad leakage does not.
  let lastSignal = 0;
  let base = total;
  outer: for (let p = parts.length - 1; p >= 0; p--) {
    const part = parts[p];
    base -= part.length / 2;
    for (let i = part.length - 2; i >= 0; i -= 2) {
      if (Math.abs(part[i]) > 1e-4 || Math.abs(part[i + 1]) > 1e-4) {
        lastSignal = base + i / 2 + 1;
        break outer;
      }
    }
  }
  const rawL = raw.getChannelData(0);
  let rawEnd = raw.length;
  while (rawEnd > startFrame && Math.abs(rawL[rawEnd - 1]) <= 1e-4) rawEnd--;
  const tailSilence = Math.round((raw.length - rawEnd) / tempo);
  const length = Math.max(1, Math.min(total, lastSignal + tailSilence));
  const out = new AudioBuffer({
    length,
    sampleRate: sr,
    numberOfChannels: channels,
  });
  const mono = new Float32Array(CHUNK);
  let pos = 0;
  for (const part of parts) {
    const n = Math.min(part.length / 2, length - pos);
    if (n <= 0) break;
    for (let c = 0; c < channels; c++) {
      for (let i = 0; i < n; i++) mono[i] = part[i * 2 + c];
      out.copyToChannel(mono.subarray(0, n), c, pos);
    }
    pos += n;
  }
  return out;
}

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
      rate,
    })
    .catch(() => {});
  if (!playing && reportTimer) {
    clearInterval(reportTimer);
    reportTimer = null;
  }
}

// Each source plays through its own gain so a mid-buffer rate change can
// crossfade at the splice point instead of hard-cutting (which clicks).
function makeSource(buf, when, offset, playbackRate) {
  const gain = new GainNode(ctx);
  gain.connect(ctx.destination);
  const source = new AudioBufferSourceNode(ctx, { buffer: buf, playbackRate });
  source.connect(gain);
  source.onended = () => gain.disconnect(); // don't accumulate nodes on ctx
  source.start(when, offset);
  return { source, gain };
}

// Play raw's content from contentSec onward at the current rate, starting
// at time when. Stretched audio plays at playbackRate 1; if stretching
// fails, raw plays resampled (pitch shifts) rather than going silent.
function play(raw, when, contentSec, block) {
  let buf = raw;
  let bufOffset = contentSec;
  let playbackRate = 1;
  if (rate !== 1) {
    let stretched = null;
    try {
      stretched = stretchBuffer(raw, rate, contentSec);
    } catch (e) {
      console.warn("voice-ml player: stretch failed,", e.message);
      playbackRate = rate;
    }
    if (stretched) {
      buf = stretched;
      bufOffset = 0;
    } else if (playbackRate === 1) {
      return null; // no content left past contentSec
    }
  } else if (contentSec >= raw.duration) {
    return null;
  }
  const { source, gain } = makeSource(buf, when, bufOffset, playbackRate);
  const end = when + (buf.duration - bufOffset) / playbackRate;
  const entry = { source, gain, raw, rate, offset: contentSec, start: when, end, block };
  scheduled.push(entry);
  return entry;
}

function schedule(buf, block) {
  const start = Math.max(ctx.currentTime, nextTime);
  const entry = play(buf, start, 0, block);
  if (!entry) return;
  nextTime = entry.end;
  if (!reportTimer) {
    reportTimer = setInterval(report, 250);
    report(); // highlight the first segment now, not a tick later
  }
}

const FADE = 0.005; // 5ms; enough to dodge the splice click, inaudible in speech

function stopEntry(s, when) {
  try {
    if (s.gain && s.start < when) { // audible: ramp out, then stop
      s.gain.gain.setValueAtTime(1, when);
      s.gain.gain.linearRampToValueAtTime(0, when + FADE);
      s.source.stop(when + FADE);
    } else s.source.stop();
  } catch {}
}

// Change speed of everything queued or playing: re-stretch each pending
// segment's raw audio at the new rate and repack start times gaplessly from
// now. The audible segment resumes from its consumed content position
// (elapsed wall time * its rate, plus wherever it began after an earlier
// change). Works while suspended too: ctx.currentTime is frozen, so the
// math holds and the new schedule plays on resume.
function setRate(target) {
  const newRate = clampRate(target);
  const changed = newRate !== rate;
  rate = newRate;
  if (!ctx || !changed) return rate;
  const now = ctx.currentTime;
  const old = scheduled.filter((s) => s.end > now);
  scheduled = [];
  let t = now;
  for (const s of old) {
    const audible = s.start < now;
    const offset = s.offset + (audible ? (now - s.start) * s.rate : 0);
    stopEntry(s, now);
    const entry = play(s.raw, t, offset, s.block);
    if (!entry) continue; // segment finishes right at the splice
    if (audible) { // fade in at the splice point
      entry.gain.gain.setValueAtTime(0, t);
      entry.gain.gain.linearRampToValueAtTime(1, t + FADE);
    }
    t = entry.end;
  }
  if (scheduled.length) {
    nextTime = t;
    report();
  }
  return rate;
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
    if (msg.rate != null) rate = clampRate(msg.rate);
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
  } else if (msg.action === "rate") {
    const target = msg.value ?? rate + (msg.delta ?? 0) * 0.25;
    sendResponse({ rate: setRate(target) });
  } else if (msg.action === "flush" || msg.action === "stop") {
    flush();
    if (ctx?.state === "suspended") ctx.resume(); // don't sit paused on new audio
    sendResponse({ ok: true });
  }
});
