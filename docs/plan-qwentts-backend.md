# Plan: qwentts.cpp CUDA backend for serve.py

## Goal
Replace the torch/qwen-tts CUDA path with a GGML-based backend (qwentts.cpp) running
quantized GGUF weights, matching the local mlx-4bit setup in spirit: small weights,
fast decode, one daemon. The extension protocol (/speak, /stop, /health, /segment),
fx chain, token auth, and the mlx backend stay untouched.

## Current state (measured)
- Box: Arch, RTX 2060 Super (Turing sm_75, 8GB). flash-attn unsupported (needs sm_80+).
- torch backend, 1.7B bf16: RTF ~0.68 (slower than realtime), bf16 is emulated on Turing.
- Uncommitted fix in tts/serve.py: fp16 on pre-Ampere CUDA. Keep as torch fallback.
- No official CUDA quant of Qwen3-TTS exists; all 4/8-bit repos are MLX except one
  unverified BNB-4bit. GGUF conversions target qwentts.cpp, not mainline llama.cpp.

## qwentts.cpp facts (from README, verify at build time)
- Build: clone --recurse-submodules, ./buildcuda.sh (NVCC_CCBIN=g++-13 on rolling distros).
- GGUFs: talker (base 0.6B/1.7B) + shared tokenizer codec, from Serveurperso/Qwen3-TTS-GGUF.
- tts-server: --model <talker.gguf> --codec <tokenizer.gguf> --port N
  - POST /v1/audio/voices: register clone voice {name, ref wav or spk_b64/rvq_b64, ref_text}
  - POST /v1/audio/speech: {input, voice, response_format: "wav"|"pcm", seed, temperature, ...}
- CLI (qwen-tts) usable for one-shot benchmarking before any integration.

## Design: one daemon
serve.py -b qwentts spawns tts-server as a child process and proxies synthesis to it.

- New flags: --qwentts-bin (path to tts-server), --qwentts-model, --qwentts-codec,
  --qwentts-port (default: pick a free localhost port).
- load_qwentts_synth():
  1. Spawn tts-server bound to 127.0.0.1 only (never the LAN; serve.py owns auth).
  2. Poll until it answers, with a startup timeout.
  3. Register the clone voice once: POST /v1/audio/voices with ref wav + ref text.
  4. synth(text, make_path): POST /v1/audio/speech {input, voice, response_format: "wav"},
     write body to make_path(), yield it. fx/segment pipeline applies downstream unchanged.
- Lifecycle: terminate the child on exit (atexit + signal handlers); if the child dies,
  synth raises and the existing model-load/synth error path reports it.
- Future, not now: response_format "pcm" to stream chunks into multiple segments per
  block for lower first-audio latency.

## Steps
1. Box setup (manual, needs passphrase/sudo):
   - git clone --recurse-submodules https://github.com/ServeurpersoCom/qwentts.cpp
   - ./buildcuda.sh (Arch: NVCC_CCBIN=g++-13 if nvcc rejects current gcc)
   - Download GGUFs: 0.6B-base and 1.7B-base talkers at Q4 and Q8, plus tokenizer codec.
2. Benchmark matrix with the CLI, ref samples/c3po_god.wav, a fixed ~300-char text:
   {0.6B, 1.7B} x {Q4, Q8}, record RTF and subjective quality. Pick the smallest model
   at or above RTF ~1.5 whose quality is acceptable. Decision gate: if nothing beats
   realtime, stop; reconsider (0.6B fp16 torch, or accept buffering).
3. Implement the backend in tts/serve.py per the design above.
4. Tests in tts/test_serve.py: mock tts-server with a stub HTTP server; cover voice
   registration, wav round-trip, child-death error path, and port/flag plumbing.
   Run the full pytest suite before commit.
5. Run on box:
   uv run --no-group mlx tts/serve.py -r samples/c3po_god.wav --fx -b qwentts \
     --qwentts-bin ~/qwentts.cpp/build/tts-server \
     --qwentts-model <talker.gguf> --qwentts-codec <tokenizer.gguf> \
     --host 0.0.0.0 --token <secret> --playback client
   Verify from laptop via extension popup (health, speak, stop, preempt).

## Execution workflow (worktree + subagents)
- Do the serve.py work in a git worktree off main (EnterWorktree) so main stays
  runnable on the box mid-implementation; merge back when tests pass.
- Subagents:
  - Explore agent (read-only) on the qwentts.cpp source to confirm the real
    tts-server flags and JSON fields before implementation (closes risk 1).
  - One agent implements the backend in the worktree, a parallel agent writes the
    tts/test_serve.py stub-server tests against the plan's interface; reconcile
    and run pytest in the worktree.
  - Benchmarks (step 2) stay manual on the box; agents have no ssh access.

## Risks / unknowns
- qwentts.cpp API details are from its README summary; confirm flag names and JSON
  fields against the actual repo when building.
- Turing support and RTF of the CUDA GGML kernels: unknown until benchmarked (step 2
  is the gate).
- Clone quality of GGUF-quantized talker vs mlx-4bit: judge by ear in step 2.
- Concurrency: tts-server's behavior under overlapping requests is undocumented;
  serve.py's synth loop is single-threaded, which avoids the question.
- torch group stays in pyproject as fallback; do not remove it in this change.
