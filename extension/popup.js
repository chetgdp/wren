const DEFAULTS = { base: "http://127.0.0.1:8765", token: "" };

const greeting = document.getElementById("greeting");
const hostEl = document.getElementById("host");
const portEl = document.getElementById("port");

async function refresh() {
  const { base, token } = await chrome.storage.sync.get(DEFAULTS);
  const url = new URL(base);
  const port = url.port || (url.protocol === "https:" ? "443" : "80");
  hostEl.value = url.hostname;
  portEl.value = port;
  const where = `${url.hostname}:${port}`;
  greeting.textContent = "checking daemon…";
  try {
    const res = await fetch(base + "/health", {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    });
    if (!res.ok) throw new Error(res.status);
    greeting.textContent = `hello from ${where}`;
  } catch {
    greeting.textContent = `daemon not reachable at ${where}`;
  }
}

document.getElementById("addr").addEventListener("submit", async (e) => {
  e.preventDefault();
  const host = hostEl.value.trim();
  const port = portEl.value.trim();
  if (!host || !/^\d+$/.test(port)) return;
  const { base } = await chrome.storage.sync.get(DEFAULTS);
  const protocol = new URL(base).protocol; // keep http/https from current setting
  await chrome.storage.sync.set({ base: `${protocol}//${host}:${port}` });
  refresh();
});

document.getElementById("read").addEventListener("click", () => {
  chrome.runtime.sendMessage({ cmd: "read-tab" }).catch(() => {});
  window.close();
});

// PDF tabs have no content script, so the p/o keybinds don't exist there;
// this button is the pause control for PDF reads.
document.getElementById("pause").addEventListener("click", () => {
  chrome.runtime.sendMessage({ cmd: "player-toggle" }).catch(() => {});
});

document.getElementById("stop").addEventListener("click", () => {
  chrome.runtime.sendMessage({ path: "/stop" }).catch(() => {});
  chrome.runtime
    .sendMessage({ cmd: "player", action: "stop" })
    .catch(() => {});
  window.close();
});

refresh();
