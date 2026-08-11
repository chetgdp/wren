#!/bin/sh
# Assemble, sign, and install ~/Applications/Wren.app.
#
# Why a bundle: Spotlight only launches .app bundles, and signing every
# build with the same local cert keeps the app's identity stable across
# rebuilds instead of resetting each time the binary changes.
#
# The install is a two-rename swap (old app aside, staged app in), so the
# inner binary's inode changes atomically and watch.sh hot reload still
# fires. ~/.local/bin/wren becomes a symlink into the bundle so the CLI
# and the Spotlight app are one signed executable.
set -e
cd "$(dirname "$0")/.."

BIN="${1:-daemon/.build/release/wren}"
# Reuses otis's local cert: TCC keys grants to identity + bundle id, so
# two apps sharing one signing identity stay independently permissioned.
IDENTITY="${WREN_SIGN_IDENTITY:-otis_local_sign_test}"
APP="$HOME/Applications/Wren.app"
STAGE="daemon/.build/Wren.app"
VERSION=$(git describe --tags --always 2>/dev/null || echo 0.0.0)

if [ ! -f "$BIN" ]; then
    echo "missing $BIN (run: swift build -c release)" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "signing identity '$IDENTITY' not found in keychain" >&2
    echo "(set WREN_SIGN_IDENTITY to override)" >&2
    exit 1
fi

REPO="$(cd .. && pwd)"
ENGINE_BUILD="$REPO/qwentts.cpp/build"
UV_BIN="${WREN_UV:-$(command -v uv || true)}"

# Version pin for a python package, read from the repo's uv.lock so the
# bundled env matches what the repo runs today.
pin() {
    awk -v name="$1" '
        $0 == "name = \"" name "\"" { found = 1; next }
        found && /^version = / { gsub(/"/, "", $3); print name "==" $3; exit }
    ' "$REPO/uv.lock"
}

for f in "$ENGINE_BUILD/tts-server" "$UV_BIN" \
         "$REPO/samples/c3po_god.wav" "$REPO/samples/c3po_god.txt"; do
    if [ ! -f "$f" ]; then
        echo "missing $f (engine build, uv, and the default voice are bundled)" >&2
        exit 1
    fi
done

# stage
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/wren"

# Self-contained server: serve.py + its local import, pinned deps for the
# first-run env, the qwentts engine, the default voice, and uv itself.
# Models (2.2 GB) are NOT here - the app downloads them into Application
# Support on first run.
RES="$STAGE/Contents/Resources"
mkdir -p "$RES/server" "$RES/engine" "$RES/voices"
cp "$REPO/tts/serve.py" "$REPO/tts/fx.py" "$RES/server/"
{ pin soundfile; pin pedalboard; pin numpy; } > "$RES/server/requirements.txt"
if [ "$(wc -l < "$RES/server/requirements.txt")" -ne 3 ]; then
    echo "failed to pin server deps from uv.lock" >&2
    exit 1
fi
cp "$REPO/samples/c3po_god.wav" "$REPO/samples/c3po_god.txt" "$RES/voices/"
cp "$UV_BIN" "$RES/uv"

# Engine: tts-server finds libggml via @rpath, and the build stamps an
# absolute LC_RPATH to the build tree. Rewrite it to @loader_path (all
# engine files sit flat in one directory), then re-sign: editing load
# commands invalidates the signature and arm64 refuses unsigned code.
cp "$ENGINE_BUILD/tts-server" "$RES/engine/"
for lib in libggml libggml-base libggml-blas libggml-cpu libggml-metal; do
    cp -L "$ENGINE_BUILD/$lib.0.dylib" "$RES/engine/$lib.0.dylib"
done
for bin in "$RES/engine/"*; do
    otool -l "$bin" | awk '/LC_RPATH/{grab=2; next} grab && /path /{print $2; grab=0}' |
    while read -r rpath; do
        install_name_tool -delete_rpath "$rpath" "$bin" 2>/dev/null || true
    done
    install_name_tool -add_rpath "@loader_path" "$bin"
    codesign --force --sign "$IDENTITY" "$bin"
done
# No logo yet: bundle without an icon rather than fail the install.
ICON_KEYS=""
if [ -f assets/generated/AppIcon.icns ]; then
    cp assets/generated/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
    ICON_KEYS="	<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
else
    echo "warning: assets/generated/AppIcon.icns missing; bundling without an icon" >&2
fi
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>wren</string>
$ICON_KEYS
	<key>CFBundleIdentifier</key>
	<string>com.digimata.wren</string>
	<key>CFBundleName</key>
	<string>Wren</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

codesign --force --sign "$IDENTITY" "$STAGE"
codesign --verify --strict "$STAGE"

# install: swap the whole bundle so the running binary is never mutated
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$APP.old"
if [ -d "$APP" ]; then
    mv "$APP" "$APP.old"
fi
mv "$STAGE" "$APP"
rm -rf "$APP.old"

ln -sfn "$APP/Contents/MacOS/wren" "$HOME/.local/bin/wren"

echo "installed $APP ($VERSION, signed: $IDENTITY)"
echo "cli: ~/.local/bin/wren -> bundle binary (running wren will hot reload)"
