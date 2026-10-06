const D = {base: "http://127.0.0.1:8765"};
const $ = (id) => document.getElementById(id);
chrome.storage.sync.get(D).then((c) => {
  $("base").value = c.base;
});
$("save").onclick = async () => {
  const base = ($("base").value.trim() || D.base)
    .replace(/\/+$/, "");
  await chrome.storage.sync.set({base});
  $("base").value = base;
  $("saved").style.visibility = "visible";
  setTimeout(
    () => $("saved").style.visibility = "hidden", 1500
  );
};
