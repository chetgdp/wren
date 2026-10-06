#!/usr/bin/env bash
# Run the wren synthesis server on this machine for clients on the tailnet.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
data="${WREN_DATA_DIR:-$HOME/Library/Application Support/voice-ml}"
engine="${WREN_ENGINE_ROOT:-$repo/../research/qwentts.cpp}"

# The qwentts.cpp build was moved after compiling, so its baked rpath is stale.
export DYLD_LIBRARY_PATH="$engine/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

cd "$repo"
exec uv run tts/serve.py \
  --host "${WREN_BIND:-0.0.0.0}" \
  --port "${WREN_PORT:-8765}" \
  --data-dir "$data" \
  --qwentts-bin "$engine/build/tts-server" \
  --qwentts-model "$data/models/qwen-talker-1.7b-base-Q8_0.gguf" \
  --qwentts-codec "$data/models/qwen-tokenizer-12hz-Q8_0.gguf" \
  --initial-voice c3po_god \
  --allow-origin https://pq9.time-phrygian.ts.net:42049 \
  --allow-origin http://pq9.time-phrygian.ts.net:42049 \
  "$@"
