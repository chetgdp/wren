#!/bin/sh
# Fetch the 4-bit MLX TTS model(s) into models/ (git-ignored; see .gitignore).
# mlx-community hosts the same 4-bit conversions as the local ones serve.py's
# DEFAULT_MODEL points at, with identical file layouts.
#
# Usage:
#   ./fetch-models.sh                                # default: 1.7B (serve.py default)
#   ./fetch-models.sh Qwen3-TTS-12Hz-0.6B-Base-4bit  # or name other mlx-community repos
set -eu

cd "$(dirname "$0")"

BASE=https://huggingface.co/mlx-community
FILES="config.json
generation_config.json
merges.txt
model.safetensors
model.safetensors.index.json
preprocessor_config.json
tokenizer_config.json
vocab.json
speech_tokenizer/config.json
speech_tokenizer/configuration.json
speech_tokenizer/model.safetensors
speech_tokenizer/preprocessor_config.json"

[ $# -gt 0 ] && repos="$*" || repos="Qwen3-TTS-12Hz-1.7B-Base-4bit"

for repo in $repos; do
  for f in $FILES; do
    out="models/$repo/$f"
    if [ -f "$out" ]; then
      echo "have    $out"
      continue
    fi
    mkdir -p "$(dirname "$out")"
    echo "fetching $repo/$f"
    # .part + mv so an interrupted download never leaves a truncated file
    # that a rerun would skip over
    curl -L --fail --progress-bar -o "$out.part" "$BASE/$repo/resolve/main/$f"
    mv "$out.part" "$out"
  done
done
echo "done: $repos"
