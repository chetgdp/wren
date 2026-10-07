#!/bin/sh
# Assemble and optionally sign/install Wren.app.
# Local use only (no notarization, no sparkle).
set -e
cd "$(dirname "$0")/.."
. scripts/release-lib.sh

SOURCE_ROOT="$(pwd)"
BIN=""
OUTPUT=""
IDENTITY="${WREN_SIGN_IDENTITY:-otis_local_sign_test}"
UNSIGNED=false
INSTALL=false

print_usage() {
    cat <<'EOF' >&2
usage: scripts/bundle.sh [options] [BIN] [OUTPUT]

Arguments:
  BIN       Path to compiled binary (default: daemon/.build/release/wren)
  OUTPUT    Path to target .app bundle

Options:
  --unsigned    Allow assembling bundle unsigned if signing identity is absent
  --install     Install atomically to ~/Applications and ~/.local/bin/wren
  --identity ID Codesigning identity (default: otis_local_sign_test)
  -h, --help    Show this message
EOF
    exit 2
}

POSITIONAL_ARGS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --unsigned)
            UNSIGNED=true
            shift
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        --identity)
            IDENTITY="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            if [ -z "$BIN" ]; then
                BIN="$1"
            elif [ -z "$OUTPUT" ]; then
                OUTPUT="$1"
            else
                echo "unexpected argument: $1" >&2
                print_usage
            fi
            shift
            ;;
    esac
done

[ -n "$BIN" ] || BIN="daemon/.build/release/wren"

BUNDLE_ID="com.heavyetl.wren"
BUNDLE_NAME="Wren"
DEFAULT_STAGE="daemon/.build/Wren.app"
DEFAULT_APP="$HOME/Applications/Wren.app"
DEFAULT_CLI_LINK="$HOME/.local/bin/wren"

STAGE="${OUTPUT:-$DEFAULT_STAGE}"
APP="${WREN_INSTALL_APP:-$DEFAULT_APP}"
CLI_LINK="${WREN_CLI_LINK:-$DEFAULT_CLI_LINK}"

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
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
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

wren_validate_bundle "$STAGE" "$BUNDLE_ID"

HAS_IDENTITY=false
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    HAS_IDENTITY=true
fi

if [ "$HAS_IDENTITY" = true ]; then
    codesign --force --sign "$IDENTITY" "$STAGE"
    codesign --verify --strict "$STAGE"
else
    if [ "$UNSIGNED" = true ]; then
        echo "warning: signing identity '$IDENTITY' not found; assembling unsigned (--unsigned)" >&2
    else
        echo "signing identity '$IDENTITY' not found in keychain" >&2
        echo "(set WREN_SIGN_IDENTITY to override, or pass --unsigned)" >&2
        exit 1
    fi
fi

if [ "$INSTALL" = true ]; then
    wren_install_bundle "$STAGE" "$APP" "$CLI_LINK"
    echo "installed $APP ($VERSION_LABEL)"
else
    echo "assembled $STAGE ($VERSION_LABEL, id: $BUNDLE_ID)"
fi
