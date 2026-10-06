const D = {base: "http://127.0.0.1:8765"};
const $ = (id) => document.getElementById(id);
async function refresh() {
  const {base} = await chrome.storage.sync.get(D);
  const u = new URL(base);
  const port = u.port ||
    (u.protocol === "https:" ? "443" : "80");
  $("host").value = u.hostname;
  $("port").value = port;
  $("status").textContent = "checking daemon...";
  try {
    const r = await fetch(base + "/health");
    if (!r.ok) throw 0;
    $("status").textContent =
      "connected to " + u.hostname + ":" + port;
  } catch {
    $("status").textContent =
      "daemon not reachable at " + u.hostname + ":" + port;
  }
}
$("addr").onsubmit = async (e) => {
  e.preventDefault();
  const h = $("host").value.trim();
  const p = $("port").value.trim();
  if (!h || !/^\d+$/.test(p)) return;
  const {base} = await chrome.storage.sync.get(D);
  const proto = new URL(base).protocol;
  await chrome.storage.sync.set(
    {base: proto + "//" + h + ":" + p}
  );
  refresh();
};
$("read").onclick = () => {
  chrome.runtime.sendMessage({cmd: "read-tab"});
  window.close();
};
$("pause").onclick = () => {
  chrome.runtime.sendMessage({cmd: "player-toggle"});
};
$("stop").onclick = () => {
  chrome.runtime.sendMessage({path: "/stop"});
  chrome.runtime.sendMessage(
    {cmd: "player", action: "stop"}
  );
  window.close();
};
refresh();
