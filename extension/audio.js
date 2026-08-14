import {
  SimpleFilter, SoundTouch, WebAudioBufferSource
} from "./soundtouch.js";

let ctx = null;
let base = null;
let token = "";
let running = false;
let lastSeq = 0;
let lastEpoch = null;
let playedSeq = 0;
let pollAbort = null;
let nextTime = 0;
let scheduled = [];
let reportTimer = null;
let rate = 1;

let onPosition = null;
let onCursor = null;

const clampRate = (r) =>
  Math.min(3, Math.max(0.5, Math.round(r * 4) / 4));

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
  const filter = new SimpleFilter(
    new WebAudioBufferSource(padded), st
  );
  if (startFrame) filter.sourcePosition = startFrame;
  const CHUNK = 16384;
  const tmp = new Float32Array(CHUNK * 2);
  const parts = [];
  let total = 0;
  while (true) {
    const n = filter.extract(tmp, CHUNK);
    if (!n) break;
    parts.push(tmp.slice(0, n * 2));
    total += n;
  }
  let lastSignal = 0;
  let b = total;
  outer: for (let p = parts.length - 1; p >= 0; p--) {
    const part = parts[p];
    b -= part.length / 2;
    for (let i = part.length - 2; i >= 0; i -= 2) {
      if (Math.abs(part[i]) > 1e-4 ||
          Math.abs(part[i + 1]) > 1e-4) {
        lastSignal = b + i / 2 + 1;
        break outer;
      }
    }
  }
  const rawL = raw.getChannelData(0);
  let rawEnd = raw.length;
  while (rawEnd > startFrame &&
         Math.abs(rawL[rawEnd - 1]) <= 1e-4)
    rawEnd--;
  const tailSilence = Math.round(
    (raw.length - rawEnd) / tempo
  );
  const length = Math.max(
    1, Math.min(total, lastSignal + tailSilence)
  );
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

const auth = () =>
  token ? { Authorization: `Bearer ${token}` } : {};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function flush() {
  for (const s of scheduled) {
    try {
      s.source.stop();
    } catch {}
  }
  scheduled = [];
  nextTime = 0;
  if (ctx?.state === "suspended") ctx.resume();
}

function notePlayed(seq) {
  if (seq == null || seq <= playedSeq) return;
  playedSeq = seq;
  emitCursor();
  if (pollAbort && pollAbort.played < playedSeq)
    pollAbort.abort();
}

function emitCursor() {
  if (onCursor)
    onCursor({ seq: lastSeq, played: playedSeq });
}

function report() {
  const now = ctx.currentTime;
  for (const s of scheduled) if (s.end <= now) notePlayed(s.seq);
  scheduled = scheduled.filter((s) => s.end > now);
  const cur = scheduled.find((s) => s.start <= now);
  const playing = scheduled.length > 0;
  if (onPosition)
    onPosition({
      block: cur?.block ?? null,
      playing,
      paused: ctx.state === "suspended",
      rate,
      ...(lastEpoch !== null ? { epoch: lastEpoch } : {}),
    });
  if (!playing && reportTimer) {
    clearInterval(reportTimer);
    reportTimer = null;
  }
}

function makeSource(buf, when, offset, playbackRate) {
  const gain = new GainNode(ctx);
  gain.connect(ctx.destination);
  const source = new AudioBufferSourceNode(ctx, {
    buffer: buf, playbackRate,
  });
  source.connect(gain);
  source.onended = () => gain.disconnect();
  source.start(when, offset);
  return { source, gain };
}

function play(raw, when, contentSec, block, seq) {
  let buf = raw;
  let bufOffset = contentSec;
  let playbackRate = 1;
  if (rate !== 1) {
    let stretched = null;
    try {
      stretched = stretchBuffer(raw, rate, contentSec);
    } catch (e) {
      console.warn(
        "voice-ml player: stretch failed,", e.message
      );
      playbackRate = rate;
    }
    if (stretched) {
      buf = stretched;
      bufOffset = 0;
    } else if (playbackRate === 1) {
      return null;
    }
  } else if (contentSec >= raw.duration) {
    return null;
  }
  const { source, gain } = makeSource(
    buf, when, bufOffset, playbackRate
  );
  const end = when + (buf.duration - bufOffset) / playbackRate;
  const entry = {
    source, gain, raw, rate,
    offset: contentSec, start: when, end, block, seq,
  };
  scheduled.push(entry);
  return entry;
}

function schedule(buf, block, seq) {
  const s = Math.max(ctx.currentTime, nextTime);
  const entry = play(buf, s, 0, block, seq);
  if (!entry) return;
  nextTime = entry.end;
  if (!reportTimer) {
    reportTimer = setInterval(report, 250);
    report();
  }
}

const FADE = 0.005;

function stopEntry(s, when) {
  try {
    if (s.gain && s.start < when) {
      s.gain.gain.setValueAtTime(1, when);
      s.gain.gain.linearRampToValueAtTime(0, when + FADE);
      s.source.stop(when + FADE);
    } else s.source.stop();
  } catch {}
}

function internalSetRate(target) {
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
    const offset =
      s.offset + (audible ? (now - s.start) * s.rate : 0);
    stopEntry(s, now);
    const entry = play(s.raw, t, offset, s.block, s.seq);
    if (!entry) {
      notePlayed(s.seq);
      continue;
    }
    if (audible) {
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
    pollAbort = new AbortController();
    pollAbort.played = playedSeq;
    try {
      resp = await fetch(
        `${base}/segment?channel=extension&after=${lastSeq}` +
          `&played=${playedSeq}&timeout=20`,
        { headers: auth(), signal: pollAbort.signal }
      );
    } catch (e) {
      pollAbort = null;
      if (e.name === "AbortError") continue;
      await sleep(1000);
      continue;
    }
    pollAbort = null;
    if (!resp.ok && resp.status !== 204) {
      console.warn("voice-ml player:", resp.status);
      flush();
      running = false;
      return;
    }
    const epoch = Number(resp.headers.get("X-Epoch"));
    if (lastEpoch !== null && epoch !== lastEpoch) flush();
    lastEpoch = epoch;
    if (resp.status === 204) continue;
    lastSeq = Number(resp.headers.get("X-Seq"));
    emitCursor();
    const blockHdr = resp.headers.get("X-Block");
    const block = blockHdr
      ? blockHdr.split(",").map(Number) : null;
    try {
      schedule(
        await ctx.decodeAudioData(await resp.arrayBuffer()),
        block, lastSeq
      );
    } catch (e) {
      console.warn(
        "voice-ml player: bad segment,", e.message
      );
    }
  }
}

export function start(opts) {
  base = opts.base;
  token = opts.token || "";
  if (opts.rate != null) rate = clampRate(opts.rate);
  if (opts.cursor) {
    lastSeq = Math.max(lastSeq, opts.cursor.played || 0);
    playedSeq = Math.max(
      playedSeq, opts.cursor.played || 0
    );
  }
  onPosition = opts.onPosition || null;
  onCursor = opts.onCursor || null;
  if (!ctx) ctx = new AudioContext();
  if (opts.flush) flush();
  if (ctx.state === "suspended") ctx.resume();
  loop();
}

export function stop() {
  flush();
  running = false;
}

export async function toggle() {
  if (!ctx) return { paused: false };
  await (ctx.state === "suspended"
    ? ctx.resume() : ctx.suspend());
  const now = ctx.currentTime;
  const cur = scheduled.find(
    (s) => s.start <= now && s.end > now
  );
  return {
    paused: ctx.state === "suspended",
    block: cur?.block?.[0] ?? null,
  };
}

export function setRate({ value, delta }) {
  const target = value ?? rate + (delta ?? 0) * 0.25;
  return { rate: internalSetRate(target) };
}
