# voice-ml
i let the model geenrate so much garbage its so sad

fix glitches

```
llama-server \
                                            -m ~/models/Qwen3.5-9B-VLM-Q4_K_M.gguf \
                                            --mmproj ~/models/qwen3.5-9B-mmproj-F16.gguf --no-mmproj-offload \
                                            --host 0.0.0.0 --port 8888 \
                                            -ngl 99 \
                                            --parallel 2 --ctx-size 262144 --kv-unified \
                                            -fa on -ctk q8_0 -ctv q8_0 \
                                            --batch-size 2048 --ubatch-size 512 \
                                            --threads 16 --threads-batch 16 \
                                            --jinja
```

for macos
```
uv run tts/serve.py -r samples/c3po_god.wav --fx --playback client
```

for linux cuda
```
uv run --no-group mlx tts/serve.py -r samples/c3po_god.wav --fx -b qwentts \
                                          --qwentts-bin ~/voice-ml/qwentts.cpp/build/tts-server \
                                          --qwentts-model ~/voice-ml/qwentts.cpp/models/qwen-talker-1.7b-base-Q8_0.gguf \
                                          --qwentts-codec ~/voice-ml/qwentts.cpp/models/qwen-tokenizer-12hz-Q8_0.gguf \
                                          --host 0.0.0.0 --playback client
```

## Command line options

All tools run via `uv run <script>`. On Linux/CUDA use the torch dependency
group: `uv run --no-group mlx --group torch <script>`.

### tts/serve.py - TTS daemon

Loads the model once, then speaks POSTed text (`POST /speak`, `/stop`,
`/pause`, `/resume`, `/seek`; `GET /health`, `/segment`).

```
uv run tts/serve.py -r samples/c3po_god.wav --fx
```

| option | default | description |
|---|---|---|
| `-r, --ref-audio` | required | reference voice clip (~3s wav) |
| `--ref-text` | sibling `.txt` of ref-audio | transcript of the reference clip |
| `-m, --model` | `models/Qwen3-TTS-12Hz-1.7B-Base-4bit` | TTS model id (HF repo or local path) |
| `-b, --backend` | `auto` | `mlx` or `qwen-tts` (torch); auto picks whichever is installed |
| `-l, --language` | `English` | text language (qwen-tts backend only) |
| `-d, --device` | `auto` | torch device, `cuda` > `mps` > `cpu` (qwen-tts backend only) |
| `--fx` | off | apply the droid effect chain (fx.py) to all output |
| `--fx-ring-freq` | `40.0` | ring modulator carrier Hz |
| `--fx-ring-mix` | `0.12` | ring modulator wet mix 0-1 |
| `-p, --port` | `8765` | port to listen on |
| `--host` | `127.0.0.1` | bind address; `0.0.0.0` serves the LAN (set `--token`) |
| `--playback` | `local` | `local` plays on this machine; `client` buffers segments for `GET /segment` (browser playback) |
| `--token` | `$VOICE_ML_TOKEN` | require `Authorization: Bearer <token>` on every request |

### tts/clone.py - one-shot voice clone (torch backend)

```
uv run --no-group mlx --group torch tts/clone.py -r samples/ref.wav -t "hello there"
```

| option | default | description |
|---|---|---|
| `-r, --ref-audio` | required | reference voice clip |
| `--ref-text` | sibling `.txt` | transcript of the reference clip |
| `-t, --text` | one of -t/-f required | text to speak, inline |
| `-f, --text-file` | | file containing the text to speak |
| `-o, --output` | `output_voice_clone.wav` | output wav path |
| `-l, --language` | `English` | text language |

### tts/fx.py - droid effect chain on a wav

```
uv run python tts/fx.py output_voice_clone.wav -o output_droid.wav
```

| option | default | description |
|---|---|---|
| `input` | required | input wav |
| `-o, --output` | `<input>_droid.wav` | output wav |
| `--ring-freq` | `40.0` | ring modulator carrier Hz (lower = subtler growl) |
| `--ring-mix` | `0.12` | ring modulator wet mix 0-1 (0 = off) |

### tts/bench.py - model/backend RTF benchmark

| option | default | description |
|---|---|---|
| `-r, --ref-audio` | required | reference voice clip |
| `--ref-text` | sibling `.txt` | transcript of the reference clip |
| `-m, --models` | built-in list | model ids to benchmark |
| `-b, --backend` | `auto` | `mlx` or `qwen-tts` |
| `-l, --language` | `English` | text language |
| `-t, --text` | built-in text | text to synthesize |
| `--runs` | `2` | timed runs after 1 warmup |

### trs/transcribe.py - transcribe a clip (for ref-text)

| option | default | description |
|---|---|---|
| `audio` | required | path to the reference audio clip |
| `--language` | auto-detect | ISO code, e.g. `en` |

### trs/download.py - grab audio from a video URL

| option | default | description |
|---|---|---|
| `url` | required | video URL (YouTube, etc.) |
| `-o, --output` | `audio.wav` | output wav path |
| `--js-runtime` | `node` | JS runtime for yt-dlp |

---

## Browser Extension Keybinds

### Global Keybinds (on every page)

| Key | Action |
|-----|--------|
| **`i`** | Speak selected text |
| **`p`** | - If there's a selection: start **read-page mode** from selection<br>- If **no selection** and an overlay exists: **toggle pause** on active overlay<br>- If **no selection** and no overlay: start **read-page mode** |
| **`o`** | Stop speaking |

### Read-Page Mode Keybinds

| Key | Action |
|-----|--------|
| **`j`** | Seek back by **sentence** |
| **`k`** | Seek forward by **sentence** |
| **`J`** | Seek back by **paragraph** |
| **`K`** | Seek forward by **paragraph** |
| **`<`** | Slow down (decrease speed) - client playback only |
| **`>`** | Speed up (increase speed) - client playback only |

### Notes

- All keybinds require **no modifier keys** (Ctrl/Cmd/Alt are ignored)
- Keybinds are disabled when typing in editable fields (inputs, textareas, contenteditable)
- The overlay widget (fixed at bottom-right) provides clickable buttons for pause/stop/speed controls
- Rate controls (`<` / `>`) only work with **client playback mode** (when daemon is started with `--playback client`)
