const DEFAULTS = { base: "http://127.0.0.1:8765" };

const baseEl = document.getElementById("base");
const savedEl = document.getElementById("saved");

chrome.storage.sync.get(DEFAULTS).then((cfg) => {
  baseEl.value = cfg.base;
});

document.getElementById("save").addEventListener("click", async () => {
  const base = (baseEl.value.trim() || DEFAULTS.base).replace(/\/+$/, "");
  await chrome.storage.sync.set({ base });
  baseEl.value = base;
  savedEl.style.visibility = "visible";
  setTimeout(() => (savedEl.style.visibility = "hidden"), 1500);
});
