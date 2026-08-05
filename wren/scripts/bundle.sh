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

BIN="${1:-.build/release/wren}"
# Reuses otis's local cert: TCC keys grants to identity + bundle id, so
# two apps sharing one signing identity stay independently permissioned.
IDENTITY="${WREN_SIGN_IDENTITY:-otis_local_sign_test}"
APP="$HOME/Applications/Wren.app"
STAGE=".build/Wren.app"
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

# stage
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/wren"
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
