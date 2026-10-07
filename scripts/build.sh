#!/bin/sh
# Build, test, and install as a signed ~/Applications/Wren.app
# (com.heavyetl.wren) and symlink ~/.local/bin/wren.
# bundle.sh swaps the bundle with renames rather than overwriting in place:
# overwriting a running binary gets it SIGKILLed by the kernel, and the
# inode change is also what triggers hot reload (watch.sh restarts wren
# when it sees the new binary land).
set -e

SKIP_TESTS=false
UNSIGNED=false
IDENTITY="${WREN_SIGN_IDENTITY:-otis_local_sign_test}"

print_usage() {
    cat <<'EOF' >&2
usage: scripts/build.sh [options]

Options:
  --skip-tests, -T  Skip running swift test
  --unsigned        Allow assembling bundle unsigned if signing identity is absent
  --identity ID     Codesigning identity (default: otis_local_sign_test)
  -h, --help        Show this help
EOF
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-tests|-T)
            SKIP_TESTS=true
            shift
            ;;
        --unsigned)
            UNSIGNED=true
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
            echo "unexpected argument: $1" >&2
            print_usage
            ;;
    esac
done

cd "$(dirname "$0")/.."

# Generate logo asset before building if needed
if [ -f "scripts/stamp-logo.sh" ]; then
    scripts/stamp-logo.sh
fi

if [ "$SKIP_TESTS" = false ]; then
    echo "test"
    swift test --package-path daemon
fi

echo "build (release)"
swift build --package-path daemon -c release

echo "bundle"
BUNDLE_FLAGS="--install --identity $IDENTITY"
if [ "$UNSIGNED" = true ]; then
    BUNDLE_FLAGS="$BUNDLE_FLAGS --unsigned"
fi

# shellcheck disable=SC2086
scripts/bundle.sh $BUNDLE_FLAGS

# Seed server_script default if not already configured
if ! defaults read com.heavyetl.wren server_script >/dev/null 2>&1; then
    SERVE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/serve.sh"
    defaults write com.heavyetl.wren server_script "$SERVE_SCRIPT"
fi
