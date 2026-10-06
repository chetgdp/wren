#!/bin/sh
# Assemble, sign, and install ~/Applications/Wren.app.
set -e
cd "$(dirname "$0")/.."
. scripts/release-lib.sh

SOURCE_ROOT="$(pwd)"
BIN="${1:-daemon/.build/release/wren}"
IDENTITY="${WREN_SIGN_IDENTITY:-otis_local_sign_test}"
APP="${WREN_INSTALL_APP:-$HOME/Applications/Wren.app}"
STAGE="${WREN_STAGE_APP:-daemon/.build/Wren.app}"
CLI_LINK="${WREN_CLI_LINK:-$HOME/.local/bin/wren}"
VERSION_LABEL=$(git describe --tags --always 2>/dev/null || echo 0.0.0)
VERSION_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)
VERSION_CORE=${VERSION_TAG#v}
SHORT_VERSION=$(printf '%s\n' "$VERSION_CORE" | awk -F. '
    NF >= 1 && NF <= 3 {
        for (i = 1; i <= NF; i++) if ($i !~ /^[0-9]+$/) exit
        printf "%d.%d.%d", $1, $2 + 0, $3 + 0
    }
')
[ -n "$SHORT_VERSION" ] || SHORT_VERSION=0.0.0
BUILD_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1)

if [ ! -f "$BIN" ]; then
    echo "missing binary $BIN (run swift build -c release first)" >&2
    exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/wren"
cp "$SOURCE_ROOT/assets/generated/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>wren</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.heavyetl.wren</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Wren</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

wren_validate_bundle "$STAGE"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$STAGE"
    codesign --verify --strict "$STAGE"
fi

wren_install_bundle "$STAGE" "$APP" "$CLI_LINK"
echo "installed $APP ($VERSION_LABEL)"
