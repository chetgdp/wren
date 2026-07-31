# Plan: native macOS TTS daemon

Make the TTS side a first-class macOS citizen like cawker: menu bar presence,
runs in the background, configurable without the command line. Cawker stays
the STT daemon; this is its output-side sibling. Two daemons, separate
concerns: cawker owns mic + accessibility + hotkey, this owns the model +
speakers + HTTP.

## Step 0 (gate): quality benchmark

The whole plan rests on qwentts.cpp (GGUF, Metal) sounding as good as the
MLX 4-bit path for the active voice. If it doesn't, the Swift app wraps the
Python daemon instead of replacing it, and everything below still applies
except the engine section.

Run `tts/bench_ab.py` (see that file): same sentences through both backends,
paired wavs written side by side for blind listening, RTF printed per run.
Decide with ears, tie-break with RTF.

## Architecture

```
menu bar app (Swift)
  ├─ HTTP server 127.0.0.1:8765   <- unchanged public API
  ├─ orchestration                 <- port of serve.py's Speaker
  │    sanitize -> chunk -> synth queue -> play queue, epoch preemption
  ├─ playback: AVAudioEngine
  │    AVAudioUnitTimePitch        <- pitch-preserving speed, replaces
  │                                    pedalboard/soundtouch, and it's live
  │                                    (no offline stretch step)
  └─ engine: tts-server (qwentts.cpp) child process, Metal build
       spawn/babysit exactly like serve.py's load_qwentts_synth does today
```

What gets rewritten is the ~1200-line orchestration layer, not inference.
serve.py already proxies to tts-server on Linux; the Swift daemon does the
same spawn-and-proxy on macOS. The MLX path in serve.py stays as the
dev/research harness - it is not deleted, it is just no longer the thing
users run.

## API surface: frozen

`POST /speak` (text|blocks, raw, append, speed), `POST /stop`, `/pause`,
`/resume`, `/seek`, `GET /health`, `GET /segment` - byte-for-byte the
contract serve.py serves today. The extension and any agent already speak
it; the daemon implementation is swappable behind it. Same defaults: bind
127.0.0.1, reject http(s) Origins, optional bearer token, 1 MiB body cap.

Addition: `GET /config` and `POST /config` (voice, speed, fx on/off) so the
menu bar UI, the extension, and agents can reconfigure a running daemon
without a restart. POST /config persists to the config file (below).

## Config: file is the truth, menu bar is the UI

Today's invocation is the spec for the defaults:

    uv run tts/serve.py -r samples/c3po_god.wav --fx --speed 1.4

becomes `~/Library/Application Support/voice-ml/config.json`:

```json
{
  "voice": "c3po_god",
  "voices_dir": "~/Code/voice-ml/samples",
  "speed": 1.4,
  "fx": true,
  "port": 8765,
  "launch_at_login": true
}
```

- Daemon reads it at startup and watches it (or applies POST /config writes).
- Menu bar: voice picker (scans voices_dir for wav+txt pairs), speed slider,
  fx toggle, launch-at-login toggle, pause/stop buttons, "speaking" state in
  the icon.
- CLI flags stay as one-off overrides for development.

## Lifecycle: mirror cawker

- LaunchAgent for background + launch-at-login (`install --launch-at-login`,
  `install --uninstall`).
- `doctor`: config valid, ref wav+txt present, tts-server binary + GGUFs
  present, port free, Metal available.
- Menu bar icon is the liveness indicator; quitting the app stops the daemon.
- Model stays resident (warmup at start, like serve.py); no socket-activation
  cleverness - first-token latency is the product.

## `voice` CLI shim

Thin binary on PATH, curl inside, same body as the daemon's API:

    voice say "hello there"        # POST /speak
    voice say --append "and this"
    voice stop | voice pause | voice resume
    voice speed 1.4                # POST /config
    voice status                   # GET /health, human-readable

Rationale: agents and shell scripts discover a binary on PATH more naturally
than a port number, and it documents the API by existing. Ship it inside the
app bundle, symlink on install (cawker's install.sh pattern).

## Steps

1. **Benchmark** (`tts/bench_ab.py`): build qwentts.cpp with Metal, run the
   A/B, listen. Gate.
2. Swift package skeleton: menu bar app + LaunchAgent + config file
   read/watch. No audio yet; /health serves.
3. Port orchestration: sanitize/chunk (direct port of serve.py's functions +
   its tests), synth/play queues with epoch preemption.
4. Engine: spawn tts-server, register voice, proxy synthesis (port of
   load_qwentts_synth).
5. Playback: AVAudioEngine + AVAudioUnitTimePitch; wire speed end-to-end.
6. /config + menu bar controls.
7. `voice` shim, install script, doctor.
8. Parity check: run serve.py's HTTP test suite against the Swift daemon
   (tests are black-box over HTTP already; point them at the new port).
