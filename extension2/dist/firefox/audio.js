import {
  SimpleFilter, SoundTouch, WebAudioBufferSource
} from './soundtouch.js';

let state = {
  ctx: null, base: '', running: false,
  rate: 1.0, lastSeq: -1, lastEpoch: -1,
  playedSeq: -1, pollAbort: null, nextTime: 0,
  scheduled: [], reportTimer: null,
  onPosition: null, onCursor: null,
};

function clampRate(r) {
  return Math.max(0.5, Math.min(3.0,
    Math.round(r * 4) / 4));
}

function makeSource(buf, when, offset, rate) {
  const gain = state.ctx.createGain();
  gain.connect(state.ctx.destination);
  const src = state.ctx.createBufferSource();
  src.buffer = buf;
  src.playbackRate.value = rate;
  src.connect(gain);
  src.start(when, offset);
  return { source: src, gain };
}

function stopEntry(s, when) {
  const t = when || state.ctx.currentTime;
  s.gain.gain.setValueAtTime(
    s.gain.gain.value, t
  );
  s.gain.gain.linearRampToValueAtTime(0, t + 0.005);
  s.source.stop(t + 0.005);
  s.stopped = true;
}

function stretchBuffer(raw, tempo, fromSec) {
  const ch = Math.min(raw.numberOfChannels, 2);
  const sr = raw.sampleRate;
  const dur = raw.duration - fromSec;
  if (dur <= 0) return null;

  const st = new SoundTouch();
  st.tempo = tempo;
  const base = new WebAudioBufferSource(raw);
  // SimpleFilter only processes full 16384-frame batches and drops a
  // short final batch, so feed silence past the end to flush the tail.
  const padded = {
    extract(target, numFrames, position) {
      const got = Math.max(0, base.extract(target, numFrames, position));
      target.fill(0, got * 2, numFrames * 2);
      return numFrames;
    },
  };
  const filter = new SimpleFilter(padded, st);
  // SimpleFilter passes its own sourcePosition to every extract call,
  // so setting the source's position would be overwritten.
  filter.sourcePosition = Math.floor(fromSec * sr);

  const frames = Math.round(dur / tempo * sr);
  if (frames === 0) return null;
  // SoundTouch always emits interleaved stereo, even for mono input.
  const interleaved = new Float32Array(frames * 2);
  let extracted = 0;
  while (extracted < frames) {
    const n = filter.extract(
      interleaved.subarray(extracted * 2), frames - extracted);
    if (n === 0) break;
    extracted += n;
  }
  if (extracted === 0) return null;

  const out = state.ctx.createBuffer(ch, extracted, sr);
  for (let c = 0; c < ch; c++) {
    const chan = out.getChannelData(c);
    for (let i = 0; i < extracted; i++) {
      chan[i] = interleaved[i * 2 + c];
    }
  }
  return out;
}

function play(raw, when, contentSec, block, seq) {
  let buf = raw, offset = 0, pbRate = 1;

  if (state.rate !== 1) {
    const stretched = stretchBuffer(raw, state.rate, 0);
    if (stretched) {
      buf = stretched;
    } else {
      pbRate = state.rate;
    }
  }

  const { source, gain } = makeSource(
    buf, when, offset, pbRate
  );
  const dur = buf.duration / pbRate;
  const entry = {
    source, gain, block, seq,
    start: when, end: when + dur,
    buf: raw, contentSec, origin: 0, rate: state.rate,
    stopped: false,
  };
  source.onended = () => { entry.stopped = true; };
  state.scheduled.push(entry);
  ensureReport();
  return entry;
}

function schedule(buf, block, seq) {
  const now = state.ctx.currentTime;
  const when = Math.max(now, state.nextTime);
  const contentSec = buf.duration;
  const entry = play(buf, when, contentSec, block, seq);
  state.nextTime = entry.end;
  return entry;
}

export function flush() {
  const now = state.ctx?.currentTime || 0;
  for (const s of state.scheduled) {
    if (!s.stopped) stopEntry(s, now);
  }
  state.scheduled = [];
  state.nextTime = 0;
}

function notePlayed(seq) {
  state.playedSeq = seq;
  emitCursor();
}

function emitCursor() {
  if (state.onCursor) {
    state.onCursor({
      seq: state.lastSeq,
      played: state.playedSeq,
    });
  }
}

async function loop() {
  while (state.running) {
    const ac = new AbortController();
    state.pollAbort = ac;
    const url = `${state.base}/segment`
      + `?channel=extension`
      + `&after=${state.lastSeq}`
      + `&played=${state.playedSeq}`
      + `&timeout=20`;
    try {
      const res = await fetch(url, {
        signal: ac.signal,
      });
      if (!state.running) break;
      if (res.status === 204) continue;
      if (!res.ok) {
        await sleep(1000);
        continue;
      }

      const epoch = parseInt(
        res.headers.get('X-Epoch') || '0', 10
      );
      const seq = parseInt(
        res.headers.get('X-Seq') || '0', 10
      );
      const blockHeader = res.headers.get('X-Block');
      const blocks = blockHeader
        ? blockHeader.split(',').map(Number)
        : [];
      const block = blocks.length ? blocks : null;

      if (state.lastEpoch >= 0
          && epoch !== state.lastEpoch) {
        flush();
      }
      state.lastEpoch = epoch;
      state.lastSeq = seq;

      const data = await res.arrayBuffer();
      const raw = await state.ctx.decodeAudioData(data);
      schedule(raw, block, seq);
    } catch (e) {
      if (e.name === 'AbortError') continue;
      if (!state.running) break;
      await sleep(1000);
    }
  }
  state.pollAbort = null;
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

function ensureReport() {
  if (state.reportTimer) return;
  state.reportTimer = setInterval(report, 250);
}

function report() {
  const now = state.ctx.currentTime;

  for (const s of state.scheduled)
    if (s.end <= now) notePlayed(s.seq);
  state.scheduled = state.scheduled.filter(
    s => !s.stopped && s.end > now
  );

  const cur = state.scheduled.find(
    s => s.start <= now && s.end > now
  );

  if (state.onPosition) {
    state.onPosition({
      block: cur?.block ?? null,
      playing: !!cur,
      paused: state.ctx.state === 'suspended',
      rate: state.rate,
      epoch: state.lastEpoch,
    });
  }

  if (state.scheduled.length === 0) {
    clearInterval(state.reportTimer);
    state.reportTimer = null;
    if (state.onPosition) {
      state.onPosition({
        block: null,
        playing: false,
        paused: state.ctx.state === 'suspended',
        rate: state.rate,
        epoch: state.lastEpoch,
      });
    }
  }
}

function internalSetRate(target) {
  const newRate = clampRate(target);
  if (newRate === state.rate) return;
  state.rate = newRate;

  const now = state.ctx.currentTime;
  const live = state.scheduled.filter(
    s => !s.stopped && s.end > now
  );
  if (live.length === 0) return;

  // re-stretch live entries with crossfade
  let nextAt = Math.max(now + 0.005, now);
  for (const s of live) {
    const elapsed = Math.max(0, now - s.start);
    // An entry that was itself re-stretched starts mid-chunk at its origin.
    const origPos = s.origin + elapsed * s.rate;
    const remaining = s.contentSec - origPos;
    if (remaining <= 0) continue;

    stopEntry(s, now);

    const stretched = stretchBuffer(
      s.buf, newRate, origPos
    );
    if (stretched) {
      const { source, gain } = makeSource(
        stretched, nextAt, 0, 1
      );
      const dur = stretched.duration;
      const entry = {
        source, gain, block: s.block, seq: s.seq,
        start: nextAt, end: nextAt + dur,
        buf: s.buf, contentSec: s.contentSec,
        origin: origPos, rate: newRate, stopped: false,
      };
      source.onended = () => {
        entry.stopped = true;
      };
      state.scheduled.push(entry);
      nextAt = entry.end;
    } else {
      const { source, gain } = makeSource(
        s.buf, nextAt, origPos, newRate
      );
      const dur = remaining / newRate;
      const entry = {
        source, gain, block: s.block, seq: s.seq,
        start: nextAt, end: nextAt + dur,
        buf: s.buf, contentSec: s.contentSec,
        origin: origPos, rate: newRate, stopped: false,
      };
      source.onended = () => {
        entry.stopped = true;
      };
      state.scheduled.push(entry);
      nextAt = entry.end;
    }
  }
  state.nextTime = nextAt;
}

export async function start(opts) {
  state.base = opts.base;
  if (opts.rate != null)
    state.rate = clampRate(opts.rate);
  if (opts.cursor) {
    state.lastSeq = Math.max(
      state.lastSeq, opts.cursor.seq ?? 0);
    state.playedSeq = Math.max(
      state.playedSeq, opts.cursor.played ?? 0);
  }
  state.onPosition = opts.onPosition || null;
  state.onCursor = opts.onCursor || null;
  if (!state.ctx) state.ctx = new AudioContext();
  if (opts.flush) flush();
  if (state.ctx.state === 'suspended')
    await state.ctx.resume();
  if (!state.running) {
    state.running = true;
    loop();
  }
}

export function stop() {
  state.running = false;
  if (state.pollAbort) state.pollAbort.abort();
  flush();
  if (state.reportTimer) {
    clearInterval(state.reportTimer);
    state.reportTimer = null;
  }
}

export async function toggle() {
  if (!state.ctx) return { paused: true, block: -1 };
  if (state.ctx.state === 'suspended') {
    await state.ctx.resume();
  } else {
    await state.ctx.suspend();
  }
  const cur = state.scheduled.find(s => {
    const now = state.ctx.currentTime;
    return !s.stopped && s.start <= now && s.end > now;
  });
  return {
    paused: state.ctx.state === 'suspended',
    block: cur?.block ?? null,
  };
}

export function setRate({ value, delta }) {
  const target = value != null
    ? value
    : state.rate + (delta || 0);
  internalSetRate(target);
  return { rate: state.rate };
}
