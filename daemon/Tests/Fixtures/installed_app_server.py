#!/usr/bin/env python3
"""Deterministic fixture server for thin client smoke testing per contract.md."""

import argparse
import io
import json
import signal
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit


class Fixture:
    def __init__(self, events_path):
        self.events_path = events_path
        self.lock = threading.Lock()
        self.active_client = None
        self.active_voice = "c3po"
        self.effects = False
        self.paused = False
        self.stopped = False
        self.voices = [
            {"id": "c3po", "display_name": "C-3PO"},
            {"id": "fixture", "display_name": "Fixture Voice"},
        ]
        self.wav = self._silence()

    @staticmethod
    def _silence():
        output = io.BytesIO()
        with wave.open(output, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(24000)
            wav_file.writeframes(b"\x00\x00" * 2400)
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
            return {
                "ready": True,
                "backend": "qwentts",
                "model": "qwen-test",
                "active_voice": self.active_voice,
                "effects": self.effects,
                "active_client": self.active_client,
                "channels": {},
                "voices": self.voices,
            }


class Handler(BaseHTTPRequestHandler):
    server_version = "WrenThinFixture/1"

    @property
    def fixture(self):
        return self.server.fixture

    def log_message(self, *_):
        pass

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

    def _raw(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _body(self):
        raw = self._raw()
        return json.loads(raw) if raw else {}

    def _error(self, status, code, message):
        self._json(status, {"error": {"code": code, "message": message}})

    def _multipart(self, raw):
        """Parses multipart/form-data without the removed cgi module."""
        from email.parser import BytesParser
        from email.policy import HTTP

        header = f"Content-Type: {self.headers.get('Content-Type')}\r\n\r\n"
        message = BytesParser(policy=HTTP).parsebytes(header.encode() + raw)
        fields = {}
        for part in message.iter_parts():
            name = part.get_param("name", header="content-disposition")
            fields[name] = part.get_payload(decode=True)
        return fields

    def _target_channel(self, body):
        """Mirrors the contract: no channel means the active client's."""
        channel = body.get("channel")
        if channel:
            return channel
        with self.fixture.lock:
            active = self.fixture.active_client
        if active is None:
            self._error(409, "no_active_client", "No active client")
            return None
        return active["channel"]

    def do_GET(self):
        self.fixture.record("GET", self.path)
        parsed = urlsplit(self.path)
        if parsed.path == "/state":
            self._json(200, self.fixture.state())
        elif parsed.path == "/health":
            state = self.fixture.state()
            active = state["active_client"]
            self._json(200, {
                "ok": True,
                "ready": True,
                "model": state["model"],
                "active_client": active["channel"] if active else None,
                "channels": {},
            })
        elif parsed.path == "/voices":
            state = self.fixture.state()
            self._json(200, {"voices": state["voices"], "active_voice": state["active_voice"]})
        elif parsed.path == "/segment":
            query = parse_qs(parsed.query)
            after = int(query.get("after", ["0"])[0])
            with self.fixture.lock:
                stopped = self.fixture.stopped
            if not stopped and after < 1:
                body = self.fixture.wav
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Epoch", "1")
                self.send_header("X-Seq", "1")
                self.end_headers()
                self.wfile.write(body)
            else:
                self._empty(204, {"X-Epoch": "1"})
        else:
            self._json(404, {"error": {"code": "not_found", "message": "Not found"}})

    def do_POST(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/voices":
            self._add_voice(self._multipart(self._raw()))
            return
        body = self._body()
        self.fixture.record("POST", self.path, body)
        if parsed.path == "/clients/active":
            with self.fixture.lock:
                self.fixture.active_client = {
                    "channel": body.get("channel", "default"),
                    "label": body.get("label"),
                }
            self._json(200, {"active": self.fixture.active_client["channel"]})
        elif parsed.path == "/speak":
            channel = self._target_channel(body)
            if channel is None:
                return
            with self.fixture.lock:
                self.fixture.stopped = False
            self._json(200, {"queued": 1, "channel": channel})
        elif parsed.path == "/stop":
            if not body.get("all") and self._target_channel(body) is None:
                return
            with self.fixture.lock:
                self.fixture.stopped = True
            self._json(200, {"ok": True})
        elif parsed.path in ("/pause", "/resume"):
            if self._target_channel(body) is None:
                return
            paused = parsed.path == "/pause"
            with self.fixture.lock:
                self.fixture.paused = paused
            self._json(200, {"ok": True, "paused": paused})
        else:
            self._error(404, "not_found", "Not found")

    def _add_voice(self, fields):
        def text(name):
            return (fields.get(name) or b"").decode("utf-8")

        voice_id = text("id")
        audio = fields.get("audio") or b""
        self.fixture.record("POST", self.path, {
            "id": voice_id,
            "display_name": text("display_name"),
            "transcript": text("transcript"),
            "audio_bytes": len(audio),
        })
        try:
            with wave.open(io.BytesIO(audio)) as clip:
                clip.getnframes()
        except (wave.Error, EOFError):
            self._error(422, "voice_invalid", "audio is not a WAV file")
            return
        voice = {"id": voice_id, "display_name": text("display_name")}
        with self.fixture.lock:
            if any(v["id"] == voice_id for v in self.fixture.voices):
                exists = True
            else:
                exists = False
                self.fixture.voices.append(voice)
        if exists:
            self._error(409, "voice_exists", f"{voice_id} exists")
        else:
            self._json(201, voice)

    def _voice_id(self, path):
        prefix = "/voices/"
        return unquote(path[len(prefix):]) if path.startswith(prefix) else None

    def do_DELETE(self):
        parsed = urlsplit(self.path)
        self.fixture.record("DELETE", self.path)
        voice_id = self._voice_id(parsed.path)
        with self.fixture.lock:
            active = self.fixture.active_voice
            known = any(v["id"] == voice_id for v in self.fixture.voices)
            if known and voice_id != active:
                self.fixture.voices = [
                    v for v in self.fixture.voices if v["id"] != voice_id
                ]
        if not known:
            self._error(404, "unknown_voice", f"{voice_id} not found")
        elif voice_id == active:
            self._error(409, "voice_active", "voice is active")
        else:
            self._json(200, {"ok": True})

    def do_PUT(self):
        parsed = urlsplit(self.path)
        body = self._body()
        self.fixture.record("PUT", self.path, body)
        if parsed.path == "/voice":
            voice = body.get("voice")
            with self.fixture.lock:
                known = any(v["id"] == voice for v in self.fixture.voices)
                if known:
                    self.fixture.active_voice = voice
            if known:
                self._json(200, self.fixture.state())
            else:
                self._error(404, "unknown_voice", f"{voice} not found")
        else:
            self._json(404, {"error": {"code": "not_found", "message": "Not found"}})

    def do_PATCH(self):
        parsed = urlsplit(self.path)
        body = self._body()
        self.fixture.record("PATCH", self.path, body)
        if parsed.path == "/settings":
            with self.fixture.lock:
                if "effects" in body:
                    self.fixture.effects = bool(body["effects"])
            self._json(200, self.fixture.state())
        elif self._voice_id(parsed.path):
            voice_id = self._voice_id(parsed.path)
            with self.fixture.lock:
                match = next(
                    (v for v in self.fixture.voices if v["id"] == voice_id),
                    None,
                )
                if match is not None:
                    match["display_name"] = body.get("display_name", "")
            if match is None:
                self._error(404, "unknown_voice", f"{voice_id} not found")
            else:
                self._json(200, dict(match))
        else:
            self._error(404, "not_found", "Not found")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file")
    parser.add_argument("--events-file", required=True)
    args = parser.parse_args()

    from pathlib import Path
    events = Path(args.events_file)
    fixture = Fixture(events)
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
