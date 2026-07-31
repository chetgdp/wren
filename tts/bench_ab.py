"""A/B quality benchmark: the same sentences through the MLX and qwentts.cpp
backends, paired wavs written side by side for blind listening.

Speed (RTF) is printed per run, but the point is the audio: does the GGUF
Metal build of qwentts.cpp sound as good as the MLX 4-bit path for this
voice? Decide with ears, tie-break with RTF (see plan-macos-daemon.md).

Backends can run in one invocation (qwentts is subprocess+HTTP only, no
torch import) or separately into the same outdir - files are named by text
index and backend, so pairs line up either way.

Example:
    uv run tts/bench_ab.py -r samples/c3po_god.wav --backends mlx
    uv run tts/bench_ab.py -r samples/c3po_god.wav --backends qwentts \
        --qwentts-bin qwentts.cpp/build/tts-server \
        --qwentts-model qwentts.cpp/models/qwen-talker-1.7b-base-Q8_0.gguf \
        --qwentts-codec qwentts.cpp/models/qwen-tokenizer-12hz-Q8_0.gguf
"""

import argparse
import tempfile
import time
from pathlib import Path

from serve import (DEFAULT_MODEL, _cleanup_qwentts, _pick_free_port,
                   load_synth, resolve_ref_text)

# Deliberately varied: plain prose, numbers/acronyms, a question with
# punctuation-driven prosody, and a long sentence that exerces chunk-length
# generation. Same order every run so file indices are stable.
AB_TEXTS = [
    "The daemon loads the model once and keeps it resident, so each request "
    "only pays for synthesis.",
    "Version 2 ships on May 14th with GGUF, Metal support, and a 1.7 billion "
    "parameter talker.",
    "Are you sure that's the right port? It worked yesterday, didn't it?",
    "When the queue drains and nothing is left to say, the stream stays open "
    "so the next request starts without paying the setup cost all over "
    "again, which is the entire reason the daemon exists.",
]


def concat_wavs(paths, out_path):
    """Join streamed segments into one listenable file."""
    import numpy as np
    import soundfile as sf
    parts, sr = [], None
    for path in paths:
        data, seg_sr = sf.read(path, dtype="float32")
        sr = sr or seg_sr
        parts.append(data)
    sf.write(out_path, np.concatenate(parts), sr)


def run_backend(backend, args, ref_text, outdir):
    qwentts_port = _pick_free_port() if backend == "qwentts" else None
    model_id = args.mlx_model if backend == "mlx" else str(args.qwentts_model)
    synth = load_synth(
        backend, model_id, args.ref_audio, ref_text, args.language,
        qwentts_bin=args.qwentts_bin, qwentts_model=args.qwentts_model,
        qwentts_codec=args.qwentts_codec, qwentts_port=qwentts_port,
    )
    results = []
    try:
        with tempfile.TemporaryDirectory() as tmp:
            counter = [0]

            def make_path():
                counter[0] += 1
                return str(Path(tmp) / f"{counter[0]}.wav")

            # Warmup: first generation pays JIT/cache costs on both backends.
            list(synth("Warm up run.", make_path))

            import soundfile as sf
            for i, text in enumerate(AB_TEXTS):
                t0 = time.monotonic()
                segs = list(synth(text, make_path))
                wall = time.monotonic() - t0
                out = outdir / f"{i:02d}-{backend}.wav"
                concat_wavs(segs, out)
                info = sf.info(out)
                audio_s = info.frames / info.samplerate
                rtf = audio_s / wall
                results.append((out.name, wall, audio_s, rtf))
                print(f"  {out.name}: {wall:.1f}s wall, {audio_s:.1f}s audio, "
                      f"RTF {rtf:.2f}")
    finally:
        _cleanup_qwentts()  # no-op unless the qwentts child is running
    return results


def main():
    p = argparse.ArgumentParser(
        description="Same-text A/B of MLX vs qwentts.cpp for one voice.")
    p.add_argument("-r", "--ref-audio", required=True, type=Path)
    p.add_argument("--ref-text", type=Path)
    p.add_argument("-l", "--language", default="English")
    p.add_argument("-o", "--outdir", type=Path, default=Path("outputs/ab"))
    p.add_argument("--backends", nargs="+", choices=["mlx", "qwentts"],
                   default=["mlx", "qwentts"])
    p.add_argument("--mlx-model", default=DEFAULT_MODEL)
    p.add_argument("--qwentts-bin", type=Path)
    p.add_argument("--qwentts-model", type=Path)
    p.add_argument("--qwentts-codec", type=Path)
    args = p.parse_args()

    if "qwentts" in args.backends and not all(
            [args.qwentts_bin, args.qwentts_model, args.qwentts_codec]):
        raise SystemExit("qwentts backend needs --qwentts-bin, "
                         "--qwentts-model, and --qwentts-codec")
    ref_text = resolve_ref_text(args.ref_audio, args.ref_text)
    args.outdir.mkdir(parents=True, exist_ok=True)

    summary = {}
    for backend in args.backends:
        print(f"\n=== {backend} ===")
        summary[backend] = run_backend(backend, args, ref_text, args.outdir)

    print(f"\n=== summary ===\npairs in {args.outdir}/  "
          "(listen blind: shuffle, don't peek at names)")
    for backend, results in summary.items():
        mean_rtf = sum(r[3] for r in results) / len(results)
        print(f"{backend}: mean RTF {mean_rtf:.2f} over {len(results)} texts")


if __name__ == "__main__":
    main()
