# Plan: Wren architecture reset

Status: implementation handoff, observed 2026-08-11. Core daemon,
management, Swift lifecycle, caller cutover, native menu and Settings
interaction, and deterministic release gates are implemented and verified.
External login-item refresh and hardware-dependent exit gates remain.

## Handoff checkpoint

Completed and observed:

- `uv run pytest tts/test_serve.py -q`: 216 passed.
- `swift test --package-path daemon`: 179 passed, with one intentional
  opt-in installed-app test skipped. The release executable built without
  warnings.
- `scripts/check-release.sh`: clean, upgrade, post-Ready, and invalid-update
  checks passed.
- All 11 files under `extension/**/*.js` passed `node --check`. All 26 Swift
  source files satisfy the 80-column limit, and logo generation is
  byte-idempotent.
- A signed candidate bundle passed the expanded `scripts/smoke-installed.sh`:
  connected adoption and ownership, segment playback, pause/resume/stop,
  wrong-token endpoint conflict, surfaced settings persistence failure,
  degraded-engine rejection, and clean quit.
- Isolated real-process probes against that signed bundle observed an
  actionable provisioning failure with Retry, atomic rollback after an
  unwritable settings directory, real qwentts child exit with
  `engine_child_exited`, durable `c3po_god` selection, explicit synthesis
  rejection, and clean managed descendant teardown.
- Installed defects found during the first native pass were fixed: Core Audio
  now accepts input-only zero-buffer configurations, staged import sends a
  valid 32-character ID, CLI symlinks resolve the exact Wren bundle resources,
  and an exact app bundle can register from initial `SMAppService.notFound`.
- The verified candidate is installed at `~/Applications/Wren.app` and is
  running. Its exact `127.0.0.1:8765` daemon is protocol v2, lifecycle
  `ready`, backend `qwentts`, active voice `c3po_god`, effects enabled, and
  daemon synthesis rate `1.4`. Only `c3po_god` remains in the library;
  `.staging` and `.trash` are empty.
- Installed `wren doctor`, `status`, and `voices` report local assets ready,
  MacBook Pro Speakers as the effective System Default output, and the
  authoritative daemon state. Managed say, pause, resume, and stop produced
  the expected playback transitions. Physical acoustic audibility was not
  directly observed.
- The native menu and all three Settings tabs were inspected. An in-process
  AppKit driver exercised the real Voices table selection and its Use Voice,
  Save Name, restore, and Delete controls against the installed daemon.
- The Add Voice sheet imported `trump-cut`. During activation, the daemon
  remained active on `c3po_god` in nonterminal `preparing`; Settings showed
  `c3po_god` active and `trump-cut` as `Switching…`, while the menu said
  `Switching to Trump Cut` and checked only `c3po_god`. Activation, rename,
  restore, and deletion then completed. A missing-voice failure again left
  only daemon-reported `c3po_god` marked. The app, daemon, and qwentts PIDs
  and daemon instance stayed unchanged, followed by full profile cleanup.
- The probe-only driver was removed. The preserved focused Settings controller
  suite passed 2 tests.
- A saved nonexistent output UID produced the installed fallback presentation:
  Desired `Disconnected Probe (Disconnected)`, Effective MacBook Pro Speakers,
  a visible warning, and successful native playback state. Selecting System
  Default in Wren cleared the preference and warning. Physical hot-unplug is
  not observed because this machine exposes only MacBook Pro Speakers.
- Native Launch at Login registration succeeded (`SMAppService` status
  `enabled`) and native unregistration succeeded (`notRegistered`); the final
  Wren checkbox is off. System Settings previously showed the Wren application
  row, but its switch was not exposed to Accessibility. A later pass opened
  Login Items but exposed only sidebar categories, no Wren row, switch, or
  usable geometry, and display capture was unavailable. No external toggle or
  menu-refresh claim is made.
- The existing legacy installation remains migrated to schema-v2
  `settings.json` and `voices/c3po_god/`; legacy config and flat voice sources
  were retired only after Ready.

No subagents or background jobs remain. The working tree is intentionally
uncommitted; do not reset or discard it.

Next instance, continue in this order:
Before doing the numbered work, confirm `~/.omp/agent/config.yml` maps
`modelRoles.task` to `openai-codex/gpt-5.6-luna`. Use `task` subagents for
independent slices with the `agent` field omitted. `luna` is a model role, not
a valid task-agent type; passing `agent: "luna"` fails preflight.

1. Use a human pointer interaction or display-capable UI driver to toggle Wren
   externally in System Settings > General > Login Items. Reopen the Wren menu
   and verify its checkbox refreshes. Leave the item disabled.
2. If a second physical output device is available, select it, disconnect it,
   confirm audible fallback to System Default, and reconnect it. Also obtain a
   human acoustic confirmation of native playback.
3. If any source changes are needed for those checks, rerun Python, Swift,
   release, extension, staged-bundle, and installed-app verification. Then
   mark Native menu, Native settings, and Release hardening complete and
   replace this handoff status with the final observed release status.

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
5. **Acceptance is linearizable.** Each accepted utterance carries one immutable
   synthesis snapshot containing its `VoiceContext`, effects, and daemon-side
   rate. Later setting or voice commits affect future snapshots, not accepted
   work, and backlog coalescing never crosses a snapshot boundary.
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
- effective backend/model/bind information reported from actual launch values;
- adapter execution ownership, including serialized engine preparation and
  control work.

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

`--initial-voice` is launch-only recovery input, not mutable product
configuration. It resolves a stable voice ID only when v2 settings has no
`active_voice`; an existing durable selection always wins.

Migration first completes legacy voice-profile migration as described below.
Only then does it read the old file once, validate `voice` against a ready
profile, map `fx` and `speed`, and write schema v2 atomically. The old config
and legacy voice sources remain as migration backups through the first Ready;
Phase 7 release cleanup removes them. An invalid old file or voice migration
error produces a recoverable startup state with Reset and Reveal actions; it
does not write settings that reference an unready profile or enter a crash
loop.

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
  .trash/
    <operation-id>/
```

The daemon accepts only bare stable IDs, resolves every file inside the library,
and owns profile validation and metadata. On upgrade it considers each legacy
`<name>.wav` plus `<name>.txt` pair before validating schema-v2 settings. For
each complete, noncolliding pair, it copies both sources into an
operation-specific `.staging` directory, writes and validates `profile.json`,
then commits the complete profile with a same-filesystem atomic rename. It
retains the original flat files through the first Ready as migration backups;
Phase 7 release cleanup removes them.

Incomplete pairs and IDs that collide with an existing profile or another
legacy candidate remain untouched. Migration never overwrites, chooses a
different ID, or changes the active selection implicitly. The authoritative
voice-library and state contract reports a recoverable error naming the
affected ID or files. No `.staging` entry is ever selectable or returned as a
voice.

Swift stages import source files only when it owns the managed daemon or
otherwise verifies access to that daemon's exact configured local library;
an advertised capability alone is insufficient proof. The daemon validates the
requested stable ID and display name, rejects collisions, writes and validates
the authoritative profile metadata, then commits with a same-filesystem atomic
rename. Import failure removes the operation's staging directory before the
operation completes and never exposes a partial profile. Display-name changes
rewrite profile metadata by atomic file replacement; stable IDs and
conditioning identity do not change.

Deletion rejects the active voice and any profile captured by queued or
in-flight work. It commits by atomically renaming the complete profile to
`.trash/<operation-id>` on the same filesystem, then publishes the voice-library
revision. The profile disappears from the library as one operation; recursive
cleanup runs afterward and resumes on daemon startup. A rename failure leaves
the original profile intact and returns an action failure. Neither `.staging`
nor `.trash` entries are returned by `GET /voices`.

## Daemon state model

`/health` remains the lightweight playback/liveness compatibility endpoint.
It is not the menu's product model. The replacement management API exposes one
coherent daemon snapshot.

```json
{
  "revision": 42,
  "voices_revision": 9,
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

`revision` is the `/state` revision. `voices_revision` identifies the newest
`/voices` snapshot that belongs with the state. Each is monotonic only within
one `/meta.instance_id`; they are separate domains and are never compared with
each other or with values from another daemon instance.

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

Every state-changing v2 request requires an `Idempotency-Key` header. Its value
is the operation ID used by state and result lookup. Only one state-changing
daemon operation runs at a time; a competing mutation returns `409` with the
active operation. Repeating the same key for the same method, target, and
canonical body returns the existing or final result. Reusing that key for a
different mutation returns `409 request_id_conflict`.

## Management API v2

The playback endpoints stay unversioned and compatible. The management surface
is replaced as a unit. Every v2 route inherits the existing bearer-token and
Origin enforcement, including `/meta`; none is an unauthenticated exception.

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
    "staged-import", "segment-player"
  ]
}
```

The app adopts/connects only when `service`, protocol compatibility, and
required capabilities match.

### `GET /state`

Returns the snapshot above. It is safe during model loading. The menu refreshes
from it on open and while an operation is active; the normal background poll
also updates it.

### `GET /operations/{request_id}`

Returns the active or completed operation result, including its terminal
response or structured error. The daemon retains every completed result for the
full lifetime of the current `/meta.instance_id`, so an ambiguous mutation can
be resolved before the client retries the same ID and payload.

An ID unknown to the current instance returns `404 operation_result_unknown`.
Operation results, idempotency records, and lookups are scoped to that
`instance_id` and are discarded when the daemon exits. A new instance never
resolves or deduplicates a prior instance's key; clients reconcile `/state` and
`/voices` after the instance changes.

### `GET /voices`

Returns every profile discovered by the daemon, never a Swift directory scan:

```json
{
  "revision": 9,
  "voices": [
    {
      "id": "c3po_god",
      "display_name": "C-3PO",
      "status": "ready",
      "issues": []
    },
    {
      "id": "wintermute",
      "display_name": "Wintermute",
      "status": "incomplete",
      "issues": [
        {
          "code": "voice_transcript_missing",
          "field": "transcript",
          "message": "Wintermute needs a transcript file."
        }
      ]
    }
  ]
}
```

`ready`, `incomplete`, and `invalid` are stable status values; issue `code` and
`field` are stable machine-readable data. Incomplete and invalid profiles stay
visible in voice management. The quick picker filters them out and reads its
checkmark only from `/state.synthesis.active_voice`; voice entries never carry
an `active` field.

### `POST /voices/activate`

Header: `Idempotency-Key: <request-id>`. Body: `{ "voice": "wintermute" }`.

Returns `202` with the operation. The operation prepares the new voice while
the old voice remains active. Success changes `active_voice` and the `/state`
revision together. Validation, preparation, or persistence failure records an
error and leaves the old voice active and durable.

### Voice-library mutations

- `POST /voices/import` accepts a staging directory ID, distinct from the
  required `Idempotency-Key`, plus a stable voice ID and display name. The
  daemon resolves the staging directory under its configured local library,
  validates the requested ID and name, writes and validates the authoritative
  profile metadata, and commits by same-filesystem directory rename. Arbitrary
  paths, remote uploads, and collisions are rejected.
- `PATCH /voices/{id}` changes display metadata by atomic file replacement;
  the stable ID and audio conditioning identity do not change.
- `DELETE /voices/{id}` returns `409` for the active voice or a profile captured
  by queued or in-flight work. Otherwise it commits by same-filesystem rename to
  `.trash/<operation-id>`, publishes the new voice revision, and removes the
  trash contents asynchronously with startup recovery.

The daemon always advertises `staged-import` when that support is implemented;
this says nothing about a client's filesystem access. Swift exposes import and
mutation UI only with proven access to the same configured local library.
Listing and activation remain gated by their protocol capabilities, not shared
filesystem access.

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
  Use a soft 16-entry LRU of registered content-derived keys. Pin every
  registration held by a preparing activation, the active context, or queued or
  in-flight work. Preparation acquires its pin before the registration becomes
  evictable and holds it through either the active-context swap or rollback.
  Pinned entries may temporarily push the cache above 16. After references are
  released, evict least-recently-used unpinned entries until the cache returns
  to 16; remove an engine registration only after its last reference is
  released.
- **MLX:** load reference audio and precompute/cache speaker conditioning where
  supported, then swap the immutable context used by new calls.
- **torch qwen-tts:** validate and capture the new reference inputs; the resident
  model remains loaded and each generation receives the captured context.

At `/speak` acceptance, atomically capture one immutable `SynthesisSnapshot`
containing the current `VoiceContext`, effects, and daemon-side rate. Acceptance
is serialized with voice and settings commits, and every queue item carries
that snapshot through synthesis. Work appended after a voice or setting commit
gets the new snapshot; backlog coalescing may combine work only within one
snapshot and stops at every snapshot boundary. A switch does not change already
queued or in-flight utterances and is not an implicit Stop.

Backend preparation and control work must execute through the adapter's
engine-owning executor. In particular, qwentts registration, selection, and
removal are serialized with engine calls there. MLX preparation remains on the
worker thread that owns its thread-local model rather than being dispatched to
an unrelated control thread.

## Endpoint and lifecycle policy

Do not scan a port range. Silent scanning makes clients, the extension, and the
manager disagree about the endpoint.

On app launch:

1. Resolve one endpoint from explicit launch configuration, default `8765`.
2. Probe `GET /meta` on that exact endpoint with the configured bearer token
   and no `Origin` header.
3. Missing or incorrect token (`401`): enter a visible authorization failure;
   never adopt the process, scan, or spawn a competing child. An unexpected
   Origin rejection is likewise an access failure, not an identity result.
4. Compatible Wren: enter `connected` mode and never claim process ownership.
5. Connection refused: provision if needed, spawn a managed child, and retain
   the process handle.
6. Authenticated non-Wren identity or incompatible protocol/capabilities: enter
   the corresponding visible failure with endpoint detail; never scan or
   double-launch.

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

A post-ready qwentts child exit is a daemon engine failure, not a healthy idle
state. The daemon publishes lifecycle `degraded` with an actionable engine
error, marks synthesis not ready, fails new `/speak` requests with an explicit
engine-unavailable error, and preserves the active durable voice. In managed
mode, Retry may restart only the daemon process Wren.app spawned. Connected
mode exposes the failure without a process action; on Linux, recovery remains
with the service manager or operator.

## Swift application model

Replace callback wiring in `AppController` with one `@MainActor` `WrenStore`.
It owns an immutable `AppState` assembled from:

- manager phase and ownership (`managed` or `connected`);
- current daemon `instance_id`, independently revisioned state and voices;
- local player activity, Speaking Rate, and output device;
- launch-at-login state;
- the user action currently being submitted;
- staged-import availability derived from capability plus proven library access;
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
After an ambiguous mutation response, it reads the operation result before
retrying the same request ID and payload. Unknown results and network errors
become visible `AppState` values.

`WrenStore` keeps separate revision gates for `/state` and `/voices`. A late
response can update only its own domain and only within the current
`/meta.instance_id`. On an instance change, the store clears both gates and
instance-bound operation state, then reloads both resources; it never compares
revisions across domains or daemon instances.

The daemon's `staged-import` capability says only that the protocol is
supported. Swift enables staged import only when it owns the daemon or otherwise
proves access to the same configured local voice library. A server cannot infer
shared filesystem access from a client connection.

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

Connected mode says `Connected · C-3PO` and exposes only supported
capabilities. Voice import and mutation appear only with staged-import support
and proven access to the exact local library. Lifecycle recovery remains hidden
or disabled because the app does not own the process.

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

- voice library whose selected row comes only from
  `/state.synthesis.active_voice`, with ready, incomplete, and invalid profiles
  plus recoverable migration errors;
- Add Voice flow: choose WAV and transcript; choosing either auto-fills a
  same-basename counterpart; preview the final name and stable ID; reject
  collisions until the user chooses a different ID, without overwriting or
  changing the active selection;
- delete/rename rules, never allowing deletion of the active voice without
  first activating another;
- output device details and fallback-to-system-default behavior;
- daemon connection/ownership, effective backend/model, endpoint, protocol
  version, and log location as read-only diagnostics;
- recovery actions for invalid migrated config or failed provisioning.

For import, Swift copies only the source WAV and transcript into an
operation-specific `.staging` directory. It does so only when it owns the
managed daemon or otherwise verifies access to the daemon's exact configured
local library; an advertised capability alone is insufficient. The daemon
validates the requested stable ID and display name, creates and validates the
authoritative metadata, then commits by same-filesystem atomic rename. Failure
cleans up or quarantines staging and leaves no selectable partial profile.
Remote upload is not part of this redesign.

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

- Introduce `VoiceProfile`, backend-neutral `VoiceContext`, immutable
  `SynthesisSnapshot`, registry, and atomic active-context reference.
- Make acceptance linearizable with voice/settings commits and carry the
  captured snapshot on every queue item.
- Preserve snapshot boundaries across append and backlog coalescing.
- Implement prepare/commit/rollback and crash semantics for qwentts first, then
  MLX and torch adapters, using each adapter's engine-owning executor.
- Pin every preparing, active, queued, or in-flight qwentts registration through
  activation swap or rollback, releasing it only after the last reference.
- Keep the resident model and qwentts child alive across successful and failed
  switches; surface a post-ready child exit as an engine failure.

Exit: integration tests switch A → B → A while speaking and append work across
voice, effects, and rate commits; queued work uses its captured snapshot and
coalescing stops at snapshot boundaries. Registration pressure cannot evict
preparing, active, queued, or in-flight qwentts keys. Injected validation,
registration, persistence, and post-ready engine-child failures preserve the
durable active voice without restarting HTTP for ordinary voice switches.

### Phase 2 — management API v2 and schema migration

- Add `/meta`, `/state`, `/voices`, operation-result reads, voice
  activation/library mutations, and `/settings`.
- Make state and the complete valid/invalid voice registry available during
  model loading and failures.
- Add instance-scoped state/voice revisions, require `Idempotency-Key` on every
  state-changing management request, retain current-instance results, detect
  key reuse across different mutations, return structured errors, and enforce
  `409` busy.
- Enforce the bearer token and Origin policy on every v2 route.
- Migrate complete legacy flat voice pairs into ready profile directories
  before validating or writing schema-v2 settings.
- Migrate the old config to versioned daemon product settings atomically only
  after profile migration and ready-profile validation succeed.
- Report effective backend/model/endpoint from resolved launch values.

Exit: black-box API tests cover every state transition and failure injection.
An upgraded installation reaches Ready only after its referenced legacy voice
profile is committed; incomplete pairs and collisions remain recoverable,
staging remains hidden, and original sources remain through that first Ready.
The live macOS bundle reports `qwentts` when launched with qwentts.
The API gate also covers independent revision domains, operation-result
recovery and unknown-result errors, invalid-profile issue data, and
authorization failures.

### Phase 3 — Swift lifecycle and state store

- Add an authenticated `/meta` handshake and exact-endpoint policy with distinct
  authorization, identity, and compatibility failures.
- Replace `AppController` callback state with `WrenStore` and typed actions.
- Reconstruct all endpoint-bound components together on a deployment endpoint
  change/relaunch.
- Reconcile ambiguous mutations through operation-result reads.
- Reset independent state/voice revision gates when `instance_id` changes.
- Surface request, decode, persistence, child-exit, and compatibility errors.
- Preserve managed versus connected ownership in every lifecycle action.
- Enable staged import only with capability plus proven local-library access.

Exit: reducer/integration tests prove stale responses cannot win within either
revision domain, an instance change resets both gates, ambiguous operations are
recovered, connected daemons are never killed, authorization and non-Wren port
failures stay distinct and visible, and child crash recovery reaches either
ready or a bounded actionable failure.

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
- Filter non-ready voices from the quick picker while keeping their structured
  issues visible in voice management.

Exit: run the installed app and exercise every menu state against a real daemon;
the selected voice always matches `/state.synthesis.active_voice`, including
while activation is pending or failed.

### Phase 6 — settings, voice import, output, and login

- Add the Settings/voice-management window, atomic metadata rename, and guarded
  deletion through atomic trash rename with resumable cleanup.
- Expose staged import only when Swift owns the managed daemon or otherwise
  proves access to its exact configured local library; advertised capability
  alone is insufficient.
- Add output-device selection, disconnect fallback, and visible warning.
- Add the Otis-style `SMAppService` launch-at-login row.
- Finish actionable provisioning/config/log recovery.

Exit: with exact shared-library access proven, import and activate a new voice
without restarting; otherwise staged import is unavailable. Reject incomplete,
corrupt, and colliding imports without residue or implicit selection; an
interrupted metadata rename leaves a valid old or new file; guarded deletion
never removes an active or captured profile, atomically removes an allowed
profile from the library, and resumes interrupted trash cleanup after restart;
unplug the selected output and still hear audio through fallback; external
login-item changes appear on the next menu open.

### Phase 7 — release hardening

- Update `doctor` for protocol identity, migrated settings, voice registry,
  engine/model assets, output device, endpoint conflict, and login item.
- Exercise bundle install/update over existing old and new configs.
- Run full Python, Swift, extension, and installed-app smoke verification.
- In release cleanup, remove temporary config and legacy flat-voice migration
  backups only after the upgraded daemon has reached Ready successfully.

Exit: a clean machine and an upgraded existing installation both reach Ready
without a terminal; the upgraded installation retains every legacy source
through its first successful launch and release cleanup removes only confirmed
backups; all failure scenarios below have been observed, not merely mocked.

## Verification matrix

### Voice and persistence

- valid A → B activation;
- missing WAV, missing transcript, corrupt WAV, unsafe ID;
- complete legacy flat pairs commit before schema-v2 `active_voice` validation,
  remain hidden while staged, and retain their sources through first Ready;
- incomplete legacy pairs and colliding IDs remain untouched, overwrite and
  implicit selection never occur, and recovery details are visible;
- import is unavailable without a proven shared local library; with one, the
  daemon alone writes validated metadata before the atomic profile commit;
- failed imports remove their staging directories and leave no residue or
  selectable partial profile;
- interruption during profile metadata rewrite leaves either the complete old
  metadata or the complete new metadata;
- guarded deletion rejects active and captured profiles; an allowed deletion
  either leaves the original profile intact or atomically moves it out of the
  library, and startup resumes interrupted `.trash` cleanup;
- qwentts registration pressure keeps preparing, active, queued, and in-flight
  keys pinned, permits temporary overflow, then evicts unpinned LRU entries back
  to the 16-entry limit after release;
- settings directory unwritable/disk-full injection;
- daemon crash before and after operation commit;
- the same `Idempotency-Key` and mutation returns the existing/final result,
  while reuse for a different mutation conflicts;
- ambiguous responses recover through result lookup within the current
  instance, and unknown current-instance IDs return the stable `404` error;
- daemon restart changes `instance_id`; the client resets revision gates,
  reconciles state and voices, and never looks up or deduplicates prior-instance
  keys;
- rapid A → B then B → C requests and duplicate request IDs;
- appends spanning voice, effects, and daemon-rate commits, with backlog
  coalescing stopping at each synthesis-snapshot boundary;
- activation while old-voice work is queued and speaking.

### Lifecycle and identity

- empty port spawns one child;
- compatible authenticated Wren endpoint enters connected mode;
- missing/wrong bearer tokens and rejected Origins fail visibly without
  adoption or spawning;
- authenticated unrelated JSON services and incompatible protocols fail
  distinctly from authorization;
- managed child crash/backoff/circuit breaker;
- post-ready qwentts child exit marks synthesis not ready, rejects new `/speak`
  explicitly, preserves the durable active voice, and follows managed,
  connected, and Linux ownership boundaries during recovery;
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

- menu checkmark reads only `/state.synthesis.active_voice` at rest, during
  activation, and on failure;
- voice management lists invalid/incomplete profiles with structured issues,
  while the quick picker excludes them;
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
