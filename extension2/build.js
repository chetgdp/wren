#!/usr/bin/env node
// Emits dist/chrome/ and dist/firefox/ from the same source.
const fs = require("fs");
const path = require("path");

const SRC = __dirname;
const DIST = path.join(SRC, "dist");

const SHARED = [
  "audio.js", "background.js", "content.js",
  "soundtouch.js", "popup.html", "popup.js",
  "options.html", "options.js",
];

const chromeManifest = JSON.parse(
  fs.readFileSync(path.join(SRC, "manifest.json"), "utf8")
);

const firefoxManifest = { ...chromeManifest };
delete firefoxManifest.permissions;
firefoxManifest.permissions = chromeManifest.permissions
  .filter(p => p !== "offscreen");
firefoxManifest.background = {
  scripts: ["background.js"], type: "module",
};
firefoxManifest.browser_specific_settings = {
  gecko: { id: "wren-speak@example.com" },
};

function copyFiles(files, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const f of files) {
    fs.copyFileSync(
      path.join(SRC, f), path.join(dest, f)
    );
  }
}

// Chrome
const chromeDir = path.join(DIST, "chrome");
copyFiles(SHARED, chromeDir);
copyFiles(["offscreen.js", "offscreen.html"], chromeDir);
fs.writeFileSync(
  path.join(chromeDir, "manifest.json"),
  JSON.stringify(chromeManifest, null, 2) + "\n"
);

// Firefox
const ffDir = path.join(DIST, "firefox");
copyFiles(SHARED, ffDir);
fs.writeFileSync(
  path.join(ffDir, "manifest.json"),
  JSON.stringify(firefoxManifest, null, 2) + "\n"
);

const cLoc = SHARED.length + 2;
const fLoc = SHARED.length;
console.log(
  `chrome: ${cLoc} files -> ${chromeDir}\n` +
  `firefox: ${fLoc} files -> ${ffDir}`
);
