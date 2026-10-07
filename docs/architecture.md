# Wren Architecture

## System Boundaries

```text
WrenMenuBar / SettingsPanel
  renders AppState; sends UserAction
                │
                ▼
AppCoordinator (@MainActor)
  manages lifecycle, signal traps, window presentation;
  connects ServerSupervisor and WrenStore
       │                    │
       ▼                    ▼
ServerSupervisor      WrenStore (@MainActor)
  child process       combines daemon state + local player state
  supervision         serializes actions; owns visible error state
  (posix_spawn)            │                 │
                           ▼                 ▼
                     DaemonClient       SegmentPlayer
                     /state, /speak     AVAudioEngine
```

## Bootstrap and Lifecycle

1. `AppCoordinator.start()` initialises the application runtime:
   - Sets activation policy to accessory (menu-bar only).
   - Installs POSIX signal handlers (`SIGINT`, `SIGTERM`) to trigger clean
     termination.
   - Binds `ServerSupervisor.onChange` to `WrenStore.setLocalServer(_:)`.
   - Starts `ServerSupervisor` with the resolved host (`state.host`).
   - Hooks menu actions to coordinator and store actions (`.setRunLocalServer`
     toggles `supervisor.setEnabled(_:)`).
   - Hooks store state observations to update `WrenMenuBar` and `SettingsPanel`.
2. On host endpoint change (via Settings), `ServerSupervisor.hostChanged(_:)`
   is notified to stop any child process if the endpoint becomes non-loopback,
   or start child supervision if it becomes loopback.
3. On application termination (`willTerminate`):
   - `ServerSupervisor.shutdown()` terminates child process groups cleanly
     (SIGTERM with 5s timeout, followed by SIGKILL).
   - `WrenStore.shutdown()` cancels background state polling, player playback,
     and audio monitoring.

## State Management

`AppState` represents the unified snapshot of runtime state:

- `host`: active daemon endpoint (e.g. `127.0.0.1:8765`).
- `status`: connection status (`connecting`, `connected`, `unreachable`).
- `localServer`: managed child server state (`LocalServerState`):
  - `isEnabled`: persisted toggle state (`run_local_server`).
  - `status`: `.disabled`, `.unavailable(reason)`, `.external`, `.starting`,
    `.running`, `.crashed(reason, retryIn)`.
- `channel`: client channel identifier.
- `voices`, `activeVoice`: voice profiles and active selection.
- `activeClient`: machine channel currently holding playback claim.
- `effects`: synthesis properties.
- `localPlayer`: client-side playback rate and pause state.
- `audioOutput`: output devices and user preference.
- `loginItem`: launch-at-login state via `SMAppService`.
- `lastError`: user-visible error string for settings panel.
