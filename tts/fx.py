"""C3PO-style droid effect chain for TTS output (pedalboard + numpy).

The TTS clone reproduces the human voice; the metallic character of the
original is post-processing. This recreates it: band-limiting, a low-mix
ring modulator for the metallic edge, chorus for the slight doubling, and
mild saturation.

DroidFX is stateful so consecutive segments of one gapless stream can be
processed independently without clicks at the joins (the ring-mod carrier
phase and the chorus LFO continue across calls). Call reset() between
unrelated streams.

Example:
    uv run python tts/fx.py output_voice_clone.wav -o output_droid.wav
"""

import argparse
from pathlib import Path

import numpy as np
from pedalboard import Pedalboard, Chorus, Distortion, HighpassFilter, LowpassFilter, Gain


class DroidFX:
    def __init__(self, ring_freq: float = 40.0, ring_mix: float = 0.12):
        self.ring_freq = ring_freq
        self.ring_mix = ring_mix
        self._offset = 0  # samples processed, for carrier phase continuity
        self._board = Pedalboard([
            HighpassFilter(cutoff_frequency_hz=180),
            LowpassFilter(cutoff_frequency_hz=6500),
            Chorus(rate_hz=0.9, depth=0.15, mix=0.25, centre_delay_ms=4),
            Distortion(drive_db=6),
            Gain(gain_db=-1),
        ])

    def reset(self):
        self._offset = 0
        self._board.reset()

    def process(self, audio: np.ndarray, sr: int) -> np.ndarray:
        """audio: float32, (samples,) or (channels, samples)."""
        n = audio.shape[-1]
        t = (np.arange(n) + self._offset) / sr
        carrier = np.sin(2 * np.pi * self.ring_freq * t).astype(audio.dtype)
        self._offset += n
        audio = (1 - self.ring_mix) * audio + self.ring_mix * audio * carrier
        return self._board(audio, sr, reset=False)


def main():
    import soundfile as sf

    p = argparse.ArgumentParser(
        description="Apply the droid effect chain to a wav file.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("input", type=Path, help="input wav")
    p.add_argument("-o", "--output", type=Path, help="output wav (default: <input>_droid.wav)")
    p.add_argument("--ring-freq", type=float, default=40.0,
                   help="ring modulator carrier Hz (lower = subtler growl)")
    p.add_argument("--ring-mix", type=float, default=0.12,
                   help="ring modulator wet mix 0-1 (0 = off)")
    args = p.parse_args()

    out = args.output or args.input.with_stem(args.input.stem + "_droid")
    audio, sr = sf.read(str(args.input), dtype="float32")
    if audio.ndim == 2:  # (samples, channels) -> (channels, samples)
        audio = audio.T
    fx = DroidFX(ring_freq=args.ring_freq, ring_mix=args.ring_mix)
    processed = fx.process(audio, sr)
    sf.write(str(out), processed.T if processed.ndim == 2 else processed, sr)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
