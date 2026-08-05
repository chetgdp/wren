"""Benchmark voice-clone TTS models: wall time vs audio produced (RTF).

RTF > 1.0 means faster than realtime (no gaps during streamed playback).
Models run in succession in one invocation; a model that fails to load is
reported and skipped. Default set: the MLX and PyTorch 0.6B candidates plus
the original 1.7B baseline.

Example:
    uv run tts/bench.py -r samples/ref.wav
    uv run tts/bench.py -r samples/ref.wav \
        -m mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16
"""

import argparse
import gc
import tempfile
import time
import traceback
from pathlib import Path

from serve import estimate_frames, load_synth, resolve_ref_text

DEFAULT_MODELS = [
    "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",
    "aufklarer/Qwen3-TTS-12Hz-0.6B-Base-MLX-4bit",
    #"Qwen/Qwen3-TTS-12Hz-0.6B-Base",
    #"Qwen/Qwen3-TTS-12Hz-1.7B-Base",
]

BENCH_TEXT = (
    "The daemon loads the model once and keeps it resident, so each request "
    "only pays for synthesis. Chunked playback starts after the first piece."
)


def free_memory():
    gc.collect()
    try:
        import mlx.core as mx
        mx.clear_cache()
    except Exception:
        pass
    try:
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:
        pass


def bench_model(model_id, backend, ref_audio, ref_text, language, text, runs):
    """Returns (load_seconds, best_rtf) for the summary."""
    import soundfile as sf

    t0 = time.monotonic()
    synth = load_synth(backend, model_id, ref_audio, ref_text, language)
    load_s = time.monotonic() - t0
    print(f"load: {load_s:.1f}s")

    best_rtf = 0.0
    with tempfile.TemporaryDirectory() as tmp:
        counter = [0]

        def make_path():
            counter[0] += 1
            return str(Path(tmp) / f"bench-{counter[0]}.wav")

        def timed_run():
            """(wall, time-to-first-audio, audio seconds) for one synth."""
            t0 = time.monotonic()
            first = None
            audio_s = 0.0
            for path in synth(text, make_path):
                if first is None:
                    first = time.monotonic() - t0
                info = sf.info(path)
                audio_s += info.frames / info.samplerate
            return time.monotonic() - t0, first, audio_s

        wall, _, _ = timed_run()
        print(f"warmup: {wall:.1f}s")

        expected_s = estimate_frames(text) / 12
        for i in range(runs):
            wall, first, audio_s = timed_run()
            rtf = audio_s / wall
            # A run that produces far more audio than the text warrants is a
            # runaway (missed end-of-speech): its RTF is meaningless babble.
            runaway = audio_s > expected_s * 1.5
            if not runaway:
                best_rtf = max(best_rtf, rtf)
            print(f"run {i + 1}: {wall:.1f}s wall, first audio {first:.1f}s, "
                  f"{audio_s:.1f}s audio, RTF {rtf:.2f}"
                  f"{'  RUNAWAY (excluded)' if runaway else ''}")
    return load_s, best_rtf


def main():
    p = argparse.ArgumentParser(
        description="Benchmark voice-clone synthesis speed.")
    p.add_argument("-r", "--ref-audio", required=True, type=Path)
    p.add_argument("--ref-text", type=Path)
    p.add_argument("-m", "--models", nargs="+", default=DEFAULT_MODELS,
                   help="model ids to benchmark in succession")
    p.add_argument("-b", "--backend", choices=["auto", "mlx", "qwen-tts"],
                   default="auto")
    p.add_argument("-l", "--language", default="English")
    p.add_argument("-t", "--text", default=BENCH_TEXT)
    p.add_argument("--runs", type=int, default=2,
                   help="timed runs after 1 warmup")
    args = p.parse_args()

    ref_text = resolve_ref_text(args.ref_audio, args.ref_text)

    summary = []
    for model_id in args.models:
        print(f"\n=== {model_id} ===")
        try:
            load_s, rtf = bench_model(model_id, args.backend, args.ref_audio,
                                      ref_text, args.language, args.text,
                                      args.runs)
            summary.append(
                (model_id, f"load {load_s:.0f}s, best RTF {rtf:.2f}"))
        except Exception:
            traceback.print_exc()
            summary.append((model_id, "FAILED"))
        free_memory()

    print("\n=== summary ===")
    for model_id, result in summary:
        print(f"{model_id}: {result}")


if __name__ == "__main__":
    main()
