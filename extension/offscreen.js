// Offscreen audio adapter (Chrome only): delegates to audio.js and
// relays callbacks as chrome.runtime messages to the background worker.

import * as audio from "./audio.js";

// PDF extraction lives here: the service worker can't hold the wasm
// instance across restarts, and this document already exists for audio.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.cmd !== "pdf-extract") return;
  import("./pdf.js")
    .then((m) => m.extractPdf(msg.url))
    .then(sendResponse)
    .catch((e) => sendResponse({ error: e.message }));
  return true;
});

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.cmd !== "player") return;
  if (msg.action === "start") {
    audio.start({
      base: msg.base,
      rate: msg.rate,
      flush: msg.flush,
      cursor: msg.cursor,
      onPosition: (pos) =>
        chrome.runtime
          .sendMessage({ cmd: "position", ...pos })
          .catch(() => {}),
      onCursor: (cur) =>
        chrome.runtime
          .sendMessage({ cmd: "cursor", ...cur })
          .catch(() => {}),
    });
    sendResponse({ ok: true });
  } else if (msg.action === "toggle") {
    audio.toggle().then(sendResponse);
    return true;
  } else if (msg.action === "rate") {
    sendResponse(
      audio.setRate({ value: msg.value, delta: msg.delta })
    );
  } else if (msg.action === "flush") {
    audio.flush();
    sendResponse({ ok: true });
  } else if (msg.action === "stop") {
    audio.stop();
    sendResponse({ ok: true });
  }
});
