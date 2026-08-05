"""Qwen3-TTS-12Hz-1.7B-Base voice-clone CLI.

Differs from the official NVIDIA sample: device auto-resolves cuda > mps >
cpu, attn_implementation="sdpa" (works everywhere; flash-attn is a separate
install), and the MPS CPU fallback env var is set so any unsupported op runs
on CPU instead of erroring.

Example:
    uv run --project tts python tts/clone.py \\
        --ref-audio samples/ref.wav --text "hello there" --output out.wav
"""

import argparse
import os
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

MODEL_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"


def parse_args():
    p = argparse.ArgumentParser(
        description="Voice-clone text-to-speech with Qwen3-TTS.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("-r", "--ref-audio", required=True, type=Path,
                   help="reference voice clip (~3s wav)")
    p.add_argument("--ref-text", type=Path,
                   help="transcript of --ref-audio (default: its sibling .txt)")
    text = p.add_mutually_exclusive_group(required=True)
    text.add_argument("-t", "--text", help="text to speak, inline")
    text.add_argument("-f", "--text-file", type=Path,
                      help="file containing the text to speak")
    p.add_argument("-o", "--output", type=Path,
                   default=Path("output_voice_clone.wav"),
                   help="output wav path")
    p.add_argument("-l", "--language", default="English",
                   help="language of the text")
    return p.parse_args()


def _read_text(args):
    """The text to synthesize, from --text (inline) or --text-file (path)."""
    if args.text is not None:
        return args.text.strip()
    if not args.text_file.exists():
        raise SystemExit(f"text-file not found: {args.text_file}")
    return args.text_file.read_text().strip()


def _read_ref_text(args):
    """Reference transcript; defaults to the ref-audio's sibling .txt."""
    path = args.ref_text or args.ref_audio.with_suffix(".txt")
    if not path.exists():
        raise SystemExit(
            f"ref-text not found: {path}\n"
            f"transcribe it with:\n"
            f"  uv run --project transcribe python transcribe/transcribe.py "
            f"{args.ref_audio} --language en"
        )
    return path.read_text().strip()


def main():
    args = parse_args()

    # Validate inputs before the slow model load so errors are instant.
    if not args.ref_audio.exists():
        raise SystemExit(f"ref-audio not found: {args.ref_audio}")
    ref_text = _read_ref_text(args)
    out_text = _read_text(args)

    import torch
    import soundfile as sf
    from qwen_tts import Qwen3TTSModel

    from progress_bar import attach_progress_bar, estimate_frames

    from serve import resolve_device
    device = resolve_device()
    print(f"device: {device}")
    model = Qwen3TTSModel.from_pretrained(
        MODEL_ID,
        device_map=device,
        dtype=torch.float32 if device == "cpu" else torch.bfloat16,
        attn_implementation="sdpa",
    )
    attach_progress_bar(model)

    print(f"ref_audio: {args.ref_audio}")
    print(f"ref_text:  {ref_text}")
    print(f"out_text:  {out_text}")

    est = estimate_frames(out_text)
    print(f"estimated ~{est} frames (~{est // 12}s audio)")

    wavs, sr = model.generate_voice_clone(
        text=out_text,
        language=args.language,
        ref_audio=str(args.ref_audio),
        ref_text=ref_text,
    )

    sf.write(str(args.output), wavs[0], sr)
    print(f"wrote {args.output} (sample rate {sr})")


if __name__ == "__main__":
    main()
