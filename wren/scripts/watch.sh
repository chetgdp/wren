#!/bin/sh
# Run wren and restart it whenever a new binary lands at ~/.local/bin/wren.
# That path is a symlink into ~/Applications/Wren.app; stat follows it, so
# the bundle swap done by scripts/bundle.sh changes the observed inode.
# ^C stops both wren and this script.
BIN="$HOME/.local/bin/wren"

while :; do
    inode=$(stat -f %i "$BIN")
    "$BIN" "$@" &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        if [ "$(stat -f %i "$BIN" 2>/dev/null)" != "$inode" ]; then
            echo "↻ binary updated, restarting wren"
            kill -INT "$pid"
            break
        fi
    done
    wait "$pid" 2>/dev/null

    # wren exited without a binary change: user quit or crash, stop looping
    [ "$(stat -f %i "$BIN" 2>/dev/null)" = "$inode" ] && exit
done
