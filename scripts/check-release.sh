#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/release-lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wren-release.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

(
    unset WREN_ENGINE_ROOT
    default_engine=$(wren_engine_root "$TMP/source/wren")
    [ "$default_engine" = \
        "$TMP/source/wren/../research/qwentts.cpp" ] || \
        wren_die "default engine root does not match the workspace layout"
)
(
    WREN_ENGINE_ROOT="$TMP/override/qwentts.cpp"
    export WREN_ENGINE_ROOT
    override_engine=$(wren_engine_root "$TMP/source/wren")
    [ "$override_engine" = "$WREN_ENGINE_ROOT" ] || \
        wren_die "WREN_ENGINE_ROOT override was ignored"
)

make_bundle_fixture() {
    bundle=$1
    version=$2
    resources="$bundle/Contents/Resources"
    mkdir -p "$bundle/Contents/MacOS" "$resources/server" \
        "$resources/engine" "$resources/voices"
    cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>wren</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>com.digimata.wren</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
EOF
    printf '#!/bin/sh\nexit 0\n' > "$bundle/Contents/MacOS/wren"
    printf '#!/bin/sh\nexit 0\n' > "$resources/uv"
    printf '#!/bin/sh\nexit 0\n' > "$resources/engine/tts-server"
    chmod +x "$bundle/Contents/MacOS/wren" "$resources/uv" \
        "$resources/engine/tts-server"
    for module in serve.py storage.py fx.py; do
        printf '# release fixture\n' > "$resources/server/$module"
    done
    printf 'soundfile==1\npedalboard==1\nnumpy==1\n' > \
        "$resources/server/requirements.txt"
    for library in libggml libggml-base libggml-blas libggml-cpu \
        libggml-metal; do
        printf 'fixture\n' > "$resources/engine/$library.0.dylib"
    done
    printf 'RIFF fixture\n' > "$resources/voices/c3po_god.wav"
    printf 'fixture voice\n' > "$resources/voices/c3po_god.txt"
    printf 'fixture icon\n' > "$resources/AppIcon.icns"
}

assert_same() {
    expected=$1
    path=$2
    actual=$(cksum "$path")
    [ "$actual" = "$expected" ] || \
        wren_die "install changed migration source $path"
}

APP="$TMP/Applications/Wren.app"
CLI="$TMP/bin/wren"
SUPPORT="$TMP/Application Support/voice-ml"

# A clean bundle install must not eagerly create or mutate Application Support.
CLEAN="$TMP/clean/Wren.app"
make_bundle_fixture "$CLEAN" 1
wren_install_bundle "$CLEAN" "$APP" "$CLI"
wren_validate_bundle "$APP"
[ ! -e "$SUPPORT" ] || wren_die "clean install created Application Support"
[ "$(readlink "$CLI")" = "$APP/Contents/MacOS/wren" ] || \
    wren_die "clean install created the wrong CLI link"

# An update must leave every pre-Ready migration source byte-for-byte intact.
mkdir -p "$SUPPORT/voices"
printf '{"voice":"c3po_god"}\n' > "$SUPPORT/config.json"
printf 'legacy wav\n' > "$SUPPORT/voices/c3po_god.wav"
printf 'legacy transcript\n' > "$SUPPORT/voices/c3po_god.txt"
config_sum=$(cksum "$SUPPORT/config.json")
wav_sum=$(cksum "$SUPPORT/voices/c3po_god.wav")
text_sum=$(cksum "$SUPPORT/voices/c3po_god.txt")
UPGRADE="$TMP/upgrade/Wren.app"
make_bundle_fixture "$UPGRADE" 2
wren_install_bundle "$UPGRADE" "$APP" "$CLI"
wren_validate_bundle "$APP"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist")
[ "$version" = 2 ] || wren_die "upgrade did not install version 2"
[ ! -e "$APP.old" ] || wren_die "upgrade left a stale rollback bundle"
assert_same "$config_sum" "$SUPPORT/config.json"
assert_same "$wav_sum" "$SUPPORT/voices/c3po_god.wav"
assert_same "$text_sum" "$SUPPORT/voices/c3po_god.txt"

# Once Ready cleanup retires the flat sources, a later bundle update must not
# recreate them or alter the committed profile directory.
mkdir -p "$SUPPORT/voices/c3po_god"
printf '{"schema_version":2,"id":"c3po_god"}\n' > \
    "$SUPPORT/voices/c3po_god/profile.json"
profile_sum=$(cksum "$SUPPORT/voices/c3po_god/profile.json")
rm "$SUPPORT/config.json" "$SUPPORT/voices/c3po_god.wav" \
    "$SUPPORT/voices/c3po_god.txt"
POST_READY="$TMP/post-ready/Wren.app"
make_bundle_fixture "$POST_READY" 3
wren_install_bundle "$POST_READY" "$APP" "$CLI"
assert_same "$profile_sum" "$SUPPORT/voices/c3po_god/profile.json"
[ ! -e "$SUPPORT/config.json" ] || wren_die "update recreated legacy config"
[ ! -e "$SUPPORT/voices/c3po_god.wav" ] || \
    wren_die "update recreated retired seed audio"
[ ! -e "$SUPPORT/voices/c3po_god.txt" ] || \
    wren_die "update recreated retired seed transcript"

# Validation rejects an incomplete stage before it can replace the live app.
BROKEN="$TMP/broken/Wren.app"
make_bundle_fixture "$BROKEN" 4
rm "$BROKEN/Contents/Resources/server/storage.py"
if wren_install_bundle "$BROKEN" "$APP" "$CLI" 2>/dev/null; then
    wren_die "invalid update unexpectedly installed"
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist")
[ "$version" = 3 ] || wren_die "failed update replaced the working bundle"

# The public installer accepts a local archive for deterministic clean/update
# coverage while production uses the same archive layout from GitHub Releases.
INSTALL_HOME="$TMP/installer-home"
INSTALL_APP="$TMP/installer/Wren.app"
INSTALL_CLI="$TMP/installer-bin/wren"
INSTALL_SUPPORT="$INSTALL_HOME/Library/Application Support/voice-ml"
mkdir -p "$INSTALL_SUPPORT/voices"
printf 'keep config\n' > "$INSTALL_SUPPORT/config.json"
printf 'keep voice\n' > "$INSTALL_SUPPORT/voices/keep.wav"
install_config_sum=$(cksum "$INSTALL_SUPPORT/config.json")
install_voice_sum=$(cksum "$INSTALL_SUPPORT/voices/keep.wav")
for install_version in 5 6; do
    ARCHIVE_ROOT="$TMP/archive-$install_version"
    ARCHIVE="$TMP/wren-$install_version.tar.gz"
    make_bundle_fixture "$ARCHIVE_ROOT/Wren.app" "$install_version"
    tar -czf "$ARCHIVE" -C "$ARCHIVE_ROOT" Wren.app
    HOME="$INSTALL_HOME" WREN_RELEASE_ARCHIVE="$ARCHIVE" \
        WREN_INSTALL_APP="$INSTALL_APP" WREN_CLI_LINK="$INSTALL_CLI" \
        WREN_SKIP_SIGNATURE_CHECK=1 "$SCRIPT_DIR/install.sh" >/dev/null
    assert_same "$install_config_sum" "$INSTALL_SUPPORT/config.json"
    assert_same "$install_voice_sum" "$INSTALL_SUPPORT/voices/keep.wav"
done
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$INSTALL_APP/Contents/Info.plist")
[ "$version" = 6 ] || wren_die "public installer update did not install v6"
[ "$(readlink "$INSTALL_CLI")" = \
    "$INSTALL_APP/Contents/MacOS/wren" ] || \
    wren_die "public installer linked a different executable"

if [ "$#" -gt 0 ]; then
    wren_validate_bundle "$1"
fi

echo "release checks passed: clean, upgrade, post-Ready, invalid update"
