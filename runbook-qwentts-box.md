# Runbook: qwentts backend on the box (Arch, RTX 2060 Super)

Everything verified against qwentts.cpp source on 2026-07-20. The serve.py
backend and tests are done; this covers the manual box steps (plan steps 1,
2, 5).

## 1. Build qwentts.cpp

Done on the box 2026-07-20. What worked (don't use `buildcuda.sh`, it
hardcodes `/usr/local/cuda`; Arch's cuda lives in `/opt/cuda`):

```fish
git clone --recurse-submodules git@github.com:ServeurpersoCom/qwentts.cpp.git
cd qwentts.cpp
rm -rf build; mkdir build; cd build
NVCC_CCBIN=g++-15 cmake .. -DGGML_CUDA=ON \
    -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES=native
cmake --build . --config Release -j (nproc)
```

Notes:
- SSH clone URL on purpose: the box's ~/.gitconfig had a malformed
  insteadOf rewrite (fixed 2026-07-20 to `url.ssh://git@github.com/.
  insteadOf=https://github.com/`, trailing slash matters).
- `NVCC_CCBIN=g++-15`: host GCC is 16.x which nvcc rejects; gcc15 is
  installed as a dependency of the cuda package.
- Binaries land in `build/`: `qwen-tts` (CLI), `tts-server`, `qwen-codec`.

## 2. Download GGUFs

Repo is `Serveurperso/Qwen3-TTS-GGUF` (the in-tree `models.sh` points at a
renamed/private repo and 401s; don't use it). One-liner, fish syntax:

```fish
cd ~/voice-ml/qwentts.cpp; mkdir -p models; for f in qwen-talker-0.6b-base-Q4_K_M.gguf qwen-talker-0.6b-base-Q8_0.gguf qwen-talker-1.7b-base-Q4_K_M.gguf qwen-talker-1.7b-base-Q8_0.gguf qwen-tokenizer-12hz-Q8_0.gguf; uvx --from 'huggingface_hub[cli]' hf download Serveurperso/Qwen3-TTS-GGUF $f --local-dir models; end
```

Sizes: 0.6b Q4 629MB / Q8 993MB, 1.7b Q4 1.2GB / Q8 2.1GB, tokenizer 291MB.

## 3. Benchmark matrix (decision gate)

Copy over `samples/c3po_god.wav` + `samples/c3po_god.txt` from this repo,
make a fixed ~300-char prompt, then run all four talkers:

```fish
echo "The odds of successfully navigating an asteroid field are approximately three thousand seven hundred and twenty to one. Sir, I suggest a different strategy. R2 says the chances of survival are slim, but he has been known to make mistakes, from time to time. Oh dear, oh dear. We are doomed, I fear." > /tmp/bench.txt

cd ~/voice-ml/qwentts.cpp
for m in qwen-talker-0.6b-base-Q4_K_M qwen-talker-0.6b-base-Q8_0 qwen-talker-1.7b-base-Q4_K_M qwen-talker-1.7b-base-Q8_0
    echo "== $m"
    ./build/qwen-tts --model models/$m.gguf \
        --codec models/qwen-tokenizer-12hz-Q8_0.gguf \
        --ref-wav ../samples/c3po_god.wav --ref-text ../samples/c3po_god.txt \
        --lang English --seed 42 -o /tmp/$m.wav < /tmp/bench.txt
end
```

Reading the numbers: qwen-tts logs `[Perf] Total ... RTF ...` where
RTF = wall/audio, the INVERSE of serve.py's audio/wall. The plan's gate
"RTF >= 1.5" in serve.py terms means qwentts `[Perf] RTF <= 0.67`.
Run each once to warm up, then record the second run.

Pick: smallest model at qwentts RTF <= 0.67 whose /tmp/*.wav sounds
acceptable by ear (clone fidelity vs the mlx-4bit setup). If nothing beats
realtime (all RTF > 1.0), stop here; fall back to 0.6B fp16 torch or accept
buffering.

Results (box, 2026-07-20, single run incl. CUDA graph warmup; TTFA ~325ms
on all four):

| model       | qwentts RTF | audio/wall |
|-------------|-------------|------------|
| 0.6b Q4_K_M | 0.172       | 5.8x       |
| 0.6b Q8_0   | 0.194       | 5.2x       |
| 1.7b Q4_K_M | 0.187       | 5.3x       |
| 1.7b Q8_0   | 0.230       | 4.3x       |

All pass the gate. PICKED BY EAR: `qwen-talker-1.7b-base-Q8_0` (4.3x
realtime vs torch bf16's 0.68x).

## 4. Run the daemon

From the voice-ml checkout on the box (winner from step 3 substituted):

```sh
uv run --no-group mlx tts/serve.py -r samples/c3po_god.wav --fx -b qwentts \
    --qwentts-bin ~/voice-ml/qwentts.cpp/build/tts-server \
    --qwentts-model ~/voice-ml/qwentts.cpp/models/qwen-talker-1.7b-base-Q8_0.gguf \
    --qwentts-codec ~/voice-ml/qwentts.cpp/models/qwen-tokenizer-12hz-Q8_0.gguf \
    --host 0.0.0.0 --token <secret> --playback client
```

`--qwentts-port` is optional (defaults to a free localhost port).
tts-server binds 127.0.0.1 only; serve.py owns auth on the LAN side.
Expected startup log: "starting tts-server", "tts-server ready",
"voice 'serve_clone' registered", then the warmup synthesis with serve.py's
own RTF line (audio/wall, higher is better).

## 5. Verify from the laptop

Extension popup against the box: health, speak, stop, preempt
(send a second /speak mid-playback). Also confirm cleanup: Ctrl-C or
`kill <serve.py pid>` (SIGTERM) must take tts-server down with it
(`pgrep tts-server` empty afterwards).
