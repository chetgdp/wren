# voice-ml
i let the model geenrate so much garbage its so sad

fix glitches

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
