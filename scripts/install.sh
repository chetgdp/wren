#!/usr/bin/env bash
# Install the latest complete Wren.app release and link its signed executable.
#   curl -fsSL https://digimata.github.io/wren/install.sh | bash

set -euo pipefail

REPO="digimata/wren"
ASSET="wren-macos-arm64.tar.gz"
APP="${WREN_INSTALL_APP:-$HOME/Applications/Wren.app}"
CLI_LINK="${WREN_CLI_LINK:-$HOME/.local/bin/wren}"

red() { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
dim() { printf "\033[2m%s\033[0m\n" "$*"; }
fail() { red "$*"; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "wren is macOS-only"
[ "$(uname -m)" = "arm64" ] || fail "wren requires Apple Silicon"
for command_name in tar /usr/libexec/PlistBuddy; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "missing dependency: $command_name"
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wren-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/$ASSET"
TAG="local"
if [ -n "${WREN_RELEASE_ARCHIVE:-}" ]; then
    [ -f "$WREN_RELEASE_ARCHIVE" ] || \
        fail "release archive not found: $WREN_RELEASE_ARCHIVE"
    cp "$WREN_RELEASE_ARCHIVE" "$ARCHIVE"
else
    command -v curl >/dev/null 2>&1 || fail "missing dependency: curl"
    dim "resolving latest release"
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p' | sed -n '1p')
    [ -n "$TAG" ] || fail "could not determine the latest release tag"
    URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
    dim "downloading $ASSET"
    curl -fsSL "$URL" -o "$ARCHIVE"
fi

dim "extracting Wren.app"
tar -xzf "$ARCHIVE" -C "$TMP"
STAGE="$TMP/Wren.app"
[ -d "$STAGE" ] || fail "archive did not contain Wren.app at its root"
for relative in \
    Contents/Info.plist \
    Contents/MacOS/wren \
    Contents/Resources/uv \
    Contents/Resources/server/serve.py \
    Contents/Resources/server/storage.py \
    Contents/Resources/server/fx.py \
    Contents/Resources/server/requirements.txt \
    Contents/Resources/engine/tts-server \
    Contents/Resources/engine/libggml.0.dylib \
    Contents/Resources/engine/libggml-base.0.dylib \
    Contents/Resources/engine/libggml-blas.0.dylib \
    Contents/Resources/engine/libggml-cpu.0.dylib \
    Contents/Resources/engine/libggml-metal.0.dylib \
    Contents/Resources/voices/c3po_god.wav \
    Contents/Resources/voices/c3po_god.txt \
    Contents/Resources/AppIcon.icns
do
    [ -f "$STAGE/$relative" ] || fail "release is missing $relative"
done
[ -x "$STAGE/Contents/MacOS/wren" ] || fail "Wren executable is not executable"
[ -x "$STAGE/Contents/Resources/uv" ] || fail "bundled uv is not executable"
[ -x "$STAGE/Contents/Resources/engine/tts-server" ] || \
    fail "bundled tts-server is not executable"
REQUIREMENT_COUNT=$(wc -l < \
    "$STAGE/Contents/Resources/server/requirements.txt")
[ "$REQUIREMENT_COUNT" -eq 3 ] || \
    fail "release requirements must contain exactly three pins"
BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$STAGE/Contents/Info.plist")
[ "$BUNDLE_IDENTIFIER" = "com.digimata.wren" ] || \
    fail "release has the wrong bundle identifier"
BUNDLE_EXECUTABLE=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' "$STAGE/Contents/Info.plist")
[ "$BUNDLE_EXECUTABLE" = "wren" ] || \
    fail "release names the wrong executable"
PACKAGE_TYPE=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundlePackageType' "$STAGE/Contents/Info.plist")
[ "$PACKAGE_TYPE" = "APPL" ] || fail "release is not an app bundle"
ICON_NAME=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIconFile' "$STAGE/Contents/Info.plist")
[ "$ICON_NAME" = "AppIcon" ] || fail "release names the wrong app icon"


SHORT_VERSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$STAGE/Contents/Info.plist")
BUILD_VERSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$STAGE/Contents/Info.plist")
IFS=. read -r major minor patch extra <<< "$SHORT_VERSION"
[ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && \
    [ -z "${extra:-}" ] || fail "release has an invalid short version"
for component in "$major" "$minor" "$patch" "$BUILD_VERSION"; do
    [[ "$component" =~ ^[0-9]+$ ]] || fail "release has invalid version fields"
done
[ "$BUILD_VERSION" -gt 0 ] || fail "release build version must be positive"

if [ "${WREN_SKIP_SIGNATURE_CHECK:-0}" != 1 ]; then
    codesign --verify --deep --strict "$STAGE" || \
        fail "release app signature is invalid"
fi
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true

mkdir -p "$(dirname "$APP")" "$(dirname "$CLI_LINK")"
OLD="$APP.old"
rm -rf "$OLD"
if [ -d "$APP" ]; then
    mv "$APP" "$OLD"
fi
if ! mv "$STAGE" "$APP"; then
    [ ! -d "$OLD" ] || mv "$OLD" "$APP"
    fail "could not install $APP"
fi
if ! ln -sfn "$APP/Contents/MacOS/wren" "$CLI_LINK"; then
    rm -rf "$APP"
    [ ! -d "$OLD" ] || mv "$OLD" "$APP"
    fail "could not update $CLI_LINK"
fi
rm -rf "$OLD"

green "Wren $SHORT_VERSION ($BUILD_VERSION) installed at $APP"
echo "CLI: $CLI_LINK -> $APP/Contents/MacOS/wren"
echo "Launch Wren.app from Spotlight; CLI subcommands use the same executable."
