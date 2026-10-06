#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/release-lib.sh"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <Wren.app>" >&2
    exit 1
fi
APP=$1
wren_validate_bundle "$APP"
BIN="$APP/Contents/MacOS/wren"
FIXTURE="$SCRIPT_DIR/../daemon/Tests/Fixtures/installed_app_server.py"
[ -f "$FIXTURE" ] || wren_die "missing installed-app server fixture"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wren-installed-smoke.XXXXXX")
APP_PID=
SERVER_PID=
PORT_FILE="$TMP/port"
EVENTS_FILE="$TMP/events.json"

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# Waits up to 10 s for a recorded request matching an ERE.
wait_event() {
    tries=0
    until grep -Eq "$1" "$EVENTS_FILE" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 200 ] || wren_die "timed out waiting for: $1"
        sleep 0.05
    done
}

python3 "$FIXTURE" --port-file "$PORT_FILE" --events-file "$EVENTS_FILE" &
SERVER_PID=$!
tries=0
until [ -s "$PORT_FILE" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || wren_die "fixture server did not start"
    sleep 0.05
done
export WREN_HOST="127.0.0.1:$(cat "$PORT_FILE")"

# The fixture enforces the contract: CLI speech with no active client
# must fail with 409 before any Mac has claimed.
if "$BIN" say "nobody home" 2>/dev/null; then
    wren_die "expected no_active_client before the app claimed"
fi

# The app claims on connect and polls its own channel.
"$BIN" run >"$TMP/app.log" 2>&1 &
APP_PID=$!
wait_event '"target":"/clients/active"'
wait_event '"target":"/segment\?channel=mac-'

"$BIN" say "smoke test voice" >/dev/null
"$BIN" yell "smoke test yell" >/dev/null
"$BIN" pause >/dev/null
"$BIN" resume >/dev/null
"$BIN" stop >/dev/null
"$BIN" stop --all >/dev/null
"$BIN" voices | grep -q fixture || wren_die "voices missing fixture"
"$BIN" voice use fixture >/dev/null
"$BIN" effects on >/dev/null
"$BIN" status | grep -q "voice:         fixture" \
    || wren_die "status did not show the activated voice"
"$BIN" state --json | grep -q '"effects":true' \
    || wren_die "state --json did not reflect effects"
"$BIN" doctor >/dev/null || wren_die "doctor reported a problem"

python3 - "$TMP/clip.wav" <<'EOF'
import sys
import wave

with wave.open(sys.argv[1], "wb") as clip:
    clip.setnchannels(1)
    clip.setsampwidth(2)
    clip.setframerate(24000)
    clip.writeframes(b"\0\0" * 2400)
EOF
"$BIN" voice add smoke --name "Smoke" --audio "$TMP/clip.wav" \
    --transcript "smoke clip" >/dev/null
"$BIN" voices | grep -q smoke || wren_die "added voice not listed"

echo "installed app smoke passed: claim on connect, segment poll, say," \
    "yell, pause, resume, stop, voices, voice use/add, effects, status," \
    "state, doctor"
