# Plan: Wren architecture reset

Status: replacement plan, 2026-08-07. This supersedes the original phase-six
menu/config design. It does not discard the working playback system; it
rebuilds management, configuration, voice switching, lifecycle, and macOS UX
around state the product can report honestly.

## Outcome

Wren should feel like a small macOS system service, not a menu wrapped around a
Python process:

- launch from Spotlight and remain available in the menu bar;
- speak reliably through the existing HTTP and segment-stream contracts;
- show the voice and settings that are actually active;
- switch voices without restarting the daemon or unloading the model;
- preserve the previous voice when a switch fails;
- expose one clear speaking-rate control, not two implementation knobs;
- recover visibly from provisioning, engine, persistence, and connection
  failures;
- continue to run as the same Python daemon on Linux, with no Swift dependency.

The menu is a renderer and action surface. It is not a second config engine and
must never infer runtime truth from a saved JSON value.

## Why the original phase-six design is being replaced

The current implementation proved the bundle, player, channels, and menu-bar
shell, but the management architecture has invalid assumptions:

1. `GET /config` mixes persisted intent with effective runtime state. The
   macOS bundle forces `qwentts`, while the endpoint can report `backend: auto`.
2. Voice selection persists a new value, marks it selected, then restarts the
   daemon. The UI presents the desired voice as active before it has loaded.
3. A Boolean `restart_required` loses which setting is pending, what is active,
   who can restart the daemon, and whether a restart succeeded.
4. The Swift controller swallows request and persistence errors, although the
   backend returns `persisted: false` and `persist_error`.
5. A live port change strands the app's immutable client, player, and manager
   on the old endpoint.
6. An adopted daemon cannot be restarted by the app, but the UI offers no
   useful recovery action. Adoption currently accepts any HTTP 200 JSON body as
   Wren identity.
7. Voice discovery and path interpretation are duplicated in Swift and Python.
8. The menu exposes both daemon speed and player rate. Their multiplication is
   an implementation detail, not a coherent user setting.

These are source-of-truth failures. Visual polish on top would make the product
more convincing while leaving it less trustworthy.

## Non-negotiable constraints

- `tts/serve.py` remains the cross-platform daemon. Linux must run it without
  Wren.app.
- The current playback API remains compatible: `POST /speak`, `/stop`,
  `/pause`, `/resume`, `/seek`, `GET /health`, and `GET /segment`.
- Channel routing, machine scheduling, epoch-aware preemption, the played
  cursor, and bounded synthesis lookahead remain intact.
- macOS playback stays in Swift through `AVAudioEngine` and
  `AVAudioUnitTimePitch`; Python never opens the speakers in the app bundle.
- The macOS bundle continues to ship the qwentts engine and provision models
  into Application Support. Backend selection is a build/deployment decision,
  not a menu preference.
- Wren remains one SwiftPM executable: app when launched bare, CLI when invoked
  with a subcommand.
- All persisted writes remain atomic. A failed write is an action failure, not
  a successful response with a warning field the caller may ignore.
- Clean cutover: once every caller uses the replacement management API, remove
  `/config`, `ConfigPayload`, restart-on-config code, and the old menu. Do not
  leave two management contracts.

## Working baseline to preserve

The reset starts from a functioning system:

- the self-contained Wren.app bundle launches without a checkout or terminal;
- first run provisions a small Python environment and downloads the two GGUFs;
- `serve.py` starts `tts-server`, streams PCM, and serves immediately while the
  model loads;
- Wren.app owns the local `/segment` player and reports played cursors;
- browser extension audio remains isolated in its own channel;
- pause, resume, stop, preemption, seek, and machine-wide scheduling work;
- the CLI reaches local or explicit remote daemons;
- the app can own a child or connect to an already-running daemon;
- the existing Python and Swift contract suites pass.

Playback is not rewritten as part of this plan unless a state invariant below
requires a narrow change.

## Product invariants

1. **Active means usable now.** A voice is active only after its conditioning
   is prepared and new utterances can synthesize with it.
2. **Selection is transactional.** A failed voice change leaves the old voice
   active, selected, and persisted.
3. **Every mutation has an outcome.** Pending, success, failure, and recovery
   are observable. User-triggered errors are never swallowed.
4. **One owner per datum.** Daemon synthesis settings, native player settings,
   lifecycle settings, and deployment settings have different owners and are
   not forced into one JSON object.
5. **Queued work is deterministic.** Each accepted utterance captures its
   voice, effects, and daemon-side rate. Later setting changes affect future
   utterances, not already accepted work.
6. **Local rate is immediate.** The menu's Speaking Rate controls the native
   player and may affect audio already playing. Per-request daemon stretch
   remains an API feature.
7. **Ownership is explicit.** Managed and connected daemons expose different
   lifecycle actions. The app never kills or restarts a process it did not
   spawn.
8. **Identity precedes adoption.** A JSON response is not sufficient. The app
   connects only to a compatible Wren protocol endpoint.
9. **The last good state is recoverable.** Startup and activation failures
   retain enough information to retry, choose another voice, or restore the
   previous persisted state without hand-editing files.

## System boundaries

```text
WrenMenuBar / SettingsWindow
  renders AppState; sends UserAction
                │
                ▼
WrenStore (@MainActor)
  combines manager state + daemon state + local player state
  serializes actions; owns visible operation/error state
       │                 │                    │
       ▼                 ▼                    ▼
DaemonManager       DaemonClient         SegmentPlayer
process ownership   /meta /state         AVAudioEngine
provisioning        /voices /settings    rate + output device
restart policy      playback actions     local activity
       │                 │
       └────────┬────────┘
                ▼
serve.py
  HTTP, voice registry, active synthesis context,
  durable daemon settings, queues, engine adapter
                │
                ▼
resident synthesis engine (qwentts in Wren.app; selectable on Linux/dev)
```

### Python daemon owns

- protocol identity and capabilities;
- voice registry and voice-file validation;
- prepared voice contexts and the active voice;
- effects and daemon-side default synthesis settings;
- atomic persistence of daemon product settings;
- synthesis, channels, queues, and playback protocol state;
- effective backend/model/bind information reported from actual launch values.

### Swift manager owns

- provisioning the bundled environment, engine, models, and seeded voice;
- spawning, supervising, and terminating only its own daemon child;
- endpoint connection and compatibility validation;
- native playback, local Speaking Rate, and output-device preference;
- launch-at-login through `SMAppService`;
- voice import UI and local file copying before daemon validation;
- the combined application state shown to the user.

### Menu and settings UI own

- no durable truth;
- no filesystem voice scan;
- no restart inference;
- no optimistic active selection.

They render `AppState` and issue typed actions to `WrenStore`.

## Settings taxonomy and sources of truth

| Domain | Examples | Owner | Storage | Runtime mutation |
|---|---|---|---|---|
| Daemon product | active voice, effects, default synthesis rate | `serve.py` | atomic daemon settings file | management API |
| Native player | Speaking Rate, output device | Wren.app | `UserDefaults` keyed by stable device UID | immediate in Swift |
| Lifecycle | launch at login | macOS | `SMAppService` | native API |
| Deployment | backend, model, host, port, token, voices directory | launcher/service | bundle manifest, CLI/env/service config | restart whole session; never menu config |
| Playback | queue, speaking, paused, current channel | daemon + player | ephemeral | playback API |

The existing `config.json` migrates to a versioned daemon product-settings
file containing only values the daemon owns, for example:

```json
{
  "schema_version": 2,
  "active_voice": "c3po_god",
  "effects": true,
  "default_synthesis_rate": 1.0
}
```

`backend`, `port`, and `voices_dir` are no longer writable product settings.
The app bundle supplies them at launch; Linux/dev supplies them through explicit
launch configuration. CLI overrides are reported as effective launch sources
and are never written into product settings.

Migration reads the old file once, validates the referenced voice, maps `fx`
and `speed`, writes schema v2 atomically, and keeps a one-time backup until the
new daemon has reached ready. An invalid old file produces a recoverable startup
state with Reset and Reveal Config actions; it does not enter a crash loop.

## Voice library layout

Schema v2 stores each voice as one atomically movable profile directory rather
than two unrelated flat files:

```text
voices/
  c3po_god/
    profile.json       # id, display name, schema version
    reference.wav
    transcript.txt
  .staging/
    <operation-id>/    # never returned by GET /voices
```

The daemon accepts only bare stable IDs, resolves every file inside the library,
and owns profile validation. Existing `<name>.wav` + `<name>.txt` pairs migrate
into profile directories through staging; incomplete pairs remain visible as
recoverable migration errors and are never selectable. Profile display names
may change; IDs stay immutable so queues, settings, and cached backend
registrations keep stable references.

Import stages a complete directory, validates it through the daemon, then
renames the directory into place as the commit. Delete rejects the active voice.
Rename changes display metadata only. These rules make failed import and process
crash incapable of exposing half a voice.

## Daemon state model

`/health` remains the lightweight playback/liveness compatibility endpoint.
It is not the menu's product model. The replacement management API exposes a
single coherent daemon snapshot with a monotonic revision.

```json
{
  "revision": 42,
  "lifecycle": {
    "phase": "ready",
    "message": null
  },
  "synthesis": {
    "ready": true,
    "active_voice": "c3po_god",
    "effects": true,
    "default_synthesis_rate": 1.0,
    "backend": "qwentts",
    "model": "qwen-talker-1.7b-base-Q8_0"
  },
  "operation": null,
  "playback": {
    "pending": 0,
    "speaking": false,
    "paused": false
  },
  "last_error": null
}
```

Allowed lifecycle phases are `starting`, `loading`, `ready`, `degraded`, and
`failed`. The Swift manager adds its own `provisioning`, `connecting`, and
`stopped` phases because those can exist before an HTTP daemon does.

An operation is explicit rather than inferred from value drift:

```json
{
  "id": "8A8E...",
  "kind": "activate_voice",
  "phase": "preparing",
  "target": "wintermute",
  "progress": null,
  "error": null
}
```

Only one state-changing daemon operation runs at a time. A competing mutation
returns `409` with the active operation. Repeating the same request ID is
idempotent and returns the existing/final result.

## Management API v2

The playback endpoints stay unversioned and compatible. The management surface
is replaced as a unit:

### `GET /meta`

Identity and compatibility handshake, available as soon as HTTP binds:

```json
{
  "service": "wren",
  "protocol_version": 2,
  "instance_id": "7D21...",
  "started_at": "2026-08-07T01:00:00Z",
  "capabilities": [
    "state-v2", "voice-list", "voice-activate", "settings-v2",
    "segment-player"
  ]
}
```

The app adopts/connects only when `service`, protocol compatibility, and
required capabilities match.

### `GET /state`

Returns the snapshot above. It is safe during model loading. The menu refreshes
from it on open and while an operation is active; the normal background poll
also updates it.

### `GET /voices`

Returns daemon-validated profiles, never a Swift directory scan:

```json
{
  "revision": 9,
  "voices": [
    {
      "id": "c3po_god",
      "display_name": "C-3PO",
      "active": true,
      "status": "ready"
    },
    {
      "id": "wintermute",
      "display_name": "Wintermute",
      "active": false,
      "status": "ready"
    }
  ]
}
```

Invalid/incomplete pairs are returned with a specific status in the management
window or excluded from the quick picker, but never silently treated as active.

### `POST /voices/activate`

Body: `{ "voice": "wintermute", "request_id": "..." }`.

Returns `202` with the operation. The operation prepares the new voice while
the old voice remains active. Success changes `active_voice` and the settings
revision together. Validation/preparation/persistence failure records an error
and leaves the old voice active and durable.

### Voice-library mutations

- `POST /voices/import` accepts a staging operation ID, stable voice ID, and
  display name. The daemon resolves the staging directory under its configured
  library, validates it, and commits it by directory rename. Arbitrary file
  paths and remote uploads are rejected.
- `PATCH /voices/{id}` changes display metadata only; the stable ID and audio
  conditioning identity do not change.
- `DELETE /voices/{id}` removes an inactive profile and returns `409` for the
  active voice or a profile captured by queued work.

These endpoints are advertised only when the daemon and manager share the local
voice library. Connected/remote clients without that capability may list and
activate existing voices but cannot import or mutate files.

### `PATCH /settings`

Typed partial mutation for daemon-owned hot settings only. It validates the
complete merged settings, persists atomically, applies, and returns the new
state. Persistence failure returns non-2xx and does not apply the mutation.
Unknown and deployment-only keys are rejected.

### Error contract

Every management error has a stable code and user-safe message:

```json
{
  "error": {
    "code": "voice_transcript_missing",
    "message": "Wintermute needs a transcript file.",
    "detail": "...",
    "recoverable": true
  }
}
```

The UI keys behavior off `code`, displays `message`, and sends `detail` to logs.

## Transactional voice architecture

Voice is synthesis context, not process configuration. Switching it must not
restart `serve.py`, `tts-server`, the HTTP listener, queues, or native player.

Introduce a backend-neutral `VoiceContext` and an atomic active-context
reference:

1. Resolve the profile inside the daemon-owned voice library.
2. Validate WAV readability, transcript content, and safe ID.
3. Prepare backend-specific conditioning without touching the active context.
4. Atomically persist the new active voice. This is the operation commit point.
5. Swap the prepared context into the active reference; this final pointer swap
   must be non-failing.
6. Publish a new state revision and complete the operation.

Crash semantics are defined around the commit point. Before commit, restart
loads the old voice. After commit, restart loads the new voice even if the
process died before publishing operation success.

Backend adapters:

- **qwentts:** keep the model/codec child resident; register the candidate under
  a content-derived voice key, then select that key for new synthesis calls.
  Cache registrations with a bound so repeated switching does not grow without
  limit.
- **MLX:** load reference audio and precompute/cache speaker conditioning where
  supported, then swap the immutable context used by new calls.
- **torch qwen-tts:** validate and capture the new reference inputs; the resident
  model remains loaded and each generation receives the captured context.

At `/speak` acceptance, the queued utterance captures the current
`VoiceContext`, effects, and daemon-side rate. A voice switch does not change
already queued or in-flight utterances. The response/state should make that
future-utterance boundary clear; switching voice is not an implicit Stop.

## Endpoint and lifecycle policy

Do not scan a port range. Silent scanning makes clients, the extension, and the
manager disagree about the endpoint.

On app launch:

1. Resolve one endpoint from explicit launch configuration, default `8765`.
2. Probe `GET /meta` on that exact endpoint.
3. Compatible Wren: enter `connected` mode and never claim process ownership.
4. Connection refused: provision if needed, spawn a managed child, and retain
   the process handle.
5. Occupied by a non-Wren or incompatible service: enter a visible failure
   state with endpoint detail; never scan or double-launch.

`port` is not mutable through the live management API or menu. An advanced
deployment change restarts the entire Wren session and reconstructs
`DaemonClient`, `DaemonManager`, and `SegmentPlayer` together.

Managed child policy:

- deliberate restarts and unexpected exits are distinct events;
- unexpected exits use bounded backoff and a circuit breaker;
- the last error and log path are part of manager state;
- Retry, Reveal Logs, and Reset Invalid Settings are explicit recovery actions;
- Quit stops only a managed child;
- connected mode labels itself and never offers restart/quit-daemon actions.

Voice switching and hot settings never invoke this lifecycle path.

## Swift application model

Replace callback wiring in `AppController` with one `@MainActor` `WrenStore`.
It owns an immutable `AppState` assembled from:

- manager phase and ownership (`managed` or `connected`);
- latest compatible daemon state and voice list revisions;
- local player activity, Speaking Rate, and output device;
- launch-at-login state;
- the user action currently being submitted;
- the last actionable error.

`WrenStore` exposes typed actions such as:

- `activateVoice(id:)`
- `setEffects(_:)`
- `setSpeakingRate(_:)`
- `setOutputDevice(uid:)`
- `togglePause()`
- `stopSpeaking()`
- `setLaunchAtLogin(_:)`
- `retryStartup()`
- `importVoice(wav:transcript:name:)`

Each action serializes conflicting work, updates pending presentation state,
performs the owner-specific mutation, then reconciles from authoritative state.
Network errors become visible `AppState` values. A late response with an older
revision cannot overwrite newer state.

`WrenMenuBar` becomes a pure AppKit renderer plus action emitter. Rebuild the
menu in one path on every open, as Otis does. Do not mutate persistent menu rows
from scattered callbacks.

## macOS information architecture

Keep a native `NSMenu`. Apple-esque means native hierarchy, restrained custom
rows, system terminology, and honest state feedback—not a bespoke glass
popover.

Normal state:

```text
Ready · C-3PO
────────────────────────
Voice                         C-3PO  ›
Speaking Rate                 1.50×
Effects                              ✓
Output                MacBook Speakers  ›
────────────────────────
Pause
Stop Speaking
────────────────────────
Launch at Login                    [switch]
Settings…
Quit Wren
```

Rules:

- The top row is a non-highlighting custom status view so long text does not
  widen native title/badge columns.
- Voice, Output, and other infrequent selectors use submenus with current-value
  badges and native checkmarks.
- Speaking Rate is the only visible speed control. It controls the local native
  player, persists in `UserDefaults`, and updates immediately.
- Pause and Stop are enabled only when playback is active; Pause becomes Resume.
- Effects is daemon-global and says so in Settings help text. It is not applied
  optimistically.
- Launch at Login re-reads `SMAppService` on every menu open.
- Native SF Symbols and secondary text follow Otis's established menu treatment.
- The menu refreshes authoritative state before/rebuilding for open where
  practical, then updates in place without changing layout while open.

Voice submenu:

```text
✓ C-3PO
  Wintermute
────────────────────────
  Add Voice…
  Manage Voices…
```

During activation the checkmark stays on the active voice. The status row says
`Switching to Wintermute…`; conflicting voice actions are disabled. On failure:
`Couldn't load Wintermute · Still using C-3PO`. That message remains until the
next relevant action or dismissal.

First run uses the same surface:

- `Preparing Wren…`
- `Downloading voice model… 37%` with a stable progress row;
- `Loading voice model…`;
- `Ready · C-3PO`.

Connected mode says `Connected · C-3PO` and exposes only capabilities supported
by the remote/external daemon. Local voice import and lifecycle recovery are
hidden or disabled with a specific explanation.

Fatal/recoverable states use actions, not inert prose:

```text
Wren couldn't start
Port 8765 is used by another application.
────────────────────────
Retry
Open Settings…
Reveal Logs
Quit Wren
```

## Settings and voice management window

The menu stays short. A native Settings window owns lower-frequency work:

- voice library with active, ready, incomplete, and invalid status;
- Add Voice flow: choose WAV and transcript; choosing either auto-fills a
  same-basename counterpart; preview the final name; resolve collisions;
- delete/rename rules, never allowing deletion of the active voice without
  first activating another;
- output device details and fallback-to-system-default behavior;
- daemon connection/ownership, effective backend/model, endpoint, protocol
  version, and log location as read-only diagnostics;
- recovery actions for invalid migrated config or failed provisioning.

Voice import copies a complete profile into the library's `.staging` directory,
then calls the daemon's import operation. The daemon validates and atomically
renames it before it becomes selectable. Failure removes the staging directory
and leaves no partial profile. Remote upload is not part of this redesign.

Output devices are enumerated by Swift. Persist stable Core Audio UID, retain a
disconnected selection visibly, and fall back audibly to system default with a
warning rather than silence. Device changes do not touch daemon settings.

## CLI cutover

Retain playback commands:

```text
wren say "hello"
wren say --append "next"
wren yell "now"
wren pause | resume | stop
wren status
```

Replace generic config mutation with explicit product commands:

```text
wren voices
wren voice use wintermute
wren effects on|off
wren state --json
```

`wren status` reads `/meta` and `/state`, naming effective voice, backend,
ownership-neutral daemon phase, playback, and an active operation. Explicit
remote `--host`/`WREN_HOST` remains supported. Deployment settings stay launch
arguments or service configuration and are never sent to a running daemon.

After the Swift app and CLI migrate, delete `wren config`, `wren speed` as a
global menu-setting analogue, `/config`, and their wire models/tests. If a
daemon-side default synthesis-rate command remains useful, name it explicitly
instead of calling it player speed.

## Delivery phases

Each phase has an observable exit gate. Passing a unit test while the product
still lies is not completion.

### Phase 0 — freeze the working baseline

- Record black-box fixtures for the existing playback endpoints and segment
  protocol.
- Add process-level smoke coverage for current app launch, local segment
  playback, pause/resume/stop, and clean quit.
- Capture the old config migration cases before changing the schema.

Exit: playback behavior is pinned independently of management internals.

### Phase 1 — synthesis context and transactional voice core

- Introduce `VoiceProfile`, backend-neutral `VoiceContext`, registry, and atomic
  active-context reference.
- Make queued utterances capture voice/effects/rate at acceptance.
- Implement prepare/commit/rollback and crash semantics for qwentts first, then
  MLX and torch adapters.
- Keep the resident model and qwentts child alive across successful and failed
  switches.

Exit: an integration test switches A → B → A while speaking; old queued work
uses its captured voice, new work uses the committed voice, and injected
validation/registration/persistence failures leave A active without restarting
HTTP or the engine.

### Phase 2 — management API v2 and schema migration

- Add `/meta`, `/state`, `/voices`, voice activation/library mutations, and
  `/settings`.
- Make state available during model loading and failures.
- Add revisions, idempotent operation IDs, structured errors, and `409` busy.
- Migrate old config to versioned daemon product settings atomically.
- Report effective backend/model/endpoint from resolved launch values.

Exit: black-box API tests cover every state transition and failure injection;
the live macOS bundle reports `qwentts` when launched with qwentts.

### Phase 3 — Swift lifecycle and state store

- Add strict `/meta` handshake and exact-endpoint policy.
- Replace `AppController` callback state with `WrenStore` and typed actions.
- Reconstruct all endpoint-bound components together on a deployment endpoint
  change/relaunch.
- Surface request, decode, persistence, child-exit, and compatibility errors.
- Preserve managed versus connected ownership in every lifecycle action.

Exit: reducer/integration tests prove stale responses cannot win, connected
daemons are never killed, non-Wren port occupation is visible, and child crash
recovery reaches either ready or a bounded actionable failure.

### Phase 4 — caller migration and old-contract deletion

- Move the Swift store and CLI to management API v2.
- Confirm the extension has no management dependency; migrate any discovered
  caller explicitly.
- Delete `/config`, `Config`, `ConfigPayload`, generic config CLI mutation,
  `restart_required`, Swift voice scanning, and restart-on-voice code.
- Remove backend/port from mutable product settings.

Exit: repository search finds no old management caller or compatibility shim;
all playback and new management suites pass.

### Phase 5 — native menu redesign

- Port Otis's rebuild-on-open, status-row, badge, checkmark, symbol, and
  persistent-error patterns.
- Implement the normal, playback, activation, provisioning, connected, and
  failure layouts above.
- Remove the second visible rate control and implementation terminology.

Exit: run the installed app and exercise every menu state against a real daemon;
the selected voice always matches `/state.synthesis.active_voice`, including
while activation is pending or failed.

### Phase 6 — settings, voice import, output, and login

- Add the Settings/voice-management window, profile-directory migration, staged
  import, metadata rename, and guarded delete flows.
- Add output-device selection, disconnect fallback, and visible warning.
- Add the Otis-style `SMAppService` launch-at-login row.
- Finish actionable provisioning/config/log recovery.

Exit: import and activate a new voice without restarting; reject incomplete and
corrupt imports without residue; unplug the selected output and still hear
audio through fallback; external login-item changes appear on next menu open.

### Phase 7 — release hardening

- Update `doctor` for protocol identity, migrated settings, voice registry,
  engine/model assets, output device, endpoint conflict, and login item.
- Exercise bundle install/update over existing old and new configs.
- Run full Python, Swift, extension, and installed-app smoke verification.
- Remove temporary migration backups only after a confirmed successful launch.

Exit: a clean machine and an upgraded existing installation both reach Ready
without a terminal; all failure scenarios below have been observed, not merely
mocked.

## Verification matrix

### Voice and persistence

- valid A → B activation;
- missing WAV, missing transcript, corrupt WAV, unsafe ID;
- qwentts registration failure;
- settings directory unwritable/disk-full injection;
- daemon crash before and after operation commit;
- rapid A → B then B → C requests and duplicate request IDs;
- activation while old-voice work is queued and speaking.

### Lifecycle and identity

- empty port spawns one child;
- compatible Wren endpoint enters connected mode;
- unrelated JSON service and incompatible protocol fail visibly;
- managed child crash/backoff/circuit breaker;
- Quit kills managed child only;
- provisioning download and model-load failure with Retry;
- endpoint deployment change reconstructs client, manager, and player together.

### Native playback and settings

- Speaking Rate changes current local playback without changing daemon config;
- extension/client rates remain independent;
- pause/resume/stop stay channel-correct;
- output-device switch, disconnect, and system-default fallback;
- Launch at Login reflects `SMAppService` after external changes.

### UX truthfulness

- menu checkmark equals active voice at rest, during activation, and on failure;
- loading target is named without replacing the active checkmark;
- persistence and network errors remain visible with recovery actions;
- connected mode never offers ownership-only actions;
- state rows do not resize or flicker the menu during progress updates.

## Explicit non-goals

- Rewriting `serve.py` or the HTTP server in Swift.
- Replacing qwentts.cpp or re-running model quality benchmarks.
- Redesigning channel scheduling, extension highlighting, or page-reading UX.
- Remote voice-file upload or multi-machine library synchronization.
- An auto-update framework.
- A general web settings UI.
- Runtime backend/model/host/port mutation from the menu.
- Preserving `/config` as a deprecated compatibility layer after cutover.

## Later decision: native Swift server

Only reconsider a native macOS synthesis server after this architecture ships
and the Python child is proven to be the remaining product problem. The parity
gate is behavioral: the replacement must satisfy the playback protocol,
management state, transactional voice, persistence, and failure-injection suites
without changing the Swift menu or CLI contract.
