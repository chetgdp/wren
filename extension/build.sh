#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

rm -rf dist/chrome dist/firefox
mkdir -p dist/chrome dist/firefox

# Copy all extension files to both targets
for dir in dist/chrome dist/firefox; do
  cp -R *.js *.html manifest.json vendor "$dir/"
done
# Copy non-standard extensions if present
for f in todo; do
  [ -f "$f" ] && cp "$f" dist/chrome/ && cp "$f" dist/firefox/ || true
done

# Chrome manifest is unchanged
# Firefox: transform manifest
jq '
  .background = {"scripts": ["background.js"], "type": "module"}
  | .permissions = [.permissions[] | select(. != "offscreen")]
  | .browser_specific_settings = {"gecko": {"id": "voice-ml-speak@example.com"}}
' dist/firefox/manifest.json > dist/firefox/manifest.json.tmp
mv dist/firefox/manifest.json.tmp dist/firefox/manifest.json

# Remove Chrome-only files from Firefox
rm -f dist/firefox/offscreen.js dist/firefox/offscreen.html
rm -f dist/firefox/pdf.js dist/firefox/pdfviewer.js dist/firefox/pdfviewer.html
rm -rf dist/firefox/vendor/pdfjs dist/firefox/vendor/pdf-inspector

echo "Built dist/chrome/ and dist/firefox/"
