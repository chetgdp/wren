// In-page control widget, injected when a speak starts. Guards against
// double-injection; a re-speak while the widget is up just keeps it alive.
(() => {
  if (window.__voiceMlOverlay) {
    window.__voiceMlOverlay.reset();
    return;
  }

  const call = (path) => chrome.runtime.sendMessage({ path });

  const host = document.createElement("div");
  host.style.cssText =
    "position:fixed;bottom:16px;right:16px;z-index:2147483647;";
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
    <style>
      .box {
        display: flex; align-items: center; gap: 10px;
        padding: 8px 12px; border-radius: 8px;
        background: rgba(30,30,30,.95); color: #ddd;
        font: 13px -apple-system, sans-serif;
        box-shadow: 0 2px 10px rgba(0,0,0,.4);
      }
      .status { min-width: 70px; color: #6fcf6f; }
      .status.paused { color: #e0b94f; }
      button {
        display: flex; align-items: center; justify-content: center;
        width: 28px; height: 28px;
        border: 0; border-radius: 5px; padding: 0;
        background: #3a3a3a; cursor: pointer;
      }
      button:hover { background: #4a4a4a; }
      svg { width: 14px; height: 14px; fill: #ddd; }
      #pause .play { display: none; }
      #pause.paused .play { display: block; }
      #pause.paused .bars { display: none; }
      .ratectl { display: none; }
      .box.client button.ratectl {
        display: flex; font-size: 15px; font-family: inherit; color: #ddd;
      }
      .box.client span.ratectl {
        display: inline-block; min-width: 34px; text-align: center; color: #aaa;
      }
    </style>
    <div class="box client">
      <span class="status">speaking</span>
      <button id="rdown" class="ratectl" title="Slower (<)">-</button>
      <span id="rate" class="ratectl">1x</span>
      <button id="rup" class="ratectl" title="Faster (>)">+</button>
      <button id="pause" title="Pause (p)">
        <svg class="bars" viewBox="0 0 16 16"><rect x="3" y="2" width="4" height="12" rx="1"/><rect x="9" y="2" width="4" height="12" rx="1"/></svg>
        <svg class="play" viewBox="0 0 16 16"><path d="M4 2.5v11a.6.6 0 0 0 .9.5l9-5.5a.6.6 0 0 0 0-1l-9-5.5a.6.6 0 0 0-.9.5z"/></svg>
      </button>
      <button id="stop" title="Stop (o)">
        <svg viewBox="0 0 16 16"><rect x="3" y="3" width="10" height="10" rx="1.5"/></svg>
      </button>
    </div>`;
  document.documentElement.appendChild(host);

  const statusEl = root.querySelector(".status");
  const pauseBtn = root.querySelector("#pause");
  const rateEl = root.querySelector("#rate");
  let paused = false;
  let idlePolls = 0;
  let timer = null;

  function render(h) {
    paused = !!h.paused;
    pauseBtn.title = paused ? "Resume (p)" : "Pause (p)";
    pauseBtn.classList.toggle("paused", paused);
    statusEl.classList.toggle("paused", paused);
    statusEl.textContent = paused
      ? "paused"
      : h.pending > 0
        ? `speaking (${h.pending})`
        : "speaking";
  }

  function remove() {
    clearInterval(timer);
    window.__voiceMlReader?.highlight(null);
    host.remove();
    delete window.__voiceMlOverlay;
  }

  async function poll() {
    let h;
    try {
      h = await call("/health");
    } catch {
      h = null; // extension reloaded; sendMessage throws
    }
    if (!h || h.error) return remove();
    // The extension is its own client-played channel: /health's top-level
    // fields are machine-wide, so speaking/pending come from the channel
    // entry, and paused/playing/block/rate from the offscreen player's
    // position broadcasts (via content.js), which also drive the highlight.
    const ch = h.channels?.extension ?? h;
    const st = window.__voiceMlClientState || {};
    // "active" covers content pending/speaking miss (a batch parked
    // waiting for its machine-queue turn), so the overlay survives an
    // agent's turn mid-read; older daemons lack it, hence the fallback.
    h = { paused: st.paused, pending: ch.pending,
          speaking: ch.speaking || st.playing,
          active: ch.active ?? (ch.speaking || ch.pending > 0) };
    showRate(st.rate);
    render(h);
    // First chunk takes a moment to synthesize, so require several
    // consecutive idle reads before concluding playback is done.
    idlePolls = !h.paused && !h.speaking && !h.active ? idlePolls + 1 : 0;
    if (idlePolls >= 6) remove();
  }

  function showRate(r) {
    if (r) rateEl.textContent = Math.round(r * 100) / 100 + "x";
  }

  let persistTimer = null;
  async function rateDelta(dir) {
    const r = await chrome.runtime
      .sendMessage({ cmd: "player", action: "rate", delta: dir })
      .catch(() => null);
    if (!r) return;
    showRate(r.rate);
    // Persisted here because the offscreen player can't touch chrome.storage
    // (offscreen documents only get runtime messaging). Debounced: sync
    // throttles writes and a held key would blow the quota.
    clearTimeout(persistTimer);
    persistTimer = setTimeout(
      () => chrome.storage.sync.set({ rate: r.rate }), 500);
  }

  async function togglePause() {
    // Via the background worker, which gates the daemon (/pause keeps it
    // from synthesizing the whole page while paused) and rebuilds the
    // player when Chrome closed it during a long pause.
    const r = await chrome.runtime
      .sendMessage({ cmd: "player-toggle" })
      .catch(() => null);
    if (!r) return;
    // Position broadcasts stall while paused or rebuilding; sync the
    // cached state so the next poll doesn't repaint the stale value.
    window.__voiceMlClientState = {
      ...window.__voiceMlClientState,
      paused: r.paused,
    };
    render({ paused: r.paused, pending: 0 });
  }

  // /stop goes out with the extension's channel (added by the background
  // worker), so it only silences this channel, never other channels'
  // speech.
  async function stop() {
    chrome.runtime
      .sendMessage({ cmd: "player", action: "stop" })
      .catch(() => {});
    await call("/stop");
    remove();
  }

  pauseBtn.addEventListener("click", togglePause);
  root.querySelector("#stop").addEventListener("click", stop);
  root.querySelector("#rdown").addEventListener("click", () => rateDelta(-1));
  root.querySelector("#rup").addEventListener("click", () => rateDelta(1));

  timer = setInterval(poll, 500);
  // Keybinds live in content.js and drive the overlay through this handle.
  window.__voiceMlOverlay =
    { reset: () => (idlePolls = 0), togglePause, stop, rateDelta };
})();
