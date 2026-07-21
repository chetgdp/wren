"""Tests for the TTS daemon (model mocked). Run: uv run pytest tts/"""

import json
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from serve import (App, PCMPlayer, SegmentStore, Speaker, block_span,
                   chunk_text, make_server, pick_backend, sanitize_markdown)


def wait_for(cond, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if cond():
            return True
        time.sleep(0.01)
    return False


# --- sanitize_markdown ---

def test_sanitize_drops_fenced_code():
    out = sanitize_markdown("Run this:\n```py\nprint('hi')\n```\nDone.")
    assert "print" not in out
    assert "Run this:" in out and "Done." in out


def test_sanitize_unwraps_inline_code_and_links():
    out = sanitize_markdown("Use `serve.py` per [the docs](https://x.test/d).")
    assert out == "Use serve.py per the docs."


def test_sanitize_strips_headers_bullets_emphasis():
    out = sanitize_markdown("# Title\n- **bold** item\n2. second\n> quoted")
    assert out == "Title\nbold item\nsecond\nquoted"


def test_sanitize_strips_emoji():
    assert sanitize_markdown("Because light attracts bugs. 😄") == "Because light attracts bugs."
    assert sanitize_markdown("done ✅ → next ⚡") == "done next"


def test_sanitize_drops_table_separators():
    out = sanitize_markdown("| a | b |\n|---|---|\n| 1 | 2 |")
    assert "---" not in out and "|" not in out


# --- pick_backend ---

def test_pick_backend_explicit_passthrough():
    assert pick_backend("mlx") == "mlx"
    assert pick_backend("qwen-tts") == "qwen-tts"


def test_pick_backend_auto_resolves_to_installed_library():
    # The test env syncs the default (mlx) group, so auto must resolve to mlx.
    assert pick_backend("auto") == "mlx"


# --- chunk_text ---

def test_chunk_short_text_single_chunk():
    assert chunk_text("Hello there. General Kenobi.") == ["Hello there. General Kenobi."]


def test_chunk_groups_sentences_under_limit():
    chunks = chunk_text("One two. Three four. Five six.", max_chars=18)
    assert chunks == ["One two.", "Three four.", "Five six."]
    assert all(len(c) <= 18 for c in chunks)


def test_chunk_splits_oversize_sentence_on_word_boundary():
    chunks = chunk_text("alpha beta gamma delta", max_chars=12)
    assert chunks == ["alpha beta", "gamma delta"]


def test_chunk_limit_ramps_up_from_first_chars():
    text = " ".join(["word"] * 100)  # one long run, no sentence breaks
    chunks = chunk_text(text, max_chars=40, first_chars=10)
    assert len(chunks[0]) <= 10
    assert len(chunks[1]) <= 20
    assert all(len(c) <= 40 for c in chunks)
    assert any(len(c) > 20 for c in chunks)  # reaches max after ramping


# --- Speaker ---

class FakeHandle:
    def __init__(self):
        self.terminated = False

    def terminate(self):
        self.terminated = True

    def wait(self):
        time.sleep(0.01)


def make_speaker(played, synth_delay=0.0, max_chars=300, store=None):
    def synth(text, make_path):
        time.sleep(synth_delay)
        path = make_path()
        Path(path).write_text(text)
        yield path

    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()

    return Speaker(synth, store or play, max_chars=max_chars)


def test_streaming_synth_plays_each_segment():
    played = []

    def synth(text, make_path):  # streaming backend: several segments per text
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            yield path

    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()

    sp = Speaker(synth, play)
    sp.speak("alpha beta gamma")
    assert wait_for(lambda: played == ["alpha", "beta", "gamma"])


def test_preemption_abandons_in_flight_generation():
    played = []
    def synth(text, make_path):
        for word in text.split():
            time.sleep(0.05)
            path = make_path()
            Path(path).write_text(word)
            yield path
    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()

    sp = Speaker(synth, play)
    sp.speak("one two three four five six seven eight")
    time.sleep(0.12)  # let a couple of segments emit
    sp.speak("new.")
    assert wait_for(lambda: "new." in played)
    assert wait_for(lambda: sp.pending() == 0)
    time.sleep(0.1)
    assert played[-1] == "new."
    assert "eight" not in played  # old generation was abandoned mid-stream


def gated_streaming_speaker(played, emitted, go):
    def synth(text, make_path):
        go.wait(5)
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            emitted.append(word)
            yield path

    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()

    return Speaker(synth, play)


def test_pause_stalls_synthesis_after_lookahead_and_resume_continues():
    played, emitted = [], []
    go = threading.Event()
    sp = gated_streaming_speaker(played, emitted, go)
    sp.speak("one two three four five six")
    sp.pause()  # before go: pause is set for the whole generation
    go.set()
    assert wait_for(lambda: len(emitted) == Speaker.PAUSE_LOOKAHEAD)
    time.sleep(0.3)  # gate holds: no further segments while paused
    assert len(emitted) == Speaker.PAUSE_LOOKAHEAD
    sp.resume()
    assert wait_for(lambda: emitted == "one two three four five six".split())
    assert wait_for(lambda: played == emitted)


def test_preempting_speak_releases_paused_synthesis_gate():
    played, emitted = [], []
    go = threading.Event()
    sp = gated_streaming_speaker(played, emitted, go)
    sp.speak("one two three four five six")
    sp.pause()
    go.set()
    assert wait_for(lambda: len(emitted) == Speaker.PAUSE_LOOKAHEAD)
    sp.speak("fresh.")  # preempts: releases the gate, drops the old text
    assert wait_for(lambda: "fresh." in played)
    assert sp.paused() is False
    assert "six" not in emitted  # old generation abandoned at the gate


def test_speaker_plays_chunks_in_order():
    played = []
    sp = make_speaker(played, max_chars=12)
    n = sp.speak("alpha beta. gamma delta.")
    assert n == 2
    assert wait_for(lambda: len(played) == 2)
    assert played == ["alpha beta.", "gamma delta."]


def test_speak_preempts_previous_message():
    played = []
    sp = make_speaker(played, synth_delay=0.05, max_chars=12)
    sp.speak("old one. old two. old three. old four.")
    sp.speak("new text.")
    assert wait_for(lambda: "new text." in played)
    assert wait_for(lambda: sp.pending() == 0)
    time.sleep(0.1)  # let any stale in-flight chunk surface
    assert played[-1] == "new text."
    assert len([p for p in played if p.startswith("old")]) < 4


def test_append_does_not_preempt():
    played = []
    sp = make_speaker(played, synth_delay=0.02, max_chars=12)
    sp.speak("first part.")
    sp.speak("second part.", append=True)
    sp.speak("third part.", append=True)
    # Appends behind an in-flight synthesis coalesce, but everything plays
    # in order and nothing is preempted.
    assert wait_for(lambda: " ".join(played) == "first part. second part. third part.")


def test_speaker_factory_loads_in_synth_thread_and_sets_ready():
    played = []
    loaded_in = []

    def factory():
        loaded_in.append(threading.current_thread().name)
        def synth(text, make_path):
            path = make_path()
            Path(path).write_text(text)
            yield path
        return synth

    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()

    sp = Speaker(synth_factory=factory, play_fn=play)
    assert wait_for(sp.ready.is_set)
    sp.speak("hello there.")
    assert wait_for(lambda: played == ["hello there."])
    assert loaded_in[0] != threading.main_thread().name


def test_speaker_requires_exactly_one_synth_source():
    import pytest
    with pytest.raises(ValueError):
        Speaker()
    with pytest.raises(ValueError):
        Speaker(synth_fn=lambda t, p: None, synth_factory=lambda: None)


def test_backlog_coalesces_into_one_synth_call():
    calls = []
    def synth(text, make_path):
        calls.append(text)
        time.sleep(0.1)
        path = make_path()
        Path(path).write_text(text)
        yield path
    played = []
    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()

    sp = Speaker(synth, play)
    sp.speak("first.")
    time.sleep(0.02)  # first synth in progress; the rest queue behind it
    sp.speak("second.", append=True)
    sp.speak("third.", append=True)
    sp.speak("fourth.", append=True)
    assert wait_for(lambda: "fourth." in " ".join(played))
    assert len(calls) == 2  # first alone, backlog merged into one call
    assert calls[1] == "second. third. fourth."


def test_stop_clears_queue():
    played = []
    sp = make_speaker(played, synth_delay=0.05, max_chars=12)
    sp.speak("one one. two two. three three. four four.")
    sp.stop()
    time.sleep(0.2)
    assert sp.pending() == 0
    assert len(played) < 4


# --- PCMPlayer ---

class FakeStream:
    def __init__(self):
        self.samples = 0

    def write(self, block):
        self.samples += len(block)
        time.sleep(0.005)


def make_pcm_player():
    player = PCMPlayer()
    player._stream = FakeStream()  # bypass _ensure's sounddevice setup
    player._sr = 24000
    return player


def test_pcm_player_writes_all_blocks(tmp_path):
    import numpy as np
    import soundfile as sf
    path = tmp_path / "a.wav"
    sf.write(path, np.zeros(24000, dtype="float32"), 24000)

    player = make_pcm_player()
    handle = player(str(path))
    handle.wait()
    assert player._stream.samples == 24000


def test_pcm_player_pause_stalls_and_resume_continues(tmp_path):
    import numpy as np
    import soundfile as sf
    path = tmp_path / "a.wav"
    sf.write(path, np.zeros(24000, dtype="float32"), 24000)

    player = make_pcm_player()
    player.pause()
    handle = player(str(path))
    t = threading.Thread(target=handle.wait)
    t.start()
    time.sleep(0.1)
    assert player._stream.samples == 0  # paused before the first block
    player.resume()
    t.join(timeout=5)
    assert not t.is_alive()
    assert player._stream.samples == 24000


def test_pcm_player_terminate_unblocks_while_paused(tmp_path):
    import numpy as np
    import soundfile as sf
    path = tmp_path / "a.wav"
    sf.write(path, np.zeros(24000, dtype="float32"), 24000)

    player = make_pcm_player()
    player.pause()
    handle = player(str(path))
    t = threading.Thread(target=handle.wait)
    t.start()
    time.sleep(0.05)
    handle.terminate()
    t.join(timeout=5)
    assert not t.is_alive()


def test_pcm_player_terminate_stops_mid_write(tmp_path):
    import numpy as np
    import soundfile as sf
    path = tmp_path / "a.wav"
    sf.write(path, np.zeros(24000 * 4, dtype="float32"), 24000)

    player = make_pcm_player()
    handle = player(str(path))
    t = threading.Thread(target=handle.wait)
    t.start()
    time.sleep(0.01)
    handle.terminate()
    t.join(timeout=5)
    assert not t.is_alive()
    assert player._stream.samples < 24000 * 4


# --- HTTP endpoints ---

def start_server(played, ready=True, token=None, store=None):
    app = App(model_id="test-model", token=token, segments=store)
    if ready:
        app.speaker = make_speaker(played, store=store)
    server = make_server(app, port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def raw_request(port, path, body=None, method=None, headers=None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    return urllib.request.urlopen(req, timeout=5)


def request(port, path, body=None, method=None, headers=None):
    with raw_request(port, path, body, method, headers) as resp:
        return resp.status, json.loads(resp.read())


def test_health(tmp_path):
    server, port = start_server([])
    try:
        status, body = request(port, "/health")
        assert status == 200
        assert body["ok"] is True
        assert body["ready"] is True
        assert body["model"] == "test-model"
    finally:
        server.shutdown()


def test_loading_state_health_ok_speak_503():
    server, port = start_server([], ready=False)
    try:
        status, body = request(port, "/health")
        assert status == 200
        assert body["ready"] is False

        try:
            request(port, "/speak", {"text": "hello"})
            assert False, "expected 503"
        except urllib.error.HTTPError as e:
            assert e.code == 503
    finally:
        server.shutdown()


def test_speak_sanitizes_and_queues():
    played = []
    server, port = start_server(played)
    try:
        status, body = request(port, "/speak", {"text": "Hello **world**. ```skip```"})
        assert status == 200
        assert body["queued"] == 1
        assert wait_for(lambda: played == ["Hello world."])
    finally:
        server.shutdown()


def test_speak_append_endpoint_queues_in_order():
    played = []
    server, port = start_server(played)
    try:
        request(port, "/speak", {"text": "One."})
        request(port, "/speak", {"text": "Two.", "append": True})
        assert wait_for(lambda: played == ["One.", "Two."])
    finally:
        server.shutdown()


def test_speak_rejects_missing_text_and_bad_json():
    server, port = start_server([])
    try:
        for payload in ({}, {"text": "  "}):
            try:
                request(port, "/speak", payload)
                assert False, "expected 400"
            except urllib.error.HTTPError as e:
                assert e.code == 400

        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/speak", data=b"not json", method="POST"
        )
        try:
            urllib.request.urlopen(req, timeout=5)
            assert False, "expected 400"
        except urllib.error.HTTPError as e:
            assert e.code == 400
    finally:
        server.shutdown()


def test_stop_endpoint():
    server, port = start_server([])
    try:
        status, body = request(port, "/stop", {})
        assert status == 200
        assert body["ok"] is True
    finally:
        server.shutdown()


# --- block tracking (read-mode highlight) ---

def test_block_span_interpolates_sentences_by_time():
    layout = [(0, 40), (1, 40), (2, 40)]  # 40 chars ~ 3s of speech each
    assert block_span(layout, 0.0, 1.0) == (0, 0)
    assert block_span(layout, 3.5, 4.0) == (1, 1)
    assert block_span(layout, 2.5, 4.0) == (0, 1)
    assert block_span(layout, 50.0, 60.0) == (2, 2)  # past estimate: tail


def test_block_span_uses_given_speech_rate():
    layout = [(0, 10), (1, 10)]
    # At 10 chars/sec sentence 0 covers 0..1s; the default ~13.3 would
    # already have moved on by 1.2s.
    assert block_span(layout, 0.0, 0.9, chars_per_sec=10) == (0, 0)
    assert block_span(layout, 1.2, 2.0, chars_per_sec=10) == (1, 1)


def _write_wav(path, seconds, sr=16000):
    import wave
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\x00\x00" * int(seconds * sr))


def test_completed_batch_recalibrates_speech_rate():
    import serve
    try:
        import soundfile  # noqa: F401  (_wav_seconds needs it)
    except ImportError:
        return
    measured_rate = 10.0  # this fake voice speaks 10 chars/sec

    def synth(text, make_path):
        path = make_path()
        _write_wav(path, seconds=len(text) / measured_rate)
        yield path

    class Handle:
        def terminate(self):
            pass

        def wait(self):
            pass

    sp = Speaker(synth, lambda path: Handle())
    assert sp._chars_per_sec == serve.CHARS_PER_SEC
    sp.speak(blocks=[(0, "x" * 40 + ".")])
    expected = 0.5 * serve.CHARS_PER_SEC + 0.5 * measured_rate
    assert wait_for(lambda: abs(sp._chars_per_sec - expected) < 0.2)
    release = threading.Event()
    played = []
    seen_blocks = []

    class GatedHandle:
        def terminate(self):
            release.set()

        def wait(self):
            release.wait(timeout=5)

    def synth(text, make_path):
        path = make_path()
        Path(path).write_text(text)
        yield path

    def play(path):
        played.append(Path(path).read_text())
        return GatedHandle()

    sp = Speaker(synth, play)
    sp.speak(blocks=[(0, "first block."), (1, "second block.")])
    assert wait_for(lambda: sp.current_block() is not None)
    seen_blocks.append(sp.current_block())
    assert seen_blocks[0][0] == 0
    release.set()
    assert wait_for(lambda: played and "second block." in " ".join(played))
    assert wait_for(lambda: sp.current_block() is None and sp.pending() == 0)


def test_plain_text_speak_has_no_block():
    played = []
    sp = make_speaker(played)
    sp.speak("no blocks here.")
    assert wait_for(lambda: played == ["no blocks here."])
    assert sp.current_block() is None


def test_coalesced_batch_reports_block_range():
    calls = []
    played_blocks = []

    def synth(text, make_path):
        calls.append(text)
        time.sleep(0.1)
        path = make_path()
        Path(path).write_text(text)
        yield path

    class Handle:
        def terminate(self):
            pass

        def wait(self):
            played_blocks.append(sp.current_block())

    sp = Speaker(synth, lambda path: Handle())
    sp.speak(blocks=[(0, "first.")])
    time.sleep(0.02)  # first synth in flight; the rest coalesce behind it
    sp.speak(blocks=[(1, "second."), (2, "third."), (3, "fourth.")], append=True)
    assert wait_for(lambda: len(played_blocks) == 2 and sp.pending() == 0)
    assert played_blocks[0] == (0, 0)
    assert played_blocks[1] == (1, 3)  # merged batch spans its blocks


def test_speak_blocks_endpoint_sanitizes_and_keeps_indices():
    played = []
    server, port = start_server(played)
    try:
        status, body = request(port, "/speak",
                               {"blocks": ["One.", "```dropped```", "**Two.**"]})
        assert status == 200
        assert body["queued"] == 2
        assert wait_for(lambda: played == ["One.", "Two."])

        status, body = request(port, "/health")
        assert "block" in body
    finally:
        server.shutdown()


def test_speak_blocks_endpoint_rejects_non_strings():
    server, port = start_server([])
    try:
        try:
            request(port, "/speak", {"blocks": ["ok", 5]})
            assert False, "expected 400"
        except urllib.error.HTTPError as e:
            assert e.code == 400
    finally:
        server.shutdown()


# --- seek ---

def test_seek_back_replays_from_target():
    played = []
    sp = make_speaker(played)
    sp.speak(blocks=[(0, "zero."), (1, "one."), (2, "two.")])
    assert wait_for(lambda: "two." in " ".join(played) and sp.pending() == 0)

    target = sp.seek(-2)  # finished on block 2 -> back to 0
    assert target == 0
    assert wait_for(lambda: " ".join(played).count("zero.") == 2)
    assert wait_for(lambda: sp.pending() == 0)
    assert " ".join(played).endswith("zero. one. two.")


def test_seek_clamps_to_block_range_and_survives_repeats():
    played = []
    sp = make_speaker(played)
    sp.speak(blocks=[(0, "zero."), (1, "one.")])
    assert wait_for(lambda: sp.pending() == 0 and "one." in " ".join(played))
    assert sp.seek(10) == 1  # clamped to last block
    assert wait_for(lambda: sp.pending() == 0)
    assert sp.seek(-10) == 0  # full list retained after a prior seek


def test_forward_seek_skips_past_current_batch_backward_before_it():
    played = []
    sp = make_speaker(played)
    sp.speak(blocks=[(i, f"s{i}.") for i in range(8)])
    assert wait_for(lambda: sp.pending() == 0 and not sp.speaking())

    # Position is batch-granular: while batch (2,4) plays, j must land after
    # the batch (5), not on a sentence inside it that was already heard.
    sp._current_block = (2, 4)
    assert sp.seek(1) == 5
    assert wait_for(lambda: sp.pending() == 0 and not sp.speaking())

    sp._current_block = (2, 4)
    assert sp.seek(-1) == 1
    assert wait_for(lambda: sp.pending() == 0 and not sp.speaking())


def test_rapid_seeks_chain_from_the_previous_target():
    # A second seek during the post-seek synthesis gap (nothing playing yet)
    # must move relative to the first seek's target, not reset to the start.
    played = []
    sp = make_speaker(played, synth_delay=0.2)
    sp.speak(blocks=[(i, f"s{i}.") for i in range(8)])
    assert wait_for(lambda: played)  # first sentence is playing/played
    first = sp.seek(1)
    second = sp.seek(1)  # synth for `first` still in flight
    assert second == first + 1
    assert sp.seek(-1) == first


def test_seek_absolute_block():
    played = []
    sp = make_speaker(played)
    sp.speak(blocks=[(i, f"s{i}.") for i in range(5)])
    assert wait_for(lambda: sp.pending() == 0 and not sp.speaking())
    assert sp.seek(target=2) == 2
    assert wait_for(lambda: sp.pending() == 0)
    assert sp.seek(target=99) == 4  # clamped


def test_seek_endpoint_absolute():
    played = []
    server, port = start_server(played)
    try:
        request(port, "/speak", {"blocks": ["Zero.", "One.", "Two."]})
        assert wait_for(lambda: "Two." in " ".join(played))
        status, body = request(port, "/seek", {"block": 0})
        assert status == 200
        assert body == {"ok": True, "block": 0}

        try:
            request(port, "/seek", {"block": "x"})
            assert False, "expected 400"
        except urllib.error.HTTPError as e:
            assert e.code == 400
    finally:
        server.shutdown()


def test_seek_without_blocks_returns_none():
    played = []
    sp = make_speaker(played)
    sp.speak("plain text.")
    assert sp.seek(1) is None


def test_seek_endpoint():
    played = []
    server, port = start_server(played)
    try:
        status, body = request(port, "/seek", {"delta": 1})
        assert status == 200
        assert body["ok"] is False  # nothing spoken yet

        request(port, "/speak", {"blocks": ["Zero.", "One.", "Two."]})
        assert wait_for(lambda: "Two." in " ".join(played))
        status, body = request(port, "/seek", {"delta": -1})
        assert status == 200
        assert body["ok"] is True
        assert isinstance(body["block"], int)

        try:
            request(port, "/seek", {"delta": 0})
            assert False, "expected 400"
        except urllib.error.HTTPError as e:
            assert e.code == 400
    finally:
        server.shutdown()


class FakePausablePlayer:
    def __init__(self):
        self.paused = False

    def pause(self):
        self.paused = True

    def resume(self):
        self.paused = False

    def __call__(self, path):
        return FakeHandle()


def start_pausable_server():
    app = App(model_id="test-model")

    def synth(text, make_path):
        path = make_path()
        Path(path).write_text(text)
        yield path

    app.speaker = Speaker(synth, FakePausablePlayer())
    server = make_server(app, port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], app.speaker


def test_pause_resume_endpoints_and_health_flag():
    server, port, speaker = start_pausable_server()
    try:
        status, body = request(port, "/pause", {})
        assert status == 200
        assert body == {"ok": True, "paused": True}
        assert request(port, "/health")[1]["paused"] is True

        status, body = request(port, "/resume", {})
        assert status == 200
        assert body == {"ok": True, "paused": False}
        assert request(port, "/health")[1]["paused"] is False
    finally:
        server.shutdown()


def test_pause_works_without_pausable_player():
    # The play fn has no pause(); /pause still gates synthesis and reports
    # paused (client-playback sinks and the afplay fallback hit this path).
    server, port = start_server([])
    try:
        status, body = request(port, "/pause", {})
        assert status == 200
        assert body == {"ok": True, "paused": True}
        assert request(port, "/health")[1]["paused"] is True
    finally:
        server.shutdown()


def test_stop_and_preempting_speak_clear_pause():
    server, port, speaker = start_pausable_server()
    try:
        request(port, "/pause", {})
        request(port, "/stop", {})
        assert speaker.paused() is False

        request(port, "/pause", {})
        request(port, "/speak", {"text": "fresh."})
        assert speaker.paused() is False
    finally:
        server.shutdown()


def _sine(sr=24000, seconds=1.0, freq=440.0):
    import numpy as np
    t = np.arange(int(sr * seconds)) / sr
    return np.sin(2 * np.pi * freq * t).astype("float32")


def test_wrap_fx_processes_segments_in_place(tmp_path):
    import numpy as np
    import soundfile as sf
    from serve import wrap_fx

    sr = 24000
    original = _sine(sr)
    counter = [0]

    def make_path():
        counter[0] += 1
        return str(tmp_path / f"{counter[0]}.wav")

    def synth(text, make_path):
        for _ in range(2):
            path = make_path()
            sf.write(path, original, sr)
            yield path

    wrapped = wrap_fx(synth, ring_freq=40.0, ring_mix=0.12)
    paths = list(wrapped("hello", make_path))
    assert len(paths) == 2
    for path in paths:
        audio, out_sr = sf.read(path, dtype="float32")
        assert out_sr == sr
        assert len(audio) == len(original)
        assert not np.allclose(audio, original)  # actually processed


def test_droidfx_is_continuous_across_segments():
    """Processing one buffer whole vs split in two must match: gapless
    playback concatenates segments, so any state reset clicks at the join."""
    import numpy as np
    from fx import DroidFX

    sr = 24000
    audio = _sine(sr, seconds=2.0)
    whole = DroidFX().process(audio, sr)

    fx = DroidFX()
    half = len(audio) // 2
    split = np.concatenate([fx.process(audio[:half], sr),
                            fx.process(audio[half:], sr)])
    assert np.allclose(whole, split, atol=1e-4)


# --- SegmentStore / client playback ---

def _seg_file(tmp_path, name, data):
    path = tmp_path / name
    path.write_bytes(data)
    return str(path)


def test_segment_store_orders_and_times_out(tmp_path):
    store = SegmentStore()
    store.submit(_seg_file(tmp_path, "a.wav", b"aaa"), (0, 0))
    store.submit(_seg_file(tmp_path, "b.wav", b"bbb"), (1, 2))
    assert store.next_after(0, timeout=0) == (1, (0, 0), b"aaa", 0)
    assert store.next_after(1, timeout=0) == (2, (1, 2), b"bbb", 0)
    seq, block, data, epoch = store.next_after(2, timeout=0.05)
    assert data is None and epoch == 0


def test_segment_store_long_poll_wakes_on_submit(tmp_path):
    store = SegmentStore()
    result = []
    t = threading.Thread(
        target=lambda: result.append(store.next_after(0, timeout=5)))
    t.start()
    time.sleep(0.05)
    store.submit(_seg_file(tmp_path, "a.wav", b"aaa"), None)
    t.join(timeout=5)
    assert result == [(1, None, b"aaa", 0)]


def test_segment_store_invalidate_clears_and_bumps_epoch(tmp_path):
    store = SegmentStore()
    store.submit(_seg_file(tmp_path, "a.wav", b"aaa"), None)
    store.invalidate()
    seq, block, data, epoch = store.next_after(0, timeout=0)
    assert data is None and epoch == 1
    # seq stays monotonic across invalidation
    store.submit(_seg_file(tmp_path, "b.wav", b"bbb"), None)
    assert store.next_after(0, timeout=0) == (2, None, b"bbb", 1)


def test_segment_store_overflow_drops_oldest(tmp_path):
    store = SegmentStore(max_bytes=5)
    store.submit(_seg_file(tmp_path, "a.wav", b"aaa"), None)
    store.submit(_seg_file(tmp_path, "b.wav", b"bbb"), None)
    seq, block, data, epoch = store.next_after(0, timeout=0)
    assert (seq, data) == (2, b"bbb")  # oldest dropped, newest kept


def test_speaker_with_client_sink_buffers_instead_of_playing(tmp_path):
    store = SegmentStore()
    sp = make_speaker([], store=store)
    sp.speak("hello there.")
    assert wait_for(lambda: store.next_after(0, timeout=0)[2] is not None)
    assert store.next_after(0, timeout=0)[2] == b"hello there."
    assert wait_for(lambda: sp.pending() == 0)


def test_speaker_preempt_invalidates_client_sink(tmp_path):
    store = SegmentStore()
    sp = make_speaker([], store=store)
    sp.speak("old text.")  # non-append speak preempts: epoch 1
    assert wait_for(lambda: store.next_after(0, timeout=0)[2] is not None)
    sp.speak("new text.")
    assert wait_for(
        lambda: store.next_after(0, timeout=0)[2] == b"new text.")
    assert store.epoch == 2
    sp.stop()
    assert store.epoch == 3
    assert store.next_after(0, timeout=0)[2] is None


def test_segment_endpoint_serves_wav_with_headers():
    store = SegmentStore()
    server, port = start_server([], store=store)
    try:
        request(port, "/speak", {"blocks": ["hello there."]})
        with raw_request(port, "/segment?after=0") as resp:
            assert resp.status == 200
            assert resp.headers["Content-Type"] == "audio/wav"
            assert resp.headers["X-Seq"] == "1"
            # every non-append /speak preempts, bumping the epoch once
            assert resp.headers["X-Epoch"] == "1"
            assert resp.headers["X-Block"] == "0,0"
            assert resp.read() == b"hello there."
    finally:
        server.shutdown()


def test_segment_endpoint_times_out_204_with_epoch():
    server, port = start_server([], store=SegmentStore())
    try:
        with raw_request(port, "/segment?after=0&timeout=0.05") as resp:
            assert resp.status == 204
            assert resp.headers["X-Epoch"] == "0"
    finally:
        server.shutdown()


def test_segment_endpoint_404_when_local_playback():
    server, port = start_server([])
    try:
        try:
            request(port, "/segment?after=0&timeout=0.05")
            assert False, "expected 404"
        except urllib.error.HTTPError as e:
            assert e.code == 404
    finally:
        server.shutdown()


def test_health_reports_playback_mode():
    server, port = start_server([], store=SegmentStore())
    try:
        assert request(port, "/health")[1]["playback"] == "client"
    finally:
        server.shutdown()
    server, port = start_server([])
    try:
        assert request(port, "/health")[1]["playback"] == "local"
    finally:
        server.shutdown()


def test_token_required_on_every_endpoint():
    played = []
    server, port = start_server(played, token="sekrit")
    try:
        for path, body in [("/health", None), ("/speak", {"text": "hi."}),
                           ("/segment?after=0&timeout=0.05", None)]:
            try:
                request(port, path, body)
                assert False, f"expected 401 for {path}"
            except urllib.error.HTTPError as e:
                assert e.code == 401
        auth = {"Authorization": "Bearer sekrit"}
        assert request(port, "/health", headers=auth)[0] == 200
        status, body = request(port, "/speak", {"text": "hi."}, headers=auth)
        assert status == 200 and body["queued"] == 1
        assert wait_for(lambda: played == ["hi."])
        try:
            request(port, "/health", headers={"Authorization": "Bearer nope"})
            assert False, "expected 401"
        except urllib.error.HTTPError as e:
            assert e.code == 401
    finally:
        server.shutdown()
# --- qwentts.cpp backend tests ---

import base64
import subprocess
from unittest.mock import patch

import pytest


def _make_wav_bytes(sr=24000, duration=0.5, freq=440):
    """Generate minimal WAV file bytes for testing."""
    import struct
    n_samples = int(sr * duration)
    data = b"".join(
        struct.pack("<h", int(32767 * 0.3 * ((i % 100) - 50) / 50))
        for i in range(n_samples)
    )
    return (
        b"RIFF"
        + struct.pack("<I", 36 + len(data))
        + b"WAVE"
        + b"fmt "
        + struct.pack("<IHHIIHH", 16, 1, sr, sr * 2, 2, 16, 0)
        + b"data"
        + struct.pack("<I", len(data))
        + data
    )


def _wav_b64(wav_bytes=None):
    """Base64-encode a minimal WAV for voice registration."""
    if wav_bytes is None:
        wav_bytes = _make_wav_bytes()
    return base64.b64encode(wav_bytes).decode("ascii")


class MockSubprocessProc:
    """Stub subprocess.Popen return value for mocking."""
    def __init__(self):
        self.returncode = 0

    def poll(self):
        return None

    def terminate(self):
        pass

    def wait(self, timeout=None):
        pass


def _make_qwentts_mock_server(port, ref_wav_b64, ref_text, stop_event=None):
    """Create a mock tts-server that mimics the real qwentts.cpp API.

    Endpoints:
      GET  /health                     -> {"status": "ok"}
      POST /v1/audio/voices            -> registers voice, returns {"name": ..., "status": "registered"}
      POST /v1/audio/speech            -> returns WAV audio bytes
      GET  /v1/audio/voices            -> returns voices list
      GET  /v1/models                  -> returns model list
    """
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import json as _json

    class MockHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
            elif self.path == "/v1/audio/voices":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                body = _json.dumps({
                    "voices": [{"name": "serve_clone", "kind": "registered"}],
                })
                self.wfile.write(body.encode())
            elif self.path == "/v1/models":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                body = _json.dumps({
                    "object": "list",
                    "data": [{"id": "mock-talker", "object": "model", "owned_by": "local"}],
                })
                self.wfile.write(body.encode())
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""

            if self.path == "/v1/audio/voices":
                parsed = _json.loads(body)
                name = parsed.get("name", "")
                if name == "serve_clone":
                    assert parsed.get("ref_text") == ref_text
                    assert parsed.get("wav_b64") == ref_wav_b64
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(f'{{"name":"{name}","status":"registered"}}'.encode())
            elif self.path == "/v1/audio/speech":
                parsed = _json.loads(body)
                voice = parsed.get("voice", "")
                fmt = parsed.get("response_format", "wav")
                assert voice == "serve_clone"
                wav_data = _make_wav_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav" if fmt == "wav" else "audio/pcm")
                self.end_headers()
                self.wfile.write(wav_data)
            else:
                self.send_response(404)
                self.end_headers()

    server = HTTPServer(("127.0.0.1", port), MockHandler)
    server.timeout = 1
    def serve_loop():
        while not stop_event.is_set():
            server.handle_request()
    t = threading.Thread(target=serve_loop, daemon=True)
    t.start()
    return server


def test_qwentts_backend_pick_backend_choice():
    assert pick_backend("qwentts") == "qwentts"


def test_qwentts_load_synth_sends_correct_http_requests(tmp_path):
    """Test that load_qwentts_synth correctly communicates with tts-server."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    stop_event = threading.Event()
    server = _make_qwentts_mock_server(port, _wav_b64(), "ref text here", stop_event)
    try:
        ref_wav = tmp_path / "ref.wav"
        ref_wav.write_bytes(_make_wav_bytes())

        from serve import load_qwentts_synth

        # Mock subprocess.Popen so it doesn't actually spawn a process.
        with patch("serve.subprocess.Popen", return_value=MockSubprocessProc()):
            synth = load_qwentts_synth(
                model_id="mock-talker",
                ref_audio=ref_wav,
                ref_text="ref text here",
                language="English",
                device="auto",
                qwentts_bin="/fake/path",
                qwentts_model="/fake/model.gguf",
                qwentts_codec="/fake/codec.gguf",
                qwentts_port=port,
            )

        # Run synth.
        output_files = []
        for path in synth("Hello world.", lambda: str(tmp_path / f"out_{id(synth)}.wav")):
            output_files.append(path)
            assert Path(path).exists()
            with open(path, "rb") as f:
                assert f.read(4) == b"RIFF"

        assert len(output_files) == 1
    finally:
        stop_event.set()
        server.server_close()


def test_qwentts_load_synth_child_death_error(tmp_path):
    """Test that synth raises when tts-server is not reachable."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    ref_wav = tmp_path / "ref.wav"
    ref_wav.write_bytes(_make_wav_bytes())

    from serve import load_qwentts_synth

    # Mock Popen: the child "runs" but nothing listens on the port, and the
    # startup poll bails as soon as poll() reports the child exited.
    class DeadProc(MockSubprocessProc):
        def __init__(self):
            super().__init__()
            self._polls = 0

        def poll(self):
            # Alive for the first few polls, then dead.
            self._polls += 1
            return None if self._polls < 3 else 1

    with patch("serve.subprocess.Popen", return_value=DeadProc()):
        with pytest.raises(RuntimeError) as exc_info:
            load_qwentts_synth(
                model_id="mock-talker",
                ref_audio=ref_wav,
                ref_text="ref text here",
                language="English",
                device="auto",
                qwentts_bin="/fake/path",
                qwentts_model="/fake/model.gguf",
                qwentts_codec="/fake/codec.gguf",
                qwentts_port=port,
            )
    assert "exited during startup" in str(exc_info.value)


def test_qwentts_cleanup_qwentts():
    """Test that _cleanup_qwentts terminates a running process."""
    from serve import _cleanup_qwentts
    import serve

    mock_proc = MockSubprocessProc()
    original = serve._qwentts_process
    serve._qwentts_process = mock_proc

    # poll() returns None (still alive), so terminate() is called.
    _cleanup_qwentts()

    assert serve._qwentts_process is None
    serve._qwentts_process = original


def test_qwentts_load_synth_requires_all_flags(tmp_path):
    """Test that load_qwentts_synth fails if any required flag is missing."""
    ref_wav = tmp_path / "ref.wav"
    ref_wav.write_bytes(_make_wav_bytes())

    from serve import load_qwentts_synth

    with pytest.raises(RuntimeError) as exc_info:
        load_qwentts_synth(
            model_id="mock",
            ref_audio=ref_wav,
            ref_text="ref",
            language="English",
            qwentts_bin="/path",
        )
    assert "qwentts backend requires" in str(exc_info.value)


def test_qwentts_pick_free_port():
    from serve import _pick_free_port
    import socket

    port = _pick_free_port()
    assert 0 < port < 65536
    # The port is actually bindable after being picked.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", port))


def test_qwentts_synth_failure_after_server_stops(tmp_path):
    """synth raises RuntimeError (not SystemExit) once tts-server is gone,
    so Speaker's except-Exception paths can handle it."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    stop_event = threading.Event()
    server = _make_qwentts_mock_server(port, _wav_b64(), "ref text here", stop_event)
    try:
        ref_wav = tmp_path / "ref.wav"
        ref_wav.write_bytes(_make_wav_bytes())

        from serve import load_qwentts_synth

        with patch("serve.subprocess.Popen", return_value=MockSubprocessProc()):
            synth = load_qwentts_synth(
                model_id="mock-talker",
                ref_audio=ref_wav,
                ref_text="ref text here",
                language="English",
                device="auto",
                qwentts_bin="/fake/path",
                qwentts_model="/fake/model.gguf",
                qwentts_codec="/fake/codec.gguf",
                qwentts_port=port,
            )
    finally:
        stop_event.set()
        server.server_close()

    with pytest.raises(RuntimeError):
        list(synth("Hello.", lambda: str(tmp_path / "out.wav")))
