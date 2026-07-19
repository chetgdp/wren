const DEFAULTS = { base: "http://127.0.0.1:8765", token: "" };

const baseEl = document.getElementById("base");
const tokenEl = document.getElementById("token");
const savedEl = document.getElementById("saved");

chrome.storage.sync.get(DEFAULTS).then((cfg) => {
  baseEl.value = cfg.base;
  tokenEl.value = cfg.token;
});

document.getElementById("save").addEventListener("click", async () => {
  const base = (baseEl.value.trim() || DEFAULTS.base).replace(/\/+$/, "");
  await chrome.storage.sync.set({ base, token: tokenEl.value.trim() });
  baseEl.value = base;
  savedEl.style.visibility = "visible";
  setTimeout(() => (savedEl.style.visibility = "hidden"), 1500);
});
