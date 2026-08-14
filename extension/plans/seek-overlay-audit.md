# Seek/Overlay Performance Audit

## Critical Bugs

### 1. Flush kills audio loop (Chrome) - REGRESSION from audio.js extraction
`offscreen.js` maps both `action:"flush"` and `action:"stop"` to `audio.stop()`,
which sets `running=false` and kills the segment-polling loop. Every j/k seek
sends `{cmd:"player", action:"flush"}` from content.js (line 202). After one
seek, the audio loop is dead. No restart path exists: the keepalive alarm
returns early when the offscreen document is still alive, and the /seek handler
in background.js never calls `ensureClientPlayback`.

**Fix:** Export `flush()` from audio.js (clear queue without killing loop).
Map `action:"flush"` to `audio.flush()` in offscreen.js. Keep `action:"stop"`
mapped to `audio.stop()`.

### 2. Flush is a no-op (Firefox)
background.js line ~298 drops all `cmd:"player"` messages (`return;`). The
flush message from content.js after seek never reaches `audioModule`. Old audio
keeps playing until the daemon's epoch changes on the next segment fetch
(audio.js line 270-271), which can take hundreds of milliseconds.

**Fix:** In background.js onMessage handler, when `!IS_OFFSCREEN` and
`msg.cmd === "player"`, route flush/stop to `audioModule.flush()` /
`audioModule.stop()` directly instead of dropping the message.

### 3. No seek serialization - race condition
`seek()` is async but nothing prevents concurrent calls. Rapid j/k fires N
independent HTTP requests. Responses arrive out of order. Each calls
`highlight()`, causing intermediate block flashes. The last response to arrive
determines the visual state, which may not match the last seek sent.

**Fix:** Add a seek sequence counter. Increment on each seek() call. On
response, check if the counter still matches; if not, discard the response.


## Performance Issues

### 4. Competing smooth scrolls on rapid seek
`highlight()` calls `scrollIntoView({behavior:"smooth"})` on every invocation.
Rapid j/k triggers overlapping smooth scroll animations that jitter.

**Fix:** Use `scrollIntoView({behavior:"instant"})` during rapid seeks
(debounce: if another seek arrives within 100ms, use instant). Or always use
instant for seek-triggered highlights and smooth only for position-driven ones.

### 5. 1200ms seekHold is arbitrary
`__voiceMlSeekHold = performance.now() + 1200` blocks position-driven highlights
for 1200ms. Too long for local TTS (first segment arrives in ~200-500ms), too
short if flush is broken. During the hold, the highlight appears frozen.

**Fix:** Replace wall-clock timeout with a seek epoch. Increment an epoch
counter on seek; position messages carry the epoch from when playback started.
Discard position messages with stale epochs.

### 6. config() reads storage on every HTTP call
`call()` in background.js calls `chrome.storage.sync.get(DEFAULTS)` on every
invocation, including seek and /health polls. Adds ~1-3ms per call.

**Fix:** Cache config in a module-level variable. Update on
`chrome.storage.onChanged`. Read once at startup.

### 7. Overlay polls on fixed 500ms interval
The overlay's /health poll is not adaptive. After seek, status text is stale
for up to 500ms. During idle, polling wastes HTTP requests.

**Fix:** Expose `poll()` on `__voiceMlOverlay` handle so seek() can trigger an
immediate refresh. Or switch to event-driven updates via `__voiceMlClientState`
changes (setter/proxy).


## Minor Issues

### 8. sentenceHl always redrawn
`highlight()` clears and re-adds Highlight API ranges even when the sentence
hasn't changed. The block-level early return checks element identity but not
sentence identity.

### 9. readElements/readSentences have no invalidation
Arrays reference DOM elements captured at readPage() time. SPA navigation or
DOM mutation can make them stale. No MutationObserver watches for changes.

### 10. speakTabId lazy resolution adds latency
background.js position handler falls back to chrome.storage.session.get when
speakTabId is null (after service worker restart). First few position messages
after restart may be dropped.


## Recommended Fix Order

1. Bug #1 (flush kills loop) - immediate, breaks Chrome seek
2. Bug #2 (flush no-op on Firefox) - immediate, audio bleeds after seek
3. Bug #3 (seek serialization) - high priority, visual jitter
4. Perf #4 (competing scrolls) - high priority, visible jank
5. Perf #5 (seekHold) - medium, frozen highlight feel
6. Perf #6 (config cache) - low, marginal latency
7. Perf #7 (overlay poll) - low, cosmetic staleness
