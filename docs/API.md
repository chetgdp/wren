# Wren server API

HTTP/1.1 on `tts/serve.py`, default `127.0.0.1:8765` (`--host`, `--port`).
JSON in and out unless noted. The server synthesizes; it never plays audio.
Clients fetch audio per channel through `GET /segment` and play it locally.

## Access

There is no authentication; the server is meant for a trusted network
(Tailscale).

- A request with an `Origin` header must come from a browser extension
  (`chrome-extension:`, `moz-extension:`, `safari-web-extension:`) or from
  a web origin listed with `--allow-origin <url>` (repeatable, exact match,
  e.g. `--allow-origin http://pq9:3000`). Otherwise 403
  `origin_not_allowed`. Requests without `Origin` pass.
- Allowed origins get CORS: `OPTIONS` preflights answer 204, and responses
  carry `Access-Control-Allow-Origin` plus
  `Access-Control-Expose-Headers: X-Seq, X-Epoch, X-Block` so a web page
  can read the segment headers.
- JSON bodies are capped at 1 MiB, voice uploads at 64 MiB (413
  `body_too_large`).

## Errors

Every error is the HTTP status plus:

```json
{"error": {"code": "snake_case", "message": "human text"}}
```

| status | code | when |
|---|---|---|
| 400 | `bad_request` | malformed body or field |
| 400 | `invalid_channel` | channel missing or not `[a-z0-9_-]{1,32}` |
| 403 | `origin_not_allowed` | non-extension browser origin |
| 404 | `not_found` | unknown path |
| 404 | `unknown_voice` | voice id does not exist |
| 405 | `method_not_allowed` | wrong method for a known path |
| 409 | `no_active_client` | no channel given and no client has claimed active |
| 409 | `voice_exists` | upload with an id that already exists |
| 409 | `voice_active` | delete of the active voice |
| 400/422 | `voice_invalid` | bad voice id, empty transcript, unreadable WAV, engine cannot prepare it |
| 413 | `body_too_large` | body over the cap |
| 500 | `internal_error` | unexpected server failure |
| 503 | `not_ready` | engine still loading, failed, or no active voice |

## Channels and the active client

A channel is one playback queue, named `[a-z0-9_-]{1,32}`. It is created on
first use (speak, segment poll, claim) and removed after 600 s with no use.

- Each client uses its own channel: Wren.app uses `mac-<hostname>`, the
  browser extension uses `extension`.
- The server keeps one **active client**. Playback requests without a
  `channel` go to it. With no active client they fail with 409
  `no_active_client`.
- `POST /clients/active` makes a channel active. The previously active
  channel stops (its epoch bumps) and its queue is dropped.

## Playback

### `POST /speak`

```json
{"text": "Hello.", "channel": "mac-air", "append": false, "raw": false}
```

or with blocks instead of `text`:

```json
{"blocks": ["First sentence.", "Second sentence."], "channel": "extension"}
```

- `text` (string) or `blocks` (list of strings). Blocks keep their index;
  `X-Block` on segments and `/seek` refer to these indices.
- `channel` optional; default is the active client.
- `append` true queues after current speech; false (default) replaces the
  channel's queue.
- `raw` true skips markdown sanitizing.

Response `200 {"queued": 2, "channel": "extension"}`. `queued` is 0 when
sanitizing leaves no text. 503 `not_ready` if the engine cannot speak.

### `POST /stop`

`{"channel": "mac-air"}` stops one channel (default: active client).
`{"all": true}` stops every channel. Response `{"ok": true}`.

### `POST /pause`, `POST /resume`

`{"channel": "..."}` optional. Response `{"ok": true, "paused": true|false}`.

### `POST /seek`

`{"delta": -1}` moves by blocks (non-zero integer, default 1), or
`{"block": 4}` jumps to a block index. `channel` optional.
Response `{"ok": true, "block": 4}` or `{"ok": false, "error": "nothing to seek"}`.

### `GET /segment`

Long-poll for the next audio segment of a channel.

| query | meaning |
|---|---|
| `channel` | required |
| `after` | last `X-Seq` the client received (default 0) |
| `played` | last `X-Seq` the client finished playing (optional) |
| `timeout` | seconds to wait, default 20, max 25 |

- `200 audio/wav` (24 kHz mono) with headers:
  - `X-Seq`: segment number, increasing.
  - `X-Epoch`: playback generation.
  - `X-Block: lo,hi`: block range the segment covers (only for `blocks` speech).
- `204` with `X-Epoch` when the timeout passes or the epoch changes.

When `X-Epoch` changes (stop, non-append speak, seek, claim by another
client), drop all scheduled audio and continue from the new segments.
Polling a channel keeps it alive.

### `POST /clients/active`

`{"channel": "mac-air", "label": "M1 Air"}`; `label` optional, at most 128
characters. Response `{"active": "mac-air"}`.

## Status

### `GET /health`

```json
{
  "ok": true, "ready": true, "model": ".../qwen-talker-1.7b-base-Q8_0.gguf",
  "active_client": {"channel": "mac-pq9", "label": "pq9.local"},
  "channels": {
    "extension": {"speaking": true, "paused": false, "pending": 2,
                  "active": true, "block": null}
  }
}
```

`active` is true while the channel has any unfinished text or audio.
`block` is always null.

### `GET /state`

```json
{
  "ready": true, "backend": "qwentts", "model": "...",
  "active_voice": "c3po_god", "effects": false,
  "active_client": {"channel": "mac-pq9", "label": "pq9.local"},
  "channels": {
    "mac-pq9": {"speaking": false, "paused": false, "pending": 0,
                "last_seen": 1759700000.0, "label": "pq9.local"}
  },
  "voices": [{"id": "c3po_god", "display_name": "c3po_god"}],
  "error": {"code": "no_active_voice", "message": "..."}
}
```

`error` is present only when the engine failed or no voice is set.
`last_seen` is the Unix time of the last segment poll, or null.

## Voices and settings

Voice ids match `[a-zA-Z0-9_-]{1,64}`. Display names are 1 to 128 characters.

### `GET /voices`

`{"voices": [{"id": "...", "display_name": "..."}], "active_voice": "..."}`

### `PUT /voice`

`{"voice": "trump-cut"}`. Synchronous: returns after the engine has
prepared the voice and the choice is saved. Speech accepted after the
response uses the new voice; speech already queued keeps the old one.
Response: the `/state` body. Errors: 404 `unknown_voice`, 422
`voice_invalid`, 503 `not_ready`.

### `POST /voices`

`multipart/form-data` with fields `id`, `display_name`, `audio` (WAV file),
`transcript` (text of the clip). Response `201 {"id", "display_name"}`.
Errors: 409 `voice_exists`, 400/422 `voice_invalid`.

```sh
curl -F id=wintermute -F display_name=Wintermute \
     -F audio=@ref.wav -F transcript="$(cat ref.txt)" \
     http://pq9:8765/voices
```

### `PATCH /voices/{id}`

`{"display_name": "New name"}`. Response `{"id", "display_name"}`.

### `DELETE /voices/{id}`

Response `{"ok": true}`. 409 `voice_active` for the active voice.

### `PATCH /settings`

`{"effects": true}`; unknown keys are 400. Saved to disk. Response: the `/state` body.

## Storage

Under `--data-dir` (macOS default `~/Library/Application Support/voice-ml`,
Linux `~/.local/share/wren`):

- `voices/<id>/profile.json` (`{"id", "display_name"}`), `reference.wav`,
  `transcript.txt`
- `settings.json`: `{"active_voice", "effects"}`
