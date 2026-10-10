"""Tests for the Wren synthesis server against a stub tts-server.

Run: uv run pytest tts
"""

import io
import json
import os
import stat
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest

import serve
from stub_tts_server import voice_sample
from text import chunk_text, sanitize_markdown

HERE = Path(__file__).resolve().parent


def wait_for(cond, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if cond():
            return True
        time.sleep(0.02)
    return False


def wav_bytes(seconds=0.1, rate=24000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x01\x00" * int(rate * seconds))
    return buf.getvalue()


def write_v2_voice(data_dir, voice_id, display_name, transcript):
    """The layout the previous storage.py produced."""
    root = Path(data_dir) / "voices" / voice_id
    root.mkdir(parents=True)
    (root / "profile.json").write_text(json.dumps(
        {"id": voice_id, "display_name": display_name}))
    (root / "reference.wav").write_bytes(wav_bytes())
    (root / "transcript.txt").write_text(transcript)


@pytest.fixture
def stub_bin(tmp_path_factory):
    path = tmp_path_factory.mktemp("bin") / "tts-server"
    path.write_text(f'#!/bin/sh\nexec "{sys.executable}" '
                    f'"{HERE / "stub_tts_server.py"}" "$@"\n')
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


class Server:
    def __init__(self, stub_bin, data_dir, initial_voice=None,
                 wait_ready=True, allow_origin=()):
        args = SimpleNamespace(
            host="127.0.0.1", port=0, data_dir=data_dir,
            qwentts_bin=stub_bin, qwentts_model=Path("talker.gguf"),
            qwentts_codec=Path("codec.gguf"), language="English",
            initial_voice=initial_voice, allow_origin=list(allow_origin))
        self.httpd, self.app = serve.start(args)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever,
                         daemon=True).start()
        if wait_ready:
            assert wait_for(self.app.ready), self.get("/state")

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        worker = self.app.worker
        if worker.engine is not None:
            worker.control(worker.engine.close)

    def request(self, method, path, body=None, headers=None, raw=None):
        data = raw if raw is not None else (
            json.dumps(body).encode() if body is not None else None)
        hdrs = {"Content-Type": "application/json"}
        hdrs.update(headers or {})
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", data=data, headers=hdrs,
            method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers), exc.read()

    def json(self, method, path, body=None, **kw):
        status, _, payload = self.request(method, path, body, **kw)
        return status, (json.loads(payload) if payload else None)

    def get(self, path):
        return self.json("GET", path)[1]

    def post(self, path, body=None):
        return self.json("POST", path, body or {})

    def segment(self, channel, after=0, timeout=10, played=None):
        q = f"/segment?channel={channel}&after={after}&timeout={timeout}"
        if played is not None:
            q += f"&played={played}"
        return self.request("GET", q)

    def stub_log(self):
        base = self.app.worker.engine._base_url
        with urllib.request.urlopen(f"{base}/log") as resp:
            return json.loads(resp.read())


def sample_of(wav):
    with wave.open(io.BytesIO(wav)) as w:
        frame = w.readframes(1)
    return int.from_bytes(frame, "little", signed=True)


@pytest.fixture
def data_dir(tmp_path):
    d = tmp_path / "data"
    write_v2_voice(d, "alpha", "Alpha", "alpha transcript")
    write_v2_voice(d, "beta", "Beta", "beta words here")
    return d


@pytest.fixture
def server(stub_bin, data_dir):
    s = Server(stub_bin, data_dir, initial_voice="alpha")
    yield s
    s.close()


def multipart(fields):
    boundary = uuid.uuid4().hex
    out = io.BytesIO()
    for name, (value, filename) in fields.items():
        out.write(f"--{boundary}\r\n".encode())
        disp = f'form-data; name="{name}"'
        if filename:
            disp += f'; filename="{filename}"'
        out.write(f"Content-Disposition: {disp}\r\n\r\n".encode())
        out.write(value if isinstance(value, bytes) else value.encode())
        out.write(b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={boundary}"


# --- text helpers ---

def test_sanitize_markdown():
    out = sanitize_markdown("# Title\n- **bold** `x` [l](http://a)\n```\nc\n```")
    assert out == "Title\nbold x l"


def test_chunk_text_ramps():
    chunks = chunk_text("One. " * 200, max_chars=100, first_chars=20)
    assert len(chunks[0]) <= 20 and max(len(c) for c in chunks) <= 100


# --- origin, health ---

def test_origin_rejected(server):
    status, body = server.json(
        "POST", "/speak", {"text": "hi", "channel": "x"},
        headers={"Origin": "https://evil.example"})
    assert status == 403
    assert body["error"]["code"] == "origin_not_allowed"
    status, _ = server.json(
        "GET", "/health", headers={"Origin": "chrome-extension://abc"})
    assert status == 200


WEB = "http://phone.example:3000"


@pytest.fixture
def web_server(stub_bin, data_dir):
    s = Server(stub_bin, data_dir, initial_voice="alpha",
               allow_origin=[WEB + "/"])
    yield s
    s.close()


def test_allowed_web_origin_gets_cors_and_segment_headers(web_server):
    status, headers, _ = web_server.request(
        "OPTIONS", "/speak",
        headers={"Origin": WEB,
                 "Access-Control-Request-Method": "POST",
                 "Access-Control-Request-Headers": "content-type"})
    assert status == 204
    assert headers["Access-Control-Allow-Origin"] == WEB
    assert "Content-Type" in headers["Access-Control-Allow-Headers"]

    status, body = web_server.json(
        "POST", "/speak", {"text": "hi", "channel": "webgui"},
        headers={"Origin": WEB})
    assert status == 200, body
    status, headers, wav = web_server.request(
        "GET", "/segment?channel=webgui&after=0&timeout=10",
        headers={"Origin": WEB})
    assert status == 200 and wav
    assert headers["Access-Control-Allow-Origin"] == WEB
    assert "X-Epoch" in headers["Access-Control-Expose-Headers"]


def test_unlisted_web_origin_still_rejected(web_server):
    status, _, _ = web_server.request(
        "OPTIONS", "/speak",
        headers={"Origin": "http://evil.example"})
    assert status == 403
    status, headers, _ = web_server.request(
        "GET", "/health", headers={"Origin": "http://evil.example"})
    assert status == 403
    assert "Access-Control-Allow-Origin" not in headers


def test_health_shape(server):
    server.post("/speak", {"text": "hello", "channel": "extension"})
    h = server.get("/health")
    assert h["ok"] is True and h["ready"] is True
    assert h["model"] == "talker.gguf"
    assert h["active_client"] is None
    ext = h["channels"]["extension"]
    assert set(ext) >= {"speaking", "paused", "pending", "block", "active"}


def test_unknown_route_and_method(server):
    assert server.json("GET", "/nope")[0] == 404
    status, body = server.json("GET", "/speak")
    assert status == 405 and body["error"]["code"] == "method_not_allowed"


def test_body_too_large(server):
    status, body = server.json(
        "POST", "/speak", raw=b"x" * (serve.MAX_BODY_BYTES + 1))
    assert status == 413 and body["error"]["code"] == "body_too_large"


# --- routing ---

def test_speak_without_client_is_409(server):
    status, body = server.post("/speak", {"text": "hello"})
    assert status == 409 and body["error"]["code"] == "no_active_client"
    for path in ("/stop", "/pause", "/resume", "/seek"):
        status, body = server.post(path, {})
        assert status == 409, path


def test_speak_routes_to_active_client(server):
    status, body = server.post("/clients/active",
                               {"channel": "mac-a", "label": "Mac A"})
    assert (status, body) == (200, {"active": "mac-a"})
    status, body = server.post("/speak", {"text": "hello there."})
    assert status == 200 and body == {"queued": 1, "channel": "mac-a"}
    status, headers, wav = server.segment("mac-a")
    assert status == 200 and headers["Content-Type"] == "audio/wav"
    assert int(headers["X-Seq"]) == 1 and "X-Epoch" in headers
    assert sample_of(wav) == voice_sample("alpha transcript")
    state = server.get("/state")
    assert state["active_client"] == {"channel": "mac-a", "label": "Mac A"}
    assert state["channels"]["mac-a"]["label"] == "Mac A"


def test_claim_switch_bumps_old_epoch(server):
    server.post("/clients/active", {"channel": "mac-a"})
    server.post("/speak", {"text": "first."})
    _, headers, _ = server.segment("mac-a")
    epoch = int(headers["X-Epoch"])
    server.post("/clients/active", {"channel": "mac-b"})
    status, headers, _ = server.segment("mac-a", after=1, timeout=0.2)
    assert status == 204 and int(headers["X-Epoch"]) > epoch
    status, body = server.post("/speak", {"text": "second."})
    assert body["channel"] == "mac-b"
    status, _, wav = server.segment("mac-b")
    assert status == 200


def test_extension_unaffected_by_claims(server):
    server.post("/speak", {"text": "page text.", "channel": "extension"})
    _, headers, _ = server.segment("extension")
    epoch = headers["X-Epoch"]
    server.post("/clients/active", {"channel": "mac-a"})
    server.post("/clients/active", {"channel": "mac-b"})
    status, headers, _ = server.segment("extension", after=1, timeout=0.2)
    assert status == 204 and headers["X-Epoch"] == epoch


def test_non_append_preempts_target_only(server):
    server.post("/speak", {"text": "one.", "channel": "a"})
    server.post("/speak", {"text": "two.", "channel": "b"})
    _, ha, _ = server.segment("a")
    _, hb, _ = server.segment("b")
    server.post("/speak", {"text": "three.", "channel": "a"})
    _, hb2, _ = server.segment("b", after=1, timeout=0.2)
    assert hb2["X-Epoch"] == hb["X-Epoch"]
    _, ha2, _ = server.segment("a", after=0, timeout=5)
    assert int(ha2["X-Epoch"]) > int(ha["X-Epoch"])


def test_stop_all(server):
    server.post("/speak", {"text": "one.", "channel": "a"})
    server.post("/speak", {"text": "two.", "channel": "b"})
    _, ha, _ = server.segment("a")
    _, hb, _ = server.segment("b")
    assert server.post("/stop", {"all": True}) == (200, {"ok": True})
    for name, h in (("a", ha), ("b", hb)):
        _, h2, _ = server.segment(name, after=1, timeout=0.1)
        assert int(h2["X-Epoch"]) > int(h["X-Epoch"])


def test_pause_resume_seek(server):
    ch = "reader"
    assert server.post("/pause", {"channel": ch}) == (
        200, {"ok": True, "paused": True})
    assert server.get("/health")["channels"][ch]["paused"] is True
    assert server.post("/resume", {"channel": ch}) == (
        200, {"ok": True, "paused": False})
    assert server.post("/seek", {"delta": 1, "channel": ch}) == (
        200, {"ok": False, "error": "nothing to seek"})
    status, body = server.post(
        "/speak", {"blocks": ["One.", "Two.", "Three."], "channel": ch})
    assert body["queued"] == 3
    status, headers, _ = server.segment(ch)
    assert headers["X-Block"] == "0,0"
    assert server.post("/seek", {"block": 2, "channel": ch}) == (
        200, {"ok": True, "block": 2})
    status, headers, _ = server.segment(ch, after=0)
    assert headers["X-Block"] == "2,2"
    assert server.post("/seek", {"delta": 0, "channel": ch})[0] == 400


def test_segment_requires_channel(server):
    status, _, body = server.request("GET", "/segment?after=0")
    assert status == 400
    assert json.loads(body)["error"]["code"] == "invalid_channel"


def test_played_segments_are_not_served_to_a_restarted_client(tmp_path):
    from speaker import SegmentStore

    clip = tmp_path / "clip.wav"
    with wave.open(str(clip), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(24000)
        w.writeframes(b"\0\0" * 2400)
    store = SegmentStore()
    for _ in range(3):
        store.submit(clip, None)
    assert store.next_after(0, 0)[0] == 1
    store.report_played(2)
    # A restarted client polls from 0 again; only the unplayed clip is left.
    assert store.next_after(0, 0)[0] == 3
    assert store.unplayed() == 1


def test_speak_validation(server):
    assert server.post("/speak", {"text": "", "channel": "a"})[0] == 400
    assert server.post("/speak", {"text": "x", "channel": "BAD"})[0] == 400
    assert server.post("/clients/active", {})[0] == 400



def test_not_ready_without_voice(stub_bin, tmp_path):
    s = Server(stub_bin, tmp_path / "empty", wait_ready=False)
    try:
        assert wait_for(lambda: s.get("/state").get("error") is not None)
        state = s.get("/state")
        assert state["ready"] is False
        assert state["error"]["code"] == "no_active_voice"
        status, body = s.post("/speak", {"text": "x", "channel": "a"})
        assert status == 503 and body["error"]["code"] == "not_ready"
    finally:
        s.close()


# --- voices ---

def test_v2_voices_load_and_state(server):
    state = server.get("/state")
    assert state["backend"] == "qwentts" and state["ready"] is True
    assert state["active_voice"] == "alpha"
    assert state["voices"] == [{"id": "alpha", "display_name": "Alpha"},
                               {"id": "beta", "display_name": "Beta"}]
    assert server.get("/voices") == {"voices": state["voices"],
                                     "active_voice": "alpha"}


def test_put_voice_switches_synthesis(server):
    server.post("/clients/active", {"channel": "mac"})
    seq = 0
    for voice, transcript in (("beta", "beta words here"),
                              ("alpha", "alpha transcript"),
                              ("beta", "beta words here")):
        status, state = server.json("PUT", "/voice", {"voice": voice})
        assert status == 200 and state["active_voice"] == voice
        server.post("/speak", {"text": f"in {voice}."})
        _, headers, wav = server.segment("mac", after=seq)
        seq = int(headers["X-Seq"])
        assert sample_of(wav) == voice_sample(transcript)
    assert [e["ref_text"] for e in server.stub_log()][-3:] == [
        "beta words here", "alpha transcript", "beta words here"]


def test_put_voice_errors(server):
    status, body = server.json("PUT", "/voice", {"voice": "nope"})
    assert status == 404 and body["error"]["code"] == "unknown_voice"
    broken = Path(server.app.library.voices_dir) / "broken"
    broken.mkdir()
    (broken / "reference.wav").write_bytes(b"not a wav at all")
    (broken / "transcript.txt").write_text("words")
    status, body = server.json("PUT", "/voice", {"voice": "broken"})
    assert status == 422 and body["error"]["code"] == "voice_invalid"


def test_voice_upload_rename_delete(server):
    raw, ctype = multipart({
        "id": ("gamma", None), "display_name": ("Gamma", None),
        "audio": (wav_bytes(), "ref.wav"), "transcript": ("gamma text", None),
    })
    status, _, body = server.request(
        "POST", "/voices", raw=raw, headers={"Content-Type": ctype})
    assert status == 201
    assert json.loads(body) == {"id": "gamma", "display_name": "Gamma"}
    status, _, body = server.request(
        "POST", "/voices", raw=raw, headers={"Content-Type": ctype})
    assert status == 409
    assert json.loads(body)["error"]["code"] == "voice_exists"

    bad, ctype2 = multipart({
        "id": ("delta", None), "display_name": ("D", None),
        "audio": (b"RIFFjunk", "x.wav"), "transcript": ("t", None),
    })
    status, _, body = server.request(
        "POST", "/voices", raw=bad, headers={"Content-Type": ctype2})
    assert status == 422

    assert server.json("PATCH", "/voices/gamma",
                       {"display_name": "Gamma Two"}) == (
        200, {"id": "gamma", "display_name": "Gamma Two"})
    status, body = server.json("DELETE", "/voices/alpha")
    assert status == 409 and body["error"]["code"] == "voice_active"
    assert server.json("DELETE", "/voices/gamma") == (200, {"ok": True})
    assert "gamma" not in [v["id"] for v in server.get("/voices")["voices"]]
    assert server.json("DELETE", "/voices/gamma")[0] == 404


# --- settings ---

def test_settings_persist_across_restart(stub_bin, data_dir):
    s = Server(stub_bin, data_dir, initial_voice="alpha")
    try:
        status, state = s.json("PATCH", "/settings", {"effects": True})
        assert status == 200
        assert state["effects"] is True
        assert "default_rate" not in state
        assert "rate" not in state
        assert s.json("PUT", "/voice", {"voice": "beta"})[0] == 200
        assert s.json("PATCH", "/settings", {"default_rate": 1.5})[0] == 400
        assert s.json("PATCH", "/settings", {"rate": 1.5})[0] == 400
        assert s.json("PATCH", "/settings", {"bogus": 1})[0] == 400
    finally:
        s.close()
    saved = json.loads((data_dir / "settings.json").read_text())
    assert saved == {"active_voice": "beta", "effects": True}
    s = Server(stub_bin, data_dir, initial_voice="alpha")
    try:
        state = s.get("/state")
        assert state["active_voice"] == "beta"
        assert state["effects"] is True
        assert "default_rate" not in state
        assert "rate" not in state
    finally:
        s.close()


def test_legacy_settings_keys_dropped(stub_bin, data_dir):
    (data_dir / "settings.json").write_text(json.dumps({
        "active_voice": "beta", "effects": False,
        "default_rate": 1.4,
        "rate": 1.4,
        "default_synthesis_rate": 1.25}))
    s = Server(stub_bin, data_dir)
    try:
        state = s.get("/state")
        assert state["active_voice"] == "beta"
        assert "default_rate" not in state
        assert "rate" not in state
        health = s.get("/health")
        assert "default_rate" not in health
        assert "rate" not in health
        # Trigger save by updating a setting; legacy keys must be dropped on save
        s.json("PATCH", "/settings", {"effects": True})
    finally:
        s.close()
    saved = json.loads((data_dir / "settings.json").read_text())
    assert saved == {"active_voice": "beta", "effects": True}
    assert "default_rate" not in saved
    assert "rate" not in saved
    assert "default_synthesis_rate" not in saved

def test_channel_gc_clears_active(server):
    server.post("/clients/active", {"channel": "gone"})
    mgr = server.app.channels
    mgr.gc(now=time.monotonic() + serve.CHANNEL_GC_SECONDS + 1)
    assert server.get("/health")["active_client"] is None
    assert "gone" not in server.get("/state")["channels"]


def test_segment_store_position_transitions(tmp_path):
    from speaker import SegmentStore

    clip = tmp_path / "clip.wav"
    with wave.open(str(clip), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(24000)
        w.writeframes(b"\0\0" * 2400)

    store = SegmentStore()
    # 4 segments with blocks (0, 0), (1, 1), (2, 3), (4, 4)
    blocks = [(0, 0), (1, 1), (2, 3), (4, 4)]
    for b in blocks:
        store.submit(clip, b)

    # None before any report
    assert store.position() is None

    # Never-reported client fetching segments still gets None
    store.next_after(0, 0)
    assert store.position() is None

    # Report played 1: next segment (seq 2, block (1,1)) is playing if fetched
    store.next_after(1, 0)  # fetches seq 2
    store.report_played(1)
    assert store.position() == 1

    # Report played 2: next segment (seq 3, block (2,3)) is playing if fetched
    store.next_after(2, 0)  # fetches seq 3
    store.report_played(2)
    assert store.position() == 2

    # Report all played: nothing buffered left, falls back to _played_block lo
    store.next_after(3, 0)  # fetches seq 4
    store.report_played(4)
    assert store.position() == 4

    # Invalidate clears position
    store.invalidate()
    assert store.position() is None

    # Stale reports pre-dating invalidate are ignored
    store.report_played(4)
    assert store.position() is None

    # Segment with block None is skipped in position resolution
    store.submit(clip, None)
    store.next_after(4, 0)
    # Force epoch advancement report
    store.report_played(5)
    assert store.position() is None


def test_seek_relative_to_playback(server):
    ch = "relseek"
    blocks = [f"Block {i}." for i in range(5)]
    _, body = server.post("/speak", {"blocks": blocks, "channel": ch})
    assert body["queued"] == 5

    # Fetch the first segment; determine its block range
    status, headers, _ = server.segment(ch, after=0)
    assert status == 200
    seq1 = int(headers["X-Seq"])
    lo1, _ = [int(x) for x in headers["X-Block"].split(",")]

    # Fetch second segment while reporting seq1 played
    status, headers, _ = server.segment(ch, after=seq1, played=seq1)
    assert status == 200
    seq2 = int(headers["X-Seq"])
    lo2, _ = [int(x) for x in headers["X-Block"].split(",")]

    # Playing segment is seq2; delta +1 must be relative to lo2
    status, body = server.post("/seek", {"delta": 1, "channel": ch})
    assert status == 200
    expected_target = min(lo2 + 1, 4)
    assert body["block"] == expected_target

    # Next segment after seek should start at or cover the seek target
    status, headers, _ = server.segment(ch, after=0)
    assert status == 200
    new_lo, _ = [int(x) for x in headers["X-Block"].split(",")]
    assert new_lo == expected_target

    # Seek delta -1 relative to the new playback
    new_seq = int(headers["X-Seq"])
    # Fetch another segment or report played
    status, headers2, _ = server.segment(ch, after=new_seq, played=new_seq)
    if status == 200:
        playing_lo = int(headers2["X-Block"].split(",")[0])
    else:
        playing_lo = new_lo
    status, body = server.post("/seek", {"delta": -1, "channel": ch})
    assert status == 200
    assert body["block"] == max(0, playing_lo - 1)


def test_seek_clamping(server):
    ch = "clampseek"
    blocks = ["Zero.", "One.", "Two."]
    server.post("/speak", {"blocks": blocks, "channel": ch})

    status, headers, _ = server.segment(ch, after=0)
    assert status == 200
    seq1 = int(headers["X-Seq"])
    # Fetch seq2 and report seq1 played
    server.segment(ch, after=seq1, played=seq1)

    # Huge negative delta clamps to 0
    status, body = server.post("/seek", {"delta": -50, "channel": ch})
    assert status == 200
    assert body["block"] == 0

    # Huge positive delta clamps to max block (2)
    status, body = server.post("/seek", {"delta": 50, "channel": ch})
    assert status == 200
    assert body["block"] == 2


def test_seek_chaining_without_playback(server):
    ch = "chainseek"
    blocks = ["Zero.", "One.", "Two.", "Three.", "Four."]
    server.post("/speak", {"blocks": blocks, "channel": ch})

    # Without playback reports, first seek delta=1 targets lo + 1 = 1
    status, body = server.post("/seek", {"delta": 1, "channel": ch})
    assert status == 200
    assert body["block"] == 1

    # Second seek without playback reports chains from last seek target: 1 + 1 = 2
    status, body = server.post("/seek", {"delta": 1, "channel": ch})
    assert status == 200
    assert body["block"] == 2


def test_seek_playback_overrides_older_seek_target(server):
    ch = "overrideseek"
    blocks = ["Zero.", "One.", "Two.", "Three.", "Four."]
    server.post("/speak", {"blocks": blocks, "channel": ch})

    # Absolute seek to block 4
    status, body = server.post("/seek", {"block": 4, "channel": ch})
    assert status == 200
    assert body["block"] == 4

    # Client plays the segment produced by the seek (target was 4)
    status, headers, _ = server.segment(ch, after=0)
    assert status == 200
    seq = int(headers["X-Seq"])
    played_lo = int(headers["X-Block"].split(",")[0])
    assert played_lo == 4

    # Report played for this segment
    server.segment(ch, after=seq, played=seq, timeout=0.1)

    # Now delta -1 should step from current playback (4 - 1 = 3)
    status, body = server.post("/seek", {"delta": -1, "channel": ch})
    assert status == 200
    assert body["block"] == 3
