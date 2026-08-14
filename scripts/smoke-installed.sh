#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/release-lib.sh"

if [ "$#" -ne 1 ]; then
    echo "usage: scripts/smoke-installed.sh /path/to/Wren.app" >&2
    exit 64
fi
APP=$1
wren_validate_bundle "$APP"
BIN="$APP/Contents/MacOS/wren"
FIXTURE="$SCRIPT_DIR/../daemon/Tests/Fixtures/installed_app_server.py"
[ -f "$FIXTURE" ] || wren_die "missing installed-app server fixture"
command -v python3 >/dev/null 2>&1 || wren_die "python3 is required"
command -v pgrep >/dev/null 2>&1 || wren_die "pgrep is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wren-installed-smoke.XXXXXX")
TOKEN="installed-smoke-token"
APP_PID=
SERVER_PID=
PORT_FILE=
EVENTS_FILE=
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
mkdir -p "$TMP/home"
export HOME="$TMP/home"
export CFFIXED_USER_HOME="$TMP/home"

start_fixture() {
    mode=$1
    token=$2
    name=$3
    PORT_FILE="$TMP/$name.port"
    EVENTS_FILE="$TMP/$name.events.jsonl"
    : > "$EVENTS_FILE"
    python3 "$FIXTURE" --port-file "$PORT_FILE" \
        --events-file "$EVENTS_FILE" --token "$token" --mode "$mode" \
        >"$TMP/$name.server.log" 2>&1 &
    SERVER_PID=$!
    attempt=0
    while [ ! -s "$PORT_FILE" ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 100 ] || \
            wren_die "$name fixture did not publish its port"
        kill -0 "$SERVER_PID" 2>/dev/null || \
            wren_die "$name fixture exited before publishing its port"
        sleep 0.05
    done
    PORT=$(cat "$PORT_FILE")
    export WREN_HOST="127.0.0.1:$PORT"
    export WREN_TOKEN="$token"
}

stop_fixture() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=
}

wait_event() {
    pattern=$1
    description=$2
    attempt=0
    while ! grep -q "$pattern" "$EVENTS_FILE" 2>/dev/null; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 200 ] || wren_die "$description"
        kill -0 "$APP_PID" 2>/dev/null || \
            wren_die "app exited while waiting for $description"
        sleep 0.05
    done
}

stabilize_failure() {
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        kill -0 "$APP_PID" 2>/dev/null || \
            wren_die "app exited while failure state stabilized"
        attempt=$((attempt + 1))
        sleep 0.05
    done
}

assert_no_managed_child() {
    children=$(pgrep -P "$APP_PID" 2>/dev/null || true)
    [ -z "$children" ] || \
        wren_die "connected/auth-failed app unexpectedly spawned child $children"
}

# A compatible process already occupying the dynamic endpoint must be adopted
# as connected, not replaced. The fixture's status remains reachable after the
# app quits, proving Wren did not terminate the connected owner.
start_fixture normal "$TOKEN" connected
export WREN_TOKEN="$TOKEN"
"$BIN" run >"$TMP/connected.app.log" 2>&1 &
APP_PID=$!
wait_event '"target":"/segment?' "app did not start local playback"
assert_no_managed_child
"$BIN" say "installed smoke" >/dev/null
attempt=0
while ! grep -q 'played=1' "$EVENTS_FILE" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 200 ] || \
        wren_die "installed player did not finish the fixture segment"
    kill -0 "$APP_PID" 2>/dev/null || \
        wren_die "app exited during segment playback"
    sleep 0.05
done
"$BIN" pause >/dev/null
"$BIN" resume >/dev/null
"$BIN" stop >/dev/null
kill -TERM "$APP_PID"
if ! wait "$APP_PID"; then
    wren_die "installed app did not quit cleanly after SIGTERM"
fi
APP_PID=
if ! "$BIN" status >"$TMP/connected.status" 2>&1; then
    wren_die "connected fixture did not survive app quit"
fi
grep -q 'lifecycle: ready' "$TMP/connected.status" || \
    wren_die "connected status was not ready after app quit"
stop_fixture
python3 "$FIXTURE" --events-file "$EVENTS_FILE" --assert-events

# An occupied endpoint with a wrong bearer token is an authorization failure,
# not adoption or a competing managed launch.
start_fixture normal "$TOKEN" auth
export WREN_TOKEN="wrong-installed-smoke-token"
"$BIN" run >"$TMP/auth.app.log" 2>&1 &
APP_PID=$!
wait_event '"method":"AUTH"' "app did not expose authorization failure"
stabilize_failure
assert_no_managed_child
kill -TERM "$APP_PID"
if ! wait "$APP_PID"; then
    wren_die "authorization-failed app did not quit cleanly"
fi
APP_PID=
stop_fixture

# A connected management mutation that cannot persist must fail visibly at the
# CLI boundary, rather than reporting a successful settings change.
start_fixture persistence-failure "$TOKEN" persistence
export WREN_TOKEN="$TOKEN"
if "$BIN" effects on >"$TMP/persistence.out" 2>&1; then
    wren_die "persistence failure unexpectedly reported success"
fi
grep -q 'settings_persist_failed' "$TMP/persistence.out" || \
    wren_die "persistence failure was not surfaced by the CLI"
grep -q '"method":"PATCH"' "$EVENTS_FILE" || \
    wren_die "persistence failure did not reach the management endpoint"
stop_fixture

# A post-Ready engine failure is represented as degraded/not-ready, no longer
# reports a usable active voice, preserves the failure code, and rejects speech.
start_fixture degraded "$TOKEN" degraded
export WREN_TOKEN="$TOKEN"
"$BIN" state --json >"$TMP/degraded.state"
"$BIN" status >"$TMP/degraded.status"
grep -q '"phase":"degraded"' "$TMP/degraded.state" || \
    wren_die "degraded engine state was not reported"
grep -q '"ready":false' "$TMP/degraded.state" || \
    wren_die "degraded engine did not report synthesis not ready"
grep -q 'voice:     -' "$TMP/degraded.status" || \
    wren_die "degraded engine still reported a usable active voice"
grep -q '"code":"engine_child_exited"' "$TMP/degraded.state" || \
    wren_die "degraded engine error code was not reported"
if "$BIN" say "engine failure" >"$TMP/degraded.say" 2>&1; then
    wren_die "degraded engine unexpectedly accepted synthesis"
fi
grep -q 'daemon returned 503' "$TMP/degraded.say" || \
    wren_die "degraded synthesis failure was not explicit"
stop_fixture
echo "installed app smoke passed: connected ownership, playback, auth conflict, persistence failure, degraded engine, quit"
