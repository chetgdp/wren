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

## Synthesis server

One server (any host, usually the CUDA box, reached over Tailscale) does all
synthesis with qwentts.cpp. It never plays audio: each client plays its own
channel by streaming `GET /segment`.

```
uv run tts/serve.py \
    --qwentts-bin ~/voice-ml/qwentts.cpp/build/tts-server \
    --qwentts-model ~/voice-ml/qwentts.cpp/models/qwen-talker-1.7b-base-Q8_0.gguf \
    --qwentts-codec ~/voice-ml/qwentts.cpp/models/qwen-tokenizer-12hz-Q8_0.gguf \
    --initial-voice c3po --host 0.0.0.0
```

| option | default | description |
|---|---|---|
| `--host` | `127.0.0.1` | bind address |
| `-p, --port` | `8765` | port to listen on |
| `--data-dir` | `~/.local/share/wren` (Linux), `~/Library/Application Support/voice-ml` (macOS) | holds `voices/<id>/` and `settings.json` |
| `--qwentts-bin` | required | qwentts.cpp `tts-server` binary |
| `--qwentts-model` | required | talker GGUF (`qwen-talker-*.gguf`) |
| `--qwentts-codec` | required | codec GGUF (`qwen-tokenizer-*.gguf`) |
| `--language` | `English` | language passed to tts-server |
| `--initial-voice` | none | voice id used only while `settings.json` has no active voice |

Each voice is a directory `voices/<id>/` with `profile.json`
(`{"id", "display_name"}`), `reference.wav` (a few seconds of clean
speech) and `transcript.txt` (exactly what the clip says). Add voices over
HTTP with `POST /voices` (multipart: `id`, `display_name`, `audio`,
`transcript`) or by creating the directory; switch with
`PUT /voice {"voice": "<id>"}`. Effects and the default speech rate are set
with `PATCH /settings {"effects": true, "default_rate": 1.2}` and persist in
`settings.json`.

Speech without a `channel` goes to the active client (see below); with no
active client the server answers 409 `no_active_client`.

Tests: `uv run pytest tts` (runs against a stub tts-server, no model needed).

## Wren.app client

- In Wren's Settings, enter the server host (e.g. `box:8765` on Tailscale).
- Audio plays on the Mac you last used: Wren claims "active" when you touch
  that Mac's keyboard or mouse, and speech moves there. Speech already
  playing on the previous Mac stops.
- The `wren` CLI (`wren say "..."`, including from an SSH session on
  another machine) sends no channel, so the server routes it to that Mac.

## Other tools

### tts/fx.py - droid effect chain on a wav

```
uv run python tts/fx.py input.wav -o output_droid.wav
```

| option | default | description |
|---|---|---|
| `input` | required | input wav |
| `-o, --output` | `<input>_droid.wav` | output wav |
| `--ring-freq` | `40.0` | ring modulator carrier Hz (lower = subtler growl) |
| `--ring-mix` | `0.12` | ring modulator wet mix 0-1 (0 = off) |

### trs/transcribe.py - transcribe a clip (for transcript.txt)

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
| **`<`** | Slow down (decrease speed) |
| **`>`** | Speed up (increase speed) |

### Notes

- All keybinds require **no modifier keys** (Ctrl/Cmd/Alt are ignored)
- Keybinds are disabled when typing in editable fields (inputs, textareas, contenteditable)
- The overlay widget (fixed at bottom-right) provides clickable buttons for pause/stop/speed controls
- Rate controls (`<` / `>`) adjust the extension's own player; the extension always plays its channel client-side, so no daemon flag is needed
