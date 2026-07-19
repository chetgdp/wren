"""Transcribe a reference clip into an accurate ref_text for voice cloning.

Uses mlx-whisper (Apple MLX / Metal) with whisper-large-v3-turbo.
Writes the transcript to a sibling .txt file next to the audio.

Usage:
    uv run python transcribe.py ../samples/ref.wav
    uv run python transcribe.py ../samples/ref.wav --language en
"""

import argparse
from pathlib import Path

import mlx_whisper

REPO = "mlx-community/whisper-large-v3-turbo"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", help="path to the reference audio clip")
    ap.add_argument("--language", default=None, help="ISO code, e.g. en (auto-detect if omitted)")
    args = ap.parse_args()

    audio = Path(args.audio)
    if not audio.exists():
        raise SystemExit(f"no such file: {audio}")

    result = mlx_whisper.transcribe(
        str(audio),
        path_or_hf_repo=REPO,
        language=args.language,
    )
    text = result["text"].strip()

    out = audio.with_suffix(".txt")
    out.write_text(text + "\n")
    print(f"detected language: {result.get('language')}")
    print(f"transcript: {text}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
