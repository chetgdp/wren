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
    <div class="box">
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
  const boxEl = root.querySelector(".box");
  const rateEl = root.querySelector("#rate");
  let paused = false;
  let idlePolls = 0;
  let timer = null;
  let clientMode = false; // daemon runs --playback client; audio is local

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
    clientMode = h.playback === "client";
    boxEl.classList.toggle("client", clientMode); // rate is client-side only
    if (clientMode) {
      // /health knows synthesis, not local playback; the offscreen player's
      // position broadcasts (via content.js) carry paused/playing/block/rate.
      const st = window.__voiceMlClientState || {};
      h = { ...h, paused: st.paused, speaking: h.speaking || st.playing };
      showRate(st.rate);
    }
    render(h);
    // Keep the last highlight through synthesis gaps (block is null between
    // batches); it is cleared when the overlay goes away. Right after a
    // seek, the seek response owns the highlight (stale polls rubber-band).
    // In client mode the position broadcasts drive the highlight instead.
    if (!clientMode && h.block && !(window.__voiceMlSeekHold > performance.now()))
      window.__voiceMlReader?.highlight(h.block);
    // First chunk takes a moment to synthesize, so require several
    // consecutive idle reads before concluding playback is done.
    idlePolls = !h.paused && !h.speaking && h.pending === 0 ? idlePolls + 1 : 0;
    if (idlePolls >= 6) remove();
  }

  function showRate(r) {
    if (r) rateEl.textContent = Math.round(r * 100) / 100 + "x";
  }

  let persistTimer = null;
  async function rateDelta(dir) {
    if (!clientMode) return; // local playback ignores rate
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
    if (clientMode) {
      const r = await chrome.runtime
        .sendMessage({ cmd: "player", action: "toggle" })
        .catch(() => null);
      if (r) render({ paused: r.paused, pending: 0 });
      return;
    }
    const r = await call(paused ? "/resume" : "/pause");
    if (r && !r.error) render({ paused: r.paused, pending: 0 });
  }

  async function stop() {
    if (clientMode)
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
