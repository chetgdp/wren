import * as audio from "./audio.js";

chrome.runtime.onMessage.addListener((msg, _sender, respond) => {
  if (msg.cmd !== "player") return;
  const pos = p =>
    chrome.runtime.sendMessage({cmd: "position", ...p})
      .catch(() => {});
  const cur = c =>
    chrome.runtime.sendMessage({cmd: "cursor", ...c})
      .catch(() => {});
  switch (msg.action) {
    case "start":
      audio.start({
        base: msg.base, token: msg.token,
        rate: msg.rate, flush: msg.flush,
        cursor: msg.cursor,
        onPosition: pos, onCursor: cur,
      });
      respond({ok: true});
      break;
    case "toggle":
      audio.toggle().then(respond);
      return true;
    case "rate":
      respond(audio.setRate({
        value: msg.value, delta: msg.delta,
      }));
      break;
    case "flush":
      audio.flush();
      respond({ok: true});
      break;
    case "stop":
      audio.stop();
      respond({ok: true});
      break;
  }
});
