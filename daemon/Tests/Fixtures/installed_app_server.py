#!/usr/bin/env python3
"""Deterministic management-v2 and segment fixture for installed-app smoke."""

import argparse
import io
import json
import signal
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Fixture:
    def __init__(self, events_path, token, mode="normal"):
        self.events_path = events_path
        self.token = token
        self.mode = mode
        self.lock = threading.Lock()
        self.segment_ready = False
        self.paused = False
        self.stopped = False
        self.wav = self._silence()

    @staticmethod
    def _silence():
        output = io.BytesIO()
        with wave.open(output, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(24000)
            audio.writeframes(b"\0\0" * 2400)
        return output.getvalue()

    def record(self, method, target, body=None):
        event = {"method": method, "target": target}
        if body is not None:
            event["body"] = body
        line = json.dumps(event, sort_keys=True, separators=(",", ":"))
        with self.lock, self.events_path.open("a", encoding="utf-8") as output:
            output.write(line + "\n")
            output.flush()

    def state(self):
        with self.lock:
            paused = self.paused
            stopped = self.stopped
        degraded = self.mode == "degraded"
        failure_detail = None
        last_error = None
        if degraded:
            failure_detail = {
                "code": "engine_child_exited",
                "message": "qwentts tts-server exited unexpectedly",
                "exit_code": 23,
            }
            last_error = {
                "code": "engine_child_exited",
                "message": "The synthesis engine is unavailable.",
                "detail": failure_detail,
                "recoverable": True,
            }
        return {
            "revision": 1,
            "voices_revision": 1,
            "lifecycle": {
                "phase": "degraded" if degraded else "ready",
                "message": (
                    "The synthesis engine is unavailable."
                    if degraded else None
                ),
            },
            "synthesis": {
                "ready": not degraded,
                "active_voice": None if degraded else "fixture",
                "effects": False,
                "default_synthesis_rate": 1.0,
                "backend": "fixture",
                "model": "in-repo-silence",
                "host": "127.0.0.1",
                "port": None,
                "voices_dir": "/fixture/voices",
            },
            "operation": None,
            "playback": {
                "pending": 0 if stopped else int(self.segment_ready),
                "speaking": self.segment_ready and not stopped,
                "paused": paused,
            },
            "last_error": last_error,
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "WrenInstalledSmoke/1"

    @property
    def fixture(self):
        return self.server.fixture

    def log_message(self, *_):
        pass

    def _authorized(self):
        expected = f"Bearer {self.fixture.token}"
        if self.headers.get("Authorization") == expected:
            return True
        self.fixture.record("AUTH", self.path)
        self._json(401, {
            "error": {
                "code": "unauthorized",
                "message": "Bearer token rejected.",
                "detail": None,
                "recoverable": True,
            }
        })
        return False

    def _json(self, status, payload, headers=None):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _empty(self, status, headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()

    def _body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not length:
            return {}
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if not self._authorized():
            return
        self.fixture.record("GET", self.path)
        parsed = urlsplit(self.path)
        if parsed.path == "/meta":
            self._json(200, {
                "service": "wren",
                "protocol_version": 2,
                "instance_id": "installed-smoke",
                "started_at": "2026-08-11T00:00:00Z",
                "capabilities": [
                    "state-v2", "voice-list", "voice-activate",
                    "settings-v2", "segment-player",
                ],
            })
        elif parsed.path == "/state":
            self._json(200, self.fixture.state())
        elif parsed.path == "/voices":
            self._json(200, {
                "revision": 1,
                "voices": [{
                    "id": "fixture",
                    "display_name": "Fixture",
                    "status": "ready",
                    "issues": [],
                }],
            })
        elif parsed.path == "/settings":
            self._json(200, self.fixture.state())
        elif parsed.path == "/health":
            state = self.fixture.state()
            self._json(200, {
                "ok": not self.fixture.mode == "degraded",
                "ready": state["synthesis"]["ready"],
                **state["playback"],
            })
        elif parsed.path == "/segment":
            query = parse_qs(parsed.query)
            after = int(query.get("after", ["0"])[0])
            with self.fixture.lock:
                ready = self.fixture.segment_ready
                stopped = self.fixture.stopped
            if ready and not stopped and after < 1:
                body = self.fixture.wav
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Epoch", "1")
                self.send_header("X-Seq", "1")
                self.send_header("X-Block", "0")
                self.end_headers()
                self.wfile.write(body)
            else:
                time.sleep(0.05)
                self._empty(204, {"X-Epoch": "1"})
        else:
            self._json(404, {"error": "not found"})

    def do_PATCH(self):
        if not self._authorized():
            return
        body = self._body()
        self.fixture.record("PATCH", self.path, body)
        if (
            self.path == "/settings"
            and self.fixture.mode == "persistence-failure"
        ):
            self._json(500, {
                "error": {
                    "code": "settings_persist_failed",
                    "message": "Product settings could not be saved.",
                    "detail": None,
                    "recoverable": True,
                }
            })
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            return
        body = self._body()
        self.fixture.record("POST", self.path, body)
        if self.path == "/speak" and self.fixture.mode == "degraded":
            self._json(503, {
                "error": {
                    "code": "engine_child_exited",
                    "message": "qwentts tts-server exited unexpectedly",
                    "exit_code": 23,
                }
            })
        elif self.path == "/speak":
            with self.fixture.lock:
                self.fixture.segment_ready = True
                self.fixture.stopped = False
            self._json(200, {"queued": 1})
        elif self.path == "/pause":
            with self.fixture.lock:
                self.fixture.paused = True
            self._json(200, {"ok": True, "paused": True})
        elif self.path == "/resume":
            with self.fixture.lock:
                self.fixture.paused = False
            self._json(200, {"ok": True, "paused": False})
        elif self.path == "/stop":
            with self.fixture.lock:
                self.fixture.stopped = True
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})


def assert_events(path):
    events = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line
    ]
    pairs = {(event["method"], urlsplit(event["target"]).path)
             for event in events}
    required = {
        ("GET", "/meta"),
        ("GET", "/state"),
        ("GET", "/voices"),
        ("GET", "/segment"),
        ("POST", "/speak"),
        ("POST", "/pause"),
        ("POST", "/resume"),
        ("POST", "/stop"),
    }
    missing = sorted(required - pairs)
    if missing:
        raise SystemExit(f"missing smoke events: {missing}")
    played = any(
        event["method"] == "GET"
        and urlsplit(event["target"]).path == "/segment"
        and parse_qs(urlsplit(event["target"]).query).get("played") == ["1"]
        for event in events
    )
    if not played:
        raise SystemExit("installed player did not report played=1")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file")
    parser.add_argument("--events-file", required=True)
    parser.add_argument("--token")
    parser.add_argument(
        "--mode",
        choices=("normal", "degraded", "persistence-failure"),
        default="normal",
    )
    parser.add_argument("--assert-events", action="store_true")
    args = parser.parse_args()

    from pathlib import Path
    events = Path(args.events_file)
    if args.assert_events:
        assert_events(events)
        return
    if not args.port_file or not args.token:
        parser.error("--port-file and --token are required in server mode")
    fixture = Fixture(events, args.token, args.mode)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.fixture = fixture
    Path(args.port_file).write_text(str(server.server_port), encoding="utf-8")
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    server.timeout = 0.1
    while not stopping.is_set():
        server.handle_request()
    server.server_close()


if __name__ == "__main__":
    main()
