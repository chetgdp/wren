"""Wren synthesis server: qwentts.cpp voices, streamed to edge clients.

The server never plays audio. Each edge client (Wren.app on a Mac, or the
browser extension) owns a channel and plays it locally by long-polling
GET /segment. Speech without a channel (the CLI, often run over SSH) goes to
the ACTIVE client: the Mac whose user most recently claimed it via
POST /clients/active.

Routes (JSON unless noted; errors are {"error": {"code", "message"}}):
    POST /speak {text | blocks, raw?, append?, channel?}
    POST /stop {channel?, all?}   POST /pause, /resume {channel?}
    POST /seek {delta | block, channel?}
    GET  /segment?channel=&after=&played=&timeout=   audio/wav long-poll
    POST /clients/active {channel, label?}
    GET  /health   GET /state   GET /voices   PUT /voice {voice}
    POST /voices (multipart)   PATCH|DELETE /voices/{id}
    PATCH /settings {effects?}

Run:
    uv run tts/serve.py --qwentts-bin .../tts-server \\
        --qwentts-model .../qwen-talker.gguf \\
        --qwentts-codec .../qwen-tokenizer.gguf --initial-voice c3po
"""

import argparse
import json
import re
import signal
import sys
import threading
import time
import traceback
from contextlib import contextmanager
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from engine import QwenttsEngine
from speaker import SegmentStore, Speaker, SynthesisSnapshot, SynthWorker
from storage import (
    SettingsStore, StorageError, VoiceLibrary, default_data_dir,
    validate_wav_bytes)
from text import sanitize_markdown

HOST = "127.0.0.1"
DEFAULT_PORT = 8765
# Requests carry prose; an uncapped read is a memory/CPU (sanitize regex)
# hole for whatever can reach the port. Voice uploads carry a wav.
MAX_BODY_BYTES = 1 * 1024 * 1024
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
# Browsers stamp cross-site requests with the page's Origin and JS cannot
# strip it, so rejecting non-extension origins kills drive-by CSRF from web
# pages. Extension clients pass; non-browser clients send no Origin.
ALLOWED_ORIGIN_SCHEMES = (
    "chrome-extension:", "moz-extension:", "safari-web-extension:")
SEGMENT_POLL_TIMEOUT = 20.0
MAX_POLL_TIMEOUT = 25.0
# Channels are created on first use by name, so abandoned ones (a Mac that
# went away, a typo) must not keep threads and buffers forever.
CHANNEL_GC_SECONDS = 600.0
CHANNEL_NAME_RE = re.compile(r"[a-z0-9_-]{1,32}\Z")
MAX_DISPLAY_NAME = 128
MAX_LABEL = 128


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def _bad(message, code="bad_request"):
    return ApiError(400, code, message)


def _channel_name(value):
    if not isinstance(value, str) or not CHANNEL_NAME_RE.fullmatch(value):
        raise _bad("channel must match [a-z0-9_-]{1,32}", "invalid_channel")
    return value


def _display_name(value):
    if (not isinstance(value, str) or not value.strip()
            or len(value) > MAX_DISPLAY_NAME):
        raise _bad(f"display_name must be 1-{MAX_DISPLAY_NAME} characters")
    return value.strip()


class Channel:
    __slots__ = ("name", "speaker", "store", "label", "active_polls",
                 "last_seen", "last_used", "busy")

    def __init__(self, name, speaker, store):
        self.name = name
        self.speaker = speaker
        self.store = store
        self.label = None
        self.active_polls = 0
        self.last_seen = None  # wall clock of the last /segment poll
        self.last_used = time.monotonic()
        self.busy = 0


class ChannelManager:
    """Channels by name plus the active-client pointer."""

    def __init__(self, worker, gc_seconds=CHANNEL_GC_SECONDS, tick=5.0):
        self._worker = worker
        self._lock = threading.Lock()
        self._channels = {}
        self._active = None  # (channel, label)
        self._gc_seconds = gc_seconds
        threading.Thread(target=self._janitor, args=(tick,), daemon=True,
                         name="channel-gc").start()

    def _get_locked(self, name):
        ch = self._channels.get(name)
        if ch is None:
            store = SegmentStore()
            ch = Channel(name, Speaker(name, self._worker, store), store)
            self._channels[name] = ch
        ch.last_used = time.monotonic()
        return ch

    @contextmanager
    def use(self, name):
        """Pin a channel for one request so GC cannot delete it mid-use."""
        with self._lock:
            ch = self._get_locked(name)
            ch.busy += 1
        try:
            yield ch
        finally:
            with self._lock:
                ch.busy -= 1
                ch.last_used = time.monotonic()

    def resolve(self, name):
        if name is not None:
            return name
        with self._lock:
            if self._active is None:
                raise ApiError(409, "no_active_client",
                               "No Wren client has claimed active yet; "
                               "pass a channel or open Wren on a Mac.")
            return self._active[0]

    def active(self):
        with self._lock:
            if self._active is None:
                return None
            return {"channel": self._active[0], "label": self._active[1]}

    def claim(self, name, label):
        """Future channel-less speech goes to name. The previous client's
        audio stops (epoch bump) and its queue is dropped, not migrated:
        the user has moved to another machine."""
        with self._lock:
            ch = self._get_locked(name)
            if label is not None:
                ch.label = label
            previous = self._active[0] if self._active else None
            self._active = (name, ch.label)
            old = (self._channels.get(previous)
                   if previous not in (None, name) else None)
        if old is not None:
            old.speaker.stop()

    def stop_all(self):
        with self._lock:
            channels = list(self._channels.values())
        for ch in channels:
            ch.speaker.stop()

    @contextmanager
    def poll(self, name, played):
        with self._lock:
            ch = self._get_locked(name)
            ch.active_polls += 1
            ch.last_seen = time.time()
        try:
            if played is not None:
                ch.store.report_played(played)
            yield ch
        finally:
            with self._lock:
                ch.active_polls -= 1
                ch.last_seen = time.time()
                ch.last_used = time.monotonic()

    @staticmethod
    def _status(ch):
        speaker = ch.speaker
        paused = speaker.paused()
        unplayed = ch.store.unplayed()
        pending = speaker.pending()
        return {
            "speaking": unplayed > 0 and not paused,
            "paused": paused,
            "pending": pending,
            # Unfinished content of any kind; the extension reads this to
            # keep its player alive while a batch is still rendering.
            "active": (speaker.has_queued_text() or pending > 0
                       or unplayed > 0),
        }

    def health(self):
        with self._lock:
            channels = list(self._channels.values())
        out = {}
        for ch in channels:
            status = self._status(ch)
            status["block"] = None
            out[ch.name] = status
        return out

    def state(self):
        with self._lock:
            channels = list(self._channels.values())
        out = {}
        for ch in channels:
            status = self._status(ch)
            del status["active"]
            status["last_seen"] = ch.last_seen
            if ch.label is not None:
                status["label"] = ch.label
            out[ch.name] = status
        return out

    def _janitor(self, tick):
        while True:
            time.sleep(tick)
            try:
                self.gc()
            except Exception:
                traceback.print_exc()

    def gc(self, now=None):
        now = time.monotonic() if now is None else now
        dead = []
        with self._lock:
            for name, ch in list(self._channels.items()):
                if ch.active_polls or ch.busy:
                    continue
                if now - ch.last_used <= self._gc_seconds:
                    continue
                if ch.speaker.has_queued_text() or ch.speaker.pending():
                    continue
                dead.append(ch)
                del self._channels[name]
                if self._active and self._active[0] == name:
                    # The client stopped polling for 10 minutes; speaking
                    # into its dead channel would be silent, a 409 is not.
                    self._active = None
        for ch in dead:
            ch.speaker.close()


class App:
    """Product state: active voice, settings, engine readiness."""

    def __init__(self, worker, library, settings_store, settings, model,
                 gc_seconds=CHANNEL_GC_SECONDS,
                 allowed_origins=()):
        self.worker = worker
        self.library = library
        self.settings_store = settings_store
        self.settings = settings
        self.model = model
        self.allowed_origins = {o.rstrip("/") for o in allowed_origins}
        self.channels = ChannelManager(worker, gc_seconds=gc_seconds)
        self._lock = threading.Lock()  # context/settings snapshot
        self._voice_lock = threading.Lock()  # serializes voice switches
        self._context = None
        self._voice_error = None

    # --- readiness ---

    def start_initial_voice(self, initial_voice=None):
        """Prepare the persisted voice (or the bootstrap hint) once the
        engine is up. Runs in the background so HTTP answers /state while
        the model loads."""
        def run():
            self.worker.loaded.wait()
            if self.worker.error is not None:
                return
            # The persisted choice wins; the hint only covers a fresh data
            # dir or a persisted voice that has since been deleted.
            candidates = [v for v in (self.settings.get("active_voice"),
                                      initial_voice) if v]
            for voice_id in dict.fromkeys(candidates):
                try:
                    self.set_voice(voice_id)
                    return
                except ApiError as exc:
                    with self._lock:
                        self._voice_error = {"code": exc.code,
                                             "message": exc.message}
        threading.Thread(target=run, name="initial-voice",
                         daemon=True).start()

    def error(self):
        if self.worker.error is not None:
            return {"code": "engine_load_failed",
                    "message": f"The synthesis engine could not be loaded: "
                               f"{self.worker.error}"}
        engine = self.worker.engine
        if engine is not None and engine.failure is not None:
            return dict(engine.failure)
        with self._lock:
            if self._voice_error is not None:
                return dict(self._voice_error)
            no_voice = self._context is None
        if self.worker.loaded.is_set() and no_voice:
            return {"code": "no_active_voice",
                    "message": "Choose a voice with PUT /voice."}
        return None

    def ready(self):
        with self._lock:
            has_voice = self._context is not None
        return (has_voice and self.worker.loaded.is_set()
                and self.error() is None)

    # --- voices and settings ---

    def capture(self):
        """Snapshot voice/effects and pin the voice for this request."""
        with self._lock:
            context = self._context
            if context is None or not self.ready_locked():
                raise ApiError(503, "not_ready",
                               "The synthesis engine is not ready.")
            snapshot = SynthesisSnapshot(
                context, bool(self.settings["effects"]))
            # Under the lock: a concurrent PUT /voice releases the old
            # context only after swapping, so this pin always lands first.
            self.worker.retain(context)
        return snapshot

    def ready_locked(self):
        engine = self.worker.engine
        return (self.worker.loaded.is_set() and self.worker.error is None
                and engine is not None and engine.failure is None)

    def set_voice(self, voice_id):
        """Synchronous: prepare on the engine, persist, swap. Speech
        accepted after this returns uses the new voice."""
        if not isinstance(voice_id, str):
            raise _bad("voice must be a voice id string")
        with self._voice_lock:
            profile = self.library.get_voice(voice_id)
            if profile is None:
                raise ApiError(404, "unknown_voice",
                               f"Voice not found: {voice_id}")
            if not self.worker.loaded.is_set() or self.worker.error:
                raise ApiError(503, "not_ready",
                               "The synthesis engine is not ready.")
            try:
                context = self.worker.prepare(profile)
            except Exception as exc:
                raise ApiError(422, "voice_invalid",
                               f"Voice {voice_id} could not be prepared: "
                               f"{exc}") from exc
            try:
                self._persist(active_voice=voice_id)
            except BaseException:
                self.worker.release(context, wait=False)
                raise
            with self._lock:
                old, self._context = self._context, context
                self._voice_error = None
            if old is not None:
                self.worker.release(old, wait=False)

    def _persist(self, **changes):
        with self._lock:
            updated = {**self.settings, **changes}
        self.settings_store.save(updated)
        with self._lock:
            self.settings = updated

    def update_settings(self, body):
        unknown = set(body) - {"effects"}
        if unknown:
            raise _bad(f"unknown setting: {sorted(unknown)[0]}")
        changes = {}
        if "effects" in body:
            if not isinstance(body["effects"], bool):
                raise _bad("effects must be a boolean")
            changes["effects"] = body["effects"]
        if changes:
            self._persist(**changes)

    def active_voice(self):
        with self._lock:
            return self._context.voice_id if self._context else None

    def voices(self):
        return [{"id": v["id"], "display_name": v["display_name"]}
                for v in self.library.list_voices()]

    def state(self):
        with self._lock:
            settings = dict(self.settings)
        body = {
            "ready": self.ready(),
            "backend": "qwentts",
            "model": self.model,
            "active_voice": self.active_voice() or settings["active_voice"],
            "effects": bool(settings["effects"]),
            "active_client": self.channels.active(),
            "channels": self.channels.state(),
            "voices": self.voices(),
        }
        error = self.error()
        if error is not None:
            body["error"] = error
        return body

    def health(self):
        return {
            "ok": True,
            "ready": self.ready(),
            "model": self.model,
            "active_client": self.channels.active(),
            "channels": self.channels.health(),
        }


def _parse_multipart(content_type, body):
    """Parse multipart/form-data with the stdlib email parser (cgi is gone
    in 3.13). Returns {name: bytes}."""
    message = BytesParser(policy=policy.HTTP).parsebytes(
        b"MIME-Version: 1.0\r\nContent-Type: "
        + content_type.encode("latin-1") + b"\r\n\r\n" + body)
    if not message.is_multipart():
        raise _bad("body must be multipart/form-data")
    fields = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            fields[name] = part.get_payload(decode=True) or b""
    return fields


class Handler(BaseHTTPRequestHandler):
    app: App
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # --- plumbing ---

    def _send_json(self, status, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error(self, exc):
        # The request body may be unread (auth/origin fail first), so the
        # connection cannot be reused for the next request.
        self.close_connection = True
        self._send_json(exc.status, {"error": {"code": exc.code,
                                               "message": exc.message}})

    def send_error(self, code, message=None, explain=None):
        # http.server's own failures (malformed request line, etc.) keep the
        # one error shape too.
        self.close_connection = True
        try:
            self._send_error(ApiError(code, "http_error",
                                      message or "request failed"))
        except OSError:
            pass

    def _origin_allowed(self, origin):
        return (origin.startswith(ALLOWED_ORIGIN_SCHEMES)
                or origin in self.app.allowed_origins)

    def end_headers(self):
        # Web pages (unlike extensions with host_permissions) only see the
        # response, and the X-* segment headers, when CORS says so.
        # Unset when http.server rejects the request line before parsing.
        headers = getattr(self, "headers", None)
        origin = headers.get("Origin", "") if headers else ""
        if origin and self._origin_allowed(origin):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Expose-Headers",
                             "X-Seq, X-Epoch, X-Block")
            self.send_header("Vary", "Origin")
        super().end_headers()

    def do_OPTIONS(self):
        # Preflights carry no body or credentials; answer them up front.
        origin = self.headers.get("Origin", "")
        if not origin or not self._origin_allowed(origin):
            self._send_error(ApiError(403, "origin_not_allowed",
                                      "This browser Origin is not allowed."))
            return
        self.send_response(204)
        self.send_header("Access-Control-Allow-Methods",
                         "GET, POST, PUT, PATCH, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _check_access(self):
        origin = self.headers.get("Origin", "")
        if origin and not self._origin_allowed(origin):
            raise ApiError(403, "origin_not_allowed",
                           "This browser Origin is not allowed.")

    def _read_body(self, limit):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            raise _bad("invalid Content-Length")
        if length < 0 or length > limit:
            # Drain (bounded) before answering, else closing mid-upload turns
            # into a RST and the client sees a reset instead of the 413.
            remaining = min(max(length, 0), 2 * limit)
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
            self.close_connection = True
            raise ApiError(413, "body_too_large", "Request body too large.")
        return self.rfile.read(length) if length else b""

    def _json_body(self):
        raw = self._read_body(MAX_BODY_BYTES)
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            raise _bad("invalid JSON", "invalid_json")
        if not isinstance(body, dict):
            raise _bad("body must be a JSON object", "invalid_json")
        return body

    def _dispatch(self, method):
        try:
            self._check_access()
            url = urlsplit(self.path)
            path = url.path
            routes = ROUTES.get(path)
            if routes is None and path.startswith("/voices/"):
                routes = VOICE_ITEM_ROUTES
            if routes is None:
                raise ApiError(404, "not_found", f"No route for {path}")
            handler = routes.get(method)
            if handler is None:
                raise ApiError(405, "method_not_allowed",
                               f"{method} not allowed on {path}")
            handler(self, url)
        except ApiError as exc:
            self._send_error(exc)
        except StorageError as exc:
            self._send_error(ApiError(exc.status, exc.code, exc.message))
        except Exception as exc:
            traceback.print_exc()
            self._send_error(ApiError(500, "internal_error", str(exc)))

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def _body_channel(self, body):
        channel = body.get("channel")
        if channel is not None:
            _channel_name(channel)
        return self.app.channels.resolve(channel)

    # --- playback ---

    def speak(self, url):
        body = self._json_body()
        append = bool(body.get("append"))
        raw = bool(body.get("raw"))
        if "blocks" in body:
            blocks = body["blocks"]
            if not isinstance(blocks, list) or not all(
                    isinstance(b, str) for b in blocks):
                raise _bad("blocks must be a list of strings")
            if not raw:
                blocks = [sanitize_markdown(b) for b in blocks]
            # Indices survive sanitize dropping blocks, so they keep lining
            # up with the client's element list.
            items = [(i, b) for i, b in enumerate(blocks) if b.strip()]
        else:
            text = body.get("text")
            if not isinstance(text, str) or not text.strip():
                raise _bad("missing text")
            if not raw:
                text = sanitize_markdown(text)
            items = [(None, text)] if text else []
        channel = self._body_channel(body)
        if not items:
            self._send_json(200, {"queued": 0, "channel": channel})
            return
        snapshot = self.app.capture()
        try:
            with self.app.channels.use(channel) as ch:
                queued = ch.speaker.speak(snapshot, items, append=append)
        except BaseException:
            self.app.worker.release(snapshot.context, wait=False)
            raise
        self._send_json(200, {"queued": queued, "channel": channel})

    def stop(self, url):
        body = self._json_body()
        if body.get("all") is True and body.get("channel") is None:
            self.app.channels.stop_all()
        else:
            with self.app.channels.use(self._body_channel(body)) as ch:
                ch.speaker.stop()
        self._send_json(200, {"ok": True})

    def pause(self, url):
        body = self._json_body()
        with self.app.channels.use(self._body_channel(body)) as ch:
            ch.speaker.pause()
            paused = ch.speaker.paused()
        self._send_json(200, {"ok": True, "paused": paused})

    def resume(self, url):
        body = self._json_body()
        with self.app.channels.use(self._body_channel(body)) as ch:
            ch.speaker.resume()
            paused = ch.speaker.paused()
        self._send_json(200, {"ok": True, "paused": paused})

    def seek(self, url):
        body = self._json_body()
        if "block" in body:
            block, delta = body["block"], None
            if not isinstance(block, int) or isinstance(block, bool):
                raise _bad("block must be an integer")
        else:
            block, delta = None, body.get("delta", 1)
            if (not isinstance(delta, int) or isinstance(delta, bool)
                    or delta == 0):
                raise _bad("delta must be a non-zero integer")
        with self.app.channels.use(self._body_channel(body)) as ch:
            target = ch.speaker.seek(delta=delta, target=block)
        if target is None:
            self._send_json(200, {"ok": False, "error": "nothing to seek"})
        else:
            self._send_json(200, {"ok": True, "block": target})

    def segment(self, url):
        query = parse_qs(url.query)
        channel = query.get("channel", [None])[0]
        if channel is None:
            raise _bad("channel is required", "invalid_channel")
        _channel_name(channel)
        try:
            after = int(query.get("after", ["0"])[0])
            timeout = min(max(float(query.get(
                "timeout", [str(SEGMENT_POLL_TIMEOUT)])[0]), 0.0),
                MAX_POLL_TIMEOUT)
            played = query.get("played", [None])[0]
            played = int(played) if played is not None else None
        except ValueError:
            raise _bad("after/timeout/played must be numeric")
        with self.app.channels.poll(channel, played) as ch:
            seq, block, data, epoch = ch.store.next_after(after, timeout)
        if data is None:
            self.send_response(204)
            self.send_header("X-Epoch", str(epoch))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Seq", str(seq))
        self.send_header("X-Epoch", str(epoch))
        if block is not None:
            self.send_header("X-Block", f"{block[0]},{block[1]}")
        self.end_headers()
        self.wfile.write(data)

    def claim(self, url):
        body = self._json_body()
        channel = _channel_name(body.get("channel"))
        label = body.get("label")
        if label is not None and (not isinstance(label, str)
                                  or len(label) > MAX_LABEL):
            raise _bad(f"label must be a string of at most {MAX_LABEL}")
        self.app.channels.claim(channel, label)
        self._send_json(200, {"active": channel})

    # --- status ---

    def health(self, url):
        self._send_json(200, self.app.health())

    def state(self, url):
        self._send_json(200, self.app.state())

    def list_voices(self, url):
        self._send_json(200, {"voices": self.app.voices(),
                              "active_voice": self.app.active_voice()})

    # --- management ---

    def put_voice(self, url):
        body = self._json_body()
        self.app.set_voice(body.get("voice"))
        self._send_json(200, self.app.state())

    def add_voice(self, url):
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            raise _bad("body must be multipart/form-data")
        fields = _parse_multipart(content_type,
                                  self._read_body(MAX_UPLOAD_BYTES))
        missing = [k for k in ("id", "display_name", "audio", "transcript")
                   if k not in fields]
        if missing:
            raise _bad(f"missing form field: {missing[0]}")
        try:
            voice_id = fields["id"].decode("utf-8")
            display_name = _display_name(fields["display_name"].decode("utf-8"))
            transcript = fields["transcript"].decode("utf-8")
        except UnicodeDecodeError:
            raise _bad("text fields must be UTF-8")
        validate_wav_bytes(fields["audio"])
        profile = self.app.library.add_voice(
            voice_id, display_name, fields["audio"], transcript)
        self._send_json(201, {"id": profile.id,
                              "display_name": profile.display_name})

    def _voice_id(self, url):
        return unquote(url.path[len("/voices/"):])

    def patch_voice(self, url):
        voice_id = self._voice_id(url)
        body = self._json_body()
        profile = self.app.library.update_voice(
            voice_id, _display_name(body.get("display_name")))
        self._send_json(200, {"id": profile.id,
                              "display_name": profile.display_name})

    def delete_voice(self, url):
        voice_id = self._voice_id(url)
        # Held across the check and delete so a concurrent PUT /voice cannot
        # activate the voice in between.
        with self.app._voice_lock:
            self.app.library.delete_voice(
                voice_id, self.app.active_voice()
                or self.app.settings.get("active_voice"))
        self._send_json(200, {"ok": True})

    def patch_settings(self, url):
        self.app.update_settings(self._json_body())
        self._send_json(200, self.app.state())


ROUTES = {
    "/speak": {"POST": Handler.speak},
    "/stop": {"POST": Handler.stop},
    "/pause": {"POST": Handler.pause},
    "/resume": {"POST": Handler.resume},
    "/seek": {"POST": Handler.seek},
    "/segment": {"GET": Handler.segment},
    "/clients/active": {"POST": Handler.claim},
    "/health": {"GET": Handler.health},
    "/state": {"GET": Handler.state},
    "/voices": {"GET": Handler.list_voices, "POST": Handler.add_voice},
    "/voice": {"PUT": Handler.put_voice},
    "/settings": {"PATCH": Handler.patch_settings},
}
VOICE_ITEM_ROUTES = {"PATCH": Handler.patch_voice,
                     "DELETE": Handler.delete_voice}


def make_server(app, host=HOST, port=DEFAULT_PORT):
    handler = type("BoundHandler", (Handler,), {"app": app})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Wren synthesis server (qwentts.cpp backend).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--host", default=HOST,
                   help="bind address")
    p.add_argument("-p", "--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--allow-origin", action="append", default=[],
                   metavar="URL",
                   help="web page origin allowed to call the API, e.g. "
                        "http://pq9:3000 (repeatable)")
    p.add_argument("--data-dir", type=Path, default=default_data_dir(),
                   help="voices/ and settings.json live here")
    p.add_argument("--qwentts-bin", type=Path, required=True,
                   help="qwentts.cpp tts-server binary")
    p.add_argument("--qwentts-model", type=Path, required=True,
                   help="talker GGUF (qwen-talker-*.gguf)")
    p.add_argument("--qwentts-codec", type=Path, required=True,
                   help="codec GGUF (qwen-tokenizer-*.gguf)")
    p.add_argument("--language", default="English",
                   help="language passed to tts-server")
    p.add_argument("--initial-voice",
                   help="voice id used only when settings have none")
    return p.parse_args(argv)


def start(args):
    """Build the app and bind the HTTP server; returns (server, app). The
    engine loads in the background so /state reports progress."""
    data_dir = Path(args.data_dir).expanduser()
    library = VoiceLibrary(data_dir)
    settings_store = SettingsStore(data_dir)
    settings = settings_store.load()

    def factory():
        return QwenttsEngine(args.qwentts_bin, args.qwentts_model,
                             args.qwentts_codec, language=args.language)

    worker = SynthWorker(factory)
    app = App(worker, library, settings_store, settings,
              model=str(args.qwentts_model),
              allowed_origins=args.allow_origin)
    server = make_server(app, args.host, args.port)
    app.start_initial_voice(args.initial_voice)
    return server, app


def main():
    args = parse_args()
    # SIGTERM -> normal exit so atexit reaps the tts-server child.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    server, app = start(args)
    host, port = server.server_address[:2]
    print(f"listening on http://{host}:{port} (data: {args.data_dir})",
          flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
