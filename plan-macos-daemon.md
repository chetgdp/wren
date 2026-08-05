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
  ├─ spawns serve.py --local-player client      systemd unit / CLI runs the
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

The Swift app consumes the local channel's segment stream exactly like
offscreen.js consumes the extension's - long-poll /segment?after=seq with
a played cursor, play, drop everything on an epoch bump. sounddevice/
afplay remain only for running serve.py bare (--local-player daemon).

Speed knobs are multiplicative (see Channels): the daemon's config speed
stretches server-side for all channels; the Swift player's
AVAudioUnitTimePitch rate - like the extension's soundtouch - multiplies
on top and is client business.

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
- Persistence: read once at launch, live settings held in memory, written
  back on every change (not at shutdown - daemons die by SIGKILL). Each
  write is atomic: full content to a temp file in the same directory, then
  rename over config.json, so a crash mid-save never leaves a truncated
  file.
- Menu bar: voice picker (scans voices_dir for wav+txt pairs), speed slider,
  fx toggle, output-device picker (pure Swift, AVAudioEngine - never touches
  the daemon), launch-at-login toggle, pause/stop buttons, "speaking" state
  in the icon.
- Adding a voice: two pickers, wav and txt, either one auto-fills the other
  by matching basename (pick c3po.wav -> loads c3po.txt if present, and vice
  versa); if the counterpart is missing the user picks it by hand.
- POST /config persists to the file; the manager restarts the child when a
  change (voice) needs a model reload, hot-applies when it doesn't (speed).

## App bundle: mirror Otis

Otis is a single SwiftPM binary (WhisperKit is native Swift, no child);
its scripts/bundle.sh hand-assembles Otis.app, signs every build with the
same local identity so TCC grants survive rebuilds, installs via two-rename
swap, and symlinks the bundle binary into ~/.local/bin. Wren gets the same
treatment - same script shape, own logo for app icon + menu bar.

Self-contained launch is a Phase A requirement, not Phase B polish. The
product moment is command-space, "wren", enter - no repo checkout, no
visible uv, no terminal, ever. `uv run` against the repo checkout remains
as a dev mode only, never the user path. Phase B is then only about whether
the Python orchestration layer gets rewritten in Swift, not about
launchability.

Concrete bundle manifest (inventoried 2026-08-04):

- Engine: tts-server is 1.7 MB + five libggml dylibs (base/cpu/blas/metal),
  all @rpath-linked - ship them in Contents/Resources/engine/, fix rpath or
  set DYLD_LIBRARY_PATH when spawning. No .metallib in the build dir, which
  suggests the Metal shader is embedded in libggml-metal (verify: run
  tts-server from a path with no build tree next to it).
- Python: macOS bundles the qwentts backend ONLY - serve.py's needs then
  shrink to soundfile, pedalboard (fx), numpy, stdlib http (sounddevice
  excluded: client playback mode). No mlx-audio, no torch - that's the
  difference between a ~50 MB env and a multi-GB one. MLX stays a dev/Linux
  backend. Provision the env on first run with a bundled uv binary
  (single static file in Contents/Resources) into Application Support;
  serve.py + tts/ support files ship in Resources.
- Models: the two GGUFs are 2.2 GB (talker Q8_0 1.9 GB + tokenizer 278 MB) -
  never in the bundle. First-run download into
  ~/Library/Application Support/voice-ml/models (fetch-models.sh already
  knows the URLs), with a progress UI in the menu bar popover.
- Voices: ref wav+txt pairs live in Application Support/voices; the app
  seeds it with the default voice on first run.

## Ports: scan a range, never double-launch

The app owns the daemon - two daemons must never run. On launch, scan
config port through port+100: a port that answers GET /health already runs
a wren daemon, so connect to it instead of launching; a port that is busy
without answering /health belongs to someone else, so try the next one and
launch there. Clients (wren CLI, extension) discover the daemon by the same
scan.

## Channels: route per utterance, kill the global playback flag

`--playback client` is a design flaw: it decides "who plays" once per
daemon lifetime, when the real answer depends on who asked. Replace it
with per-utterance routing. Each /speak lands in exactly one channel, each
channel has its own queue, and each channel has exactly one player - double
playback becomes structurally impossible.

- Default channel `local`: audio the daemon side plays on its own machine.
  Today that is sounddevice; once Wren.app exists its native player is the
  local channel's output.
- The extension requests its own channel and is the only poller of that
  channel's segment stream; read-page audio, speed, and highlighting stay
  browser-owned.
- Preemption: yell/non-append cuts everything, all channels - one voice per
  machine. (Yell is optional sugar; stop already covers deliberate cuts.)
- Per-channel queues; pause/resume/seek act on the requester's channel.
- The machine queue: per-channel queues hold content; one machine-wide
  playback queue decides whose turn the speakers are, FIFO by arrival at
  segment granularity. An append /speak from a non-playing channel slots
  in: the current speaker finishes only its already-rendered lookahead,
  the newcomer plays, the interrupted channel continues where it stopped
  (behind any later arrivals). Enforced by segment release; clients
  report completion with a played cursor on the poll they already make
  (&played=k), duration + a grace window (> the poll timeout) is the
  dead-client deadline. Explicit pause yields the turn immediately.
  Preemption stays the only queue killer.
- Synthesis lookahead: render at most ~2 segments ahead of the machine
  playhead across all channels; waiting channels hold text, not audio
  (generalizes the pause lookahead; kills the free-running full-page
  render and the memory pileup).
- Speed: multiplicative knobs. Daemon speed (config) stretches all
  channels server-side as today; a client player's own rate multiplies
  on top and never touches daemon config. fx is server-side for all.
- /stop gains an optional channel field; the extension's stop buttons
  stop only the extension channel; bare /stop stays the hammer.

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

Written in Swift, and it IS the app binary - the Otis pattern: one SwiftPM
executable that runs as the menu bar app when launched from Spotlight and
as the CLI when invoked with a subcommand (ArgumentParser), symlinked from
the bundle into ~/.local/bin. One executable, one codebase, one signed
identity. Step 2 starts this binary with just the CLI subcommands (HTTP
client only, no UI); the menu bar app grows in the same executable at step
4.

## Steps

1. ~~Benchmark~~ (done; speed passed, quality comparison pending MLX-8bit).
2. serve.py: config-file support + /config endpoints (+ tests). Benefits
   Linux immediately, freezes the full API before any Swift is written.
3. `wren` scaffold + CLI (first Swift). Scaffold first: SwiftPM package and
   the Otis-style scripts (bundle.sh with local signing so TCC grants
   survive rebuilds, install.sh, dev.sh/watch.sh hot reload, gen-icons) -
   the build/reload story is solved before any interesting code exists.
   Then the CLI subcommands in that package:
   say/stop/pause/resume/status/speed against the finished server API.
4. serve.py channels: per-utterance routing per the Channels section - replaces
   --playback client. Extension updated to request its channel. Essential
   before the Swift app is built against the old semantics.
5. Swift app, player first: the /segment long-poll loop -> AVAudioEngine +
   AVAudioUnitTimePitch with epoch-aware preemption (port offscreen.js's
   scheduling logic) is the core of the app, not an add-on - native audio
   is the reason Swift is here. The app spawns serve.py
   --local-player client from day one (no sounddevice on macOS), /health
   icon, quit-kills-child, LaunchAgent. The player's rate multiplies on
   top of the daemon's config speed.
6. Menu bar controls wired to /config; voice-change restart handling.
7. Install script, doctor.
8. Decide on Phase B only after living with Phase A.
