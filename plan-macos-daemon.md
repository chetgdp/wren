# Plan: Wren - macOS-native management for the TTS daemon

Names (decided 2026-08-02): the STT daemon (cawker) becomes **Otis** (Greek,
"keen of hearing"; also a bird genus) and the TTS daemon is **Wren** (the
tiny bird with the enormous voice). Otis hears, Wren speaks. The cawker
rename is separate future work in that repo.

Make Wren a first-class macOS citizen like Otis: menu bar presence, runs in
the background, configurable without the command line. Two daemons, separate
concerns: Otis owns mic + accessibility + hotkey, Wren owns the model +
speakers + HTTP.

Constraint that shapes everything: **serve.py stays the server, and it must
keep running bare on Linux** (the CUDA box on tailscale serves the browser
extension with no Swift anywhere). Swift is the macOS management layer, not
a replacement. Clients - extension, agents, `voice` shim - only ever see the
HTTP contract, so they cannot tell (and must not care) which platform or
manager is behind the port.

## Phase A: Swift manager app around serve.py

The shippable milestone. A menu bar app that owns the daemon's lifecycle,
config, AND audio playback - Python never touches the speakers on macOS:

```
menu bar app (Swift)                       linux box (no Swift)
  ├─ spawns serve.py --playback client      systemd unit / CLI runs the
  ├─ plays audio: long-polls GET /segment,   same serve.py directly
  │    AVAudioEngine + AVAudioUnitTimePitch  (extension is its own
  │    (live rate, epoch-aware preemption)    /segment player there)
  ├─ watches /health -> icon state
  ├─ writes config file, restarts child
  │    on voice/fx change
  └─ LaunchAgent, launch-at-login
            │
            └── serve.py: HTTP :8765, orchestration, synthesis
                (mlx locally, or -b qwentts for GGUF/Metal/CUDA)
```

This reuses the client-playback mode that already exists for the browser
extension: serve.py buffers synthesized segments (SegmentStore) and the
Swift app consumes them exactly like offscreen.js does - long-poll
/segment?after=seq, play, drop everything on an epoch bump. No new server
code; the Swift app is just a second, native /segment client. sounddevice/
afplay remain only as the fallback for running serve.py bare.

Speed placement follows playback: the player owns the rate. In client mode
the daemon simply runs at speed 1 (convention, no enforcement code) and
each client stretches for itself - the extension with soundtouch, Swift
with AVAudioUnitTimePitch. The server-side pedalboard stretch exists for
local-playback mode only.

Python stays, but hidden: no terminal, no flags, no uv invocation visible -
and no Python in the audio path.

## Phase B (optional, later): native Swift server on macOS

Only if Phase A's Python child proves annoying (bundle size, cold start,
env fragility). Move the HTTP server + orchestration into the Swift app on
macOS; serve.py remains the Linux server. Engine candidates, still to be
verified (ref-audio cloning, streaming, quant support, metallib bundling):

- tts-server (qwentts.cpp) child, Metal build - proven with serve.py today,
  isolated crash domain.
- mlx-audio-swift / swift-qwen3-tts - Qwen3-TTS natively on MLX Swift,
  in-process, no child. Younger codebases.

Playback would move to AVAudioEngine + AVAudioUnitTimePitch (live
pitch-preserving speed instead of offline stretch). Parity gate: serve.py's
HTTP test suite is black-box over HTTP; the Swift server must pass it.

## Benchmark status (step 0, 2026-07-31, M-series Mac, c3po_god)

Speed passed, quality open. 1.7B Q8_0 GGUF on Metal vs MLX 1.7B 4-bit:
bench RTF is a wash (qwentts 3.39 one-shot / 2.33 streaming vs mlx 3.03),
both far above realtime. The initial "Q8 sounds crisper" verdict was
confounded (MLX daemon ran --fx, qwentts didn't); the fx-free bench_ab
pairs in outputs/ab/ sound comparable. For a clean engine comparison,
convert an MLX 8-bit model (mlx_audio.convert --q-bits 8) and A/B vs Q8_0.
Resolved along the way: the qwentts proxy now streams pcm (~1s segments),
matching the MLX path's first-audio latency.

## API surface: frozen

`POST /speak` (text|blocks, raw, append, speed), `POST /stop`, `/pause`,
`/resume`, `/seek`, `GET /health`, `GET /segment` - byte-for-byte the
contract serve.py serves today, on macOS and Linux alike. Same defaults:
bind 127.0.0.1, reject http(s) Origins, optional bearer token, 1 MiB body
cap.

Addition: `GET /config` and `POST /config` (voice, speed, fx on/off) so the
menu bar UI, the extension, and agents can reconfigure a running daemon
without a restart. Implemented in serve.py so Linux gets it too; the menu
bar app is just another client of it.

## Config: file is the truth, menu bar is the UI

Today's invocation is the spec for the defaults:

    uv run tts/serve.py -r samples/c3po_god.wav --fx --speed 1.4

becomes a config file (`~/Library/Application Support/voice-ml/config.json`
on macOS, `~/.config/voice-ml/config.json` on Linux):

```json
{
  "voice": "c3po_god",
  "voices_dir": "~/Code/voice-ml/samples",
  "speed": 1.4,
  "fx": true,
  "port": 8765,
  "backend": "auto"
}
```

- serve.py grows `--config` (or reads the default path when flags are
  absent); flags stay as one-off overrides for development.
- Menu bar: voice picker (scans voices_dir for wav+txt pairs), speed slider,
  fx toggle, launch-at-login toggle, pause/stop buttons, "speaking" state in
  the icon.
- POST /config persists to the file; the manager restarts the child when a
  change (voice) needs a model reload, hot-applies when it doesn't (speed).

## Lifecycle: mirror cawker

- macOS: LaunchAgent for background + launch-at-login (`install
  --launch-at-login`, `install --uninstall`); menu bar icon is the liveness
  indicator; quitting the app stops the daemon.
- Linux: systemd user unit doing the same job (documented, not built - the
  box already runs it by hand fine).
- `doctor`: config valid, ref wav+txt present, engine binary + GGUFs present
  when backend=qwentts, port free, Metal/CUDA available.
- Model stays resident (warmup at start); no socket-activation cleverness -
  first-token latency is the product.

## `wren` CLI shim

Thin binary on PATH, curl inside, same body as the daemon's API:

    wren say "hello there"         # POST /speak
    wren say --append "and this"
    wren stop | wren pause | wren resume
    wren speed 1.4                 # POST /config
    wren status                    # GET /health, human-readable

Works against localhost or the tailscale box (`WREN_HOST`/`--host`).
Agents and shell scripts discover a binary on PATH more naturally than a
port number, and it documents the API by existing.

## Steps

1. ~~Benchmark~~ (done; speed passed, quality comparison pending MLX-8bit).
2. serve.py: config-file support + /config endpoints (+ tests). Benefits
   Linux immediately, prerequisite for the manager app.
3. Swift manager skeleton: menu bar app that spawns serve.py --playback
   client, /health icon, quit-kills-child, LaunchAgent.
4. Swift segment player: /segment long-poll loop -> AVAudioEngine +
   AVAudioUnitTimePitch, epoch-aware preemption (port offscreen.js's
   scheduling logic). Daemon runs speed 1 in client mode by convention;
   the player owns the rate.
5. Menu bar controls wired to /config; voice-change restart handling.
6. `voice` shim, install script, doctor.
7. Decide on Phase B only after living with Phase A.
