#!/bin/sh
# Render assets/logo.svg into every asset the app bundle needs.
# Currently that is AppIcon.icns (all ten macOS iconset sizes). The icns is
# committed so bundle.sh works on machines without resvg; re-run this after
# swapping the logo.
set -e
cd "$(dirname "$0")/.."

SVG="assets/logo.svg"
OUT="assets/generated"
ICONSET="$OUT/AppIcon.iconset"

if ! command -v resvg >/dev/null 2>&1; then
    echo "resvg not found (nix: pkgs.resvg)" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# iconutil expects this exact naming: icon_<pt>x<pt>[@2x].png
for pt in 16 32 128 256 512; do
    resvg -w "$pt" -h "$pt" "$SVG" "$ICONSET/icon_${pt}x${pt}.png"
    resvg -w "$((pt * 2))" -h "$((pt * 2))" "$SVG" "$ICONSET/icon_${pt}x${pt}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
rm -rf "$ICONSET"

echo "wrote $OUT/AppIcon.icns"
