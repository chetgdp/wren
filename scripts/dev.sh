#!/bin/sh
# Build, test, and install as a signed ~/Applications/Wren.app.
# bundle.sh swaps the bundle with renames rather than overwriting in place:
# overwriting a running binary gets it SIGKILLed by the kernel, and the
# inode change is also what triggers hot reload (watch.sh restarts wren
# when it sees the new binary land).
set -e

cd "$(dirname "$0")/.."

scripts/stamp-logo.sh
swift test
swift build -c release

scripts/bundle.sh
