"""Tests for the TTS daemon (model mocked). Run: uv run pytest tts/"""

import argparse
import json
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import asdict, fields
from pathlib import Path

from serve import (MAX_BODY_BYTES, App, Config, PCMPlayer,
                   SegmentStore, Speaker, block_span, chunk_text,
                   default_config_path, effective_settings, load_config,
                   make_server, pick_backend, sanitize_markdown, stretch_wav)


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
    assert (sanitize_markdown("Because light attracts bugs. 😄")
            == "Because light attracts bugs.")
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
    assert (chunk_text("Hello there. General Kenobi.")
            == ["Hello there. General Kenobi."])


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


class PausableBlockingPlayer:
    """Play fn whose handle blocks while paused, like PCMPlayer: nothing is
    recorded as played until the segment actually gets to run."""

    def __init__(self, played):
        self.played = played
        self._paused = threading.Event()

    def pause(self):
        self._paused.set()

    def resume(self):
        self._paused.clear()

    def __call__(self, path):
        player = self
        text = Path(path).read_text()

        class Handle:
            def __init__(self):
                self.cancelled = threading.Event()

            def terminate(self):
                self.cancelled.set()

            def wait(self):
                while (player._paused.is_set()
                       and not self.cancelled.is_set()):
                    time.sleep(0.01)
                if not self.cancelled.is_set():
                    player.played.append(text)

        return Handle()


def gated_streaming_speaker(played, emitted, go):
    def synth(text, make_path):
        go.wait(5)
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            emitted.append(word)
            yield path

    return Speaker(synth, PausableBlockingPlayer(played))


def test_pause_stops_playhead_and_lookahead_budget_parks_synthesis():
    from serve import SynthWorker

    played, emitted = [], []
    go = threading.Event()
    sp = gated_streaming_speaker(played, emitted, go)
    sp.speak("one two three four five six")
    sp.pause()  # before go: paused for the whole generation
    go.set()
    # One segment sits at the stopped playhead plus LOOKAHEAD rendered
    # ahead; the budget then parks the worker with no pause-specific rule.
    limit = 1 + SynthWorker.LOOKAHEAD
    assert wait_for(lambda: len(emitted) == limit)
    time.sleep(0.3)  # budget spent: no further segments while paused
    assert len(emitted) == limit
    assert played == []  # the playhead really is stopped
    sp.resume()
    assert wait_for(lambda: emitted == "one two three four five six".split())
    assert wait_for(lambda: played == emitted)


def test_preempting_speak_clears_pause_and_drops_parked_batch():
    from serve import SynthWorker

    played, emitted = [], []
    go = threading.Event()
    sp = gated_streaming_speaker(played, emitted, go)
    sp.speak("one two three four five six")
    sp.pause()
    go.set()
    assert wait_for(lambda: len(emitted) == 1 + SynthWorker.LOOKAHEAD)
    sp.speak("fresh.")  # preempts: clears pause, drops the old text
    assert wait_for(lambda: "fresh." in played)
    assert sp.paused() is False
    assert "six" not in emitted  # old generation abandoned while parked


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
    assert wait_for(
        lambda: " ".join(played) == "first part. second part. third part.")


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


# --- SynthWorker: shared worker, lookahead budget ---

def _recording_play(played):
    def play(path):
        played.append(Path(path).read_text())
        return FakeHandle()
    return play


def test_model_loads_once_in_the_worker_thread():
    load_threads = []
    synth_threads = []

    def factory():
        load_threads.append(threading.get_ident())

        def synth(text, make_path):
            synth_threads.append(threading.get_ident())
            path = make_path()
            Path(path).write_text(text)
            yield path

        return synth

    played = []
    sp = Speaker(synth_factory=factory, play_fn=_recording_play(played))
    assert wait_for(sp.ready.is_set)
    sp.speak("one.")
    assert wait_for(lambda: played == ["one."])
    sp.speak("two.")
    assert wait_for(lambda: played == ["one.", "two."])
    assert len(load_threads) == 1  # one load, not one per utterance
    assert set(synth_threads) == set(load_threads)  # MLX: same thread
    assert load_threads[0] != threading.get_ident()


def test_paused_speaker_does_not_stall_the_shared_worker():
    from serve import SynthWorker

    go = threading.Event()
    emitted = []

    def synth(text, make_path):
        go.wait(5)
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            emitted.append(word)
            yield path

    worker = SynthWorker(synth_fn=synth)
    played_a, played_b = [], []
    a = Speaker(play_fn=PausableBlockingPlayer(played_a), worker=worker)
    b = Speaker(play_fn=_recording_play(played_b), worker=worker)

    a.speak("one two three four five")
    a.pause()  # before go: paused for the whole generation
    go.set()
    # a's stopped playhead spends its budget: one segment blocked at the
    # player plus LOOKAHEAD rendered ahead, then a parks.
    limit = 1 + SynthWorker.LOOKAHEAD
    assert wait_for(lambda: len(emitted) == limit)
    time.sleep(0.1)
    assert len(emitted) == limit  # a is parked

    # a's queue holds text but the worker is free to serve b immediately.
    b.speak("hello there.")
    assert wait_for(lambda: played_b == ["hello", "there."])

    a.resume()
    assert wait_for(lambda: played_a == "one two three four five".split())


def test_lookahead_budget_caps_rendering_at_playhead_plus_two():
    from serve import SynthWorker

    emitted = []
    release = threading.Event()

    def synth(text, make_path):
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            emitted.append(word)
            yield path

    playing = []

    class SlowHandle:
        def terminate(self):
            release.set()

        def wait(self):
            release.wait(5)

    def play(path):
        playing.append(Path(path).read_text())
        return SlowHandle()

    sp = Speaker(synth, play)
    sp.speak("a b c d e f g h")
    # one segment playing plus LOOKAHEAD rendered ahead, nothing more
    limit = 1 + SynthWorker.LOOKAHEAD
    assert wait_for(lambda: len(playing) == 1 and len(emitted) == limit)
    time.sleep(0.2)
    assert len(emitted) == limit  # budget spent: synthesis parked
    release.set()  # playback drains; rendering follows the playhead
    assert wait_for(lambda: playing == "a b c d e f g h".split())
    assert emitted == playing


def test_lookahead_pipelining_keeps_next_segment_ready():
    emitted = []
    starts = []  # (segment, segments rendered when it started playing)
    gates = []

    def synth(text, make_path):
        time.sleep(0.02)  # slow generation the lookahead must hide
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            emitted.append(word)
            yield path
            time.sleep(0.02)

    class GatedHandle:
        def __init__(self):
            self.event = threading.Event()
            gates.append(self.event)

        def terminate(self):
            self.event.set()

        def wait(self):
            self.event.wait(5)

    def play(path):
        starts.append((Path(path).read_text(), len(emitted)))
        return GatedHandle()

    sp = Speaker(synth, play)
    words = "a b c d e".split()
    sp.speak(" ".join(words))
    for i in range(len(words)):
        assert wait_for(lambda: len(gates) > i)
        # While segment i plays, the next one gets rendered: when i ends
        # there is no synthesis gap.
        assert wait_for(lambda: len(emitted) >= min(i + 2, len(words)))
        gates[i].set()
    assert wait_for(lambda: [seg for seg, _ in starts] == words)


def test_client_mode_budget_tracks_last_fetched_seq():
    from serve import SynthWorker

    emitted = []

    def synth(text, make_path):
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            emitted.append(word)
            yield path

    store = SegmentStore()
    sp = Speaker(synth, store)
    sp.speak("a b c d e f")
    # Nothing fetched: the playhead proxy sits at 0, so only LOOKAHEAD
    # segments render (no free-running full-message synthesis).
    assert wait_for(lambda: len(emitted) == SynthWorker.LOOKAHEAD)
    time.sleep(0.2)
    assert len(emitted) == SynthWorker.LOOKAHEAD

    seq, _, data, _ = store.next_after(0, timeout=1)
    assert data == b"a"
    # The fetch advanced the playhead proxy: one more segment renders.
    assert wait_for(lambda: len(emitted) == SynthWorker.LOOKAHEAD + 1)

    while True:  # a client draining the stream pulls the rest through
        seq, _, data, _ = store.next_after(seq, timeout=1)
        if data is None:
            break
    assert emitted == "a b c d e f".split()


def test_synth_raising_at_call_time_does_not_kill_the_worker():
    # The synth callable itself blows up (not its generator): the worker
    # must log it, drop that batch, and stay alive for the next utterance.
    played = []

    def synth(text, make_path):
        if "explode" in text:
            raise RuntimeError("boom at call time")

        def gen():
            path = make_path()
            Path(path).write_text(text)
            yield path

        return gen()

    sp = Speaker(synth, _recording_play(played))
    sp.speak("explode.")
    time.sleep(0.05)  # let the failing batch reach the worker
    sp.speak("after.")
    assert wait_for(lambda: played == ["after."])


def test_synth_raising_mid_stream_does_not_kill_the_worker():
    played = []

    def synth(text, make_path):
        path = make_path()
        Path(path).write_text(text.split()[0])
        yield path
        if "explode" in text:
            raise RuntimeError("boom mid-stream")

    sp = Speaker(synth, _recording_play(played))
    sp.speak("explode now")
    assert wait_for(lambda: "explode" in played)  # segment before the raise
    sp.speak("after.")
    assert wait_for(lambda: "after." in played)


def test_stale_segment_taken_is_a_noop_after_budget_reset():
    # The race: a stale-epoch segment popped from the play queue before the
    # preempting _drain() must not free budget after reset_budget re-based
    # it, or the worker transiently renders LOOKAHEAD+1 ahead.
    played = []
    sp = make_speaker(played)
    worker = sp._worker
    stale_epoch = sp._epoch
    sp._epoch += 1  # a preemption bumps the epoch...
    worker.reset_budget(sp)  # ...and re-bases the accounting
    sp._inflight = 1  # one new-epoch segment already rendered
    worker.segment_taken(sp, stale_epoch)  # late pop of a stale segment
    assert sp._inflight == 1  # must not free the new epoch's charge
    worker.segment_taken(sp, sp._epoch)  # a real new-epoch pop still frees
    assert sp._inflight == 0


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
        status, body = request(port, "/speak",
                               {"text": "Hello **world**. ```skip```"})
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


def test_web_origin_rejected_extension_and_no_origin_pass():
    played = []
    server, port = start_server(played)
    try:
        for path, body in (("/speak", {"text": "hi"}), ("/stop", {}),
                           ("/health", None)):
            try:
                request(port, path, body,
                        headers={"Origin": "https://evil.example"})
                assert False, "expected 403"
            except urllib.error.HTTPError as e:
                assert e.code == 403
        status, _ = request(port, "/speak", {"text": "One."},
                            headers={"Origin": "chrome-extension://abcdef"})
        assert status == 200
        status, _ = request(port, "/speak", {"text": "Two.", "append": True})
        assert status == 200
        assert wait_for(lambda: played == ["One.", "Two."])
    finally:
        server.shutdown()


def test_oversize_and_negative_content_length_rejected():
    server, port = start_server([])
    try:
        try:
            request(port, "/speak", {"text": "x" * (MAX_BODY_BYTES + 1)})
            assert False, "expected 413"
        except urllib.error.HTTPError as e:
            assert e.code == 413

        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/speak", data=b"", method="POST")
        req.add_header("Content-Length", "-1")
        try:
            urllib.request.urlopen(req, timeout=5)
            assert False, "expected 413"
        except urllib.error.HTTPError as e:
            assert e.code == 413
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
    sp.speak(blocks=[(1, "second."), (2, "third."), (3, "fourth.")],
             append=True)
    assert wait_for(lambda: len(played_blocks) == 2 and sp.pending() == 0)
    assert played_blocks[0] == (0, 0)
    assert played_blocks[1] == (1, 3)  # merged batch spans its blocks


def test_speak_blocks_endpoint_sanitizes_and_keeps_indices():
    played = []
    server, port = start_server(played)
    try:
        status, body = request(
            port, "/speak",
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
    # The play fn has no pause(); /pause still reports paused, and synthesis
    # parks via the lookahead budget once the playhead stops advancing
    # (client segment streams and the afplay fallback hit this path).
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


class ConsistencyCheckingPlayer(FakePausablePlayer):
    """Records any call where the speaker's pause flag disagrees with the
    direction of the call: resume() must only ever run with the flag
    already cleared (and pause() with it set), which holds exactly when
    flag and player move as one unit under the speaker lock."""

    def __init__(self):
        super().__init__()
        self.speaker = None
        self.violations = []

    def pause(self):
        if not self.speaker._pause.is_set():
            self.violations.append("pause with flag clear")
        super().pause()

    def resume(self):
        if self.speaker._pause.is_set():
            self.violations.append("resume with flag set")
        super().resume()


def test_pause_resume_flurry_keeps_flag_and_player_in_step():
    # The race: a resume() that clears the flag and resumes the player as
    # two unlocked steps lets a concurrent pause() land in between,
    # leaving the flag set with the player running (or the mirror image
    # with the roles swapped). Hammer both interleaving orders.
    def synth(text, make_path):
        return iter(())

    for order in (("pause", "resume"), ("resume", "pause")):
        player = ConsistencyCheckingPlayer()
        speaker = Speaker(synth, player)
        player.speaker = speaker
        ops = {"pause": speaker.pause, "resume": speaker.resume}
        barrier = threading.Barrier(2)

        def hammer(first, second):
            barrier.wait()
            for _ in range(300):
                ops[first]()
                ops[second]()

        threads = [threading.Thread(target=hammer, args=(a, b))
                   for a, b in (order, order[::-1])]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert player.violations == []
        assert speaker._pause.is_set() == player.paused


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


# --- speed ---

def test_stretch_wav_shortens_audio_preserving_sr(tmp_path):
    import soundfile as sf
    path = str(tmp_path / "a.wav")
    sf.write(path, _sine(seconds=2.0), 24000)
    stretch_wav(path, 2.0)
    info = sf.info(path)
    assert info.samplerate == 24000
    assert abs(info.frames / info.samplerate - 1.0) < 0.1  # ~half as long


def test_synth_loop_stretches_segments(tmp_path):
    import soundfile as sf
    durations = []

    def synth(text, make_path):
        path = make_path()
        sf.write(path, _sine(seconds=1.0), 24000)
        yield path

    class Handle:
        def terminate(self):
            pass

        def wait(self):
            pass

    def play(path):
        info = sf.info(path)
        durations.append(info.frames / info.samplerate)
        return Handle()

    sp = Speaker(synth, play, speed=2.0)
    sp.speak("hello.")
    assert wait_for(lambda: durations)
    assert abs(durations[0] - 0.5) < 0.1


def test_speak_speed_field_updates_speaker_and_health():
    played = []
    server, port = start_server(played)
    try:
        assert request(port, "/health")[1]["speed"] == 1.0
        status, _ = request(port, "/speak", {"text": "One.", "speed": 1.5})
        assert status == 200
        assert request(port, "/health")[1]["speed"] == 1.5
        # sticky: a later speak without speed keeps 1.5
        request(port, "/speak", {"text": "Two."})
        assert request(port, "/health")[1]["speed"] == 1.5
    finally:
        server.shutdown()


def test_speak_rejects_out_of_range_speed():
    server, port = start_server([])
    try:
        for bad in (0.1, 5, "fast", True):
            try:
                request(port, "/speak", {"text": "hi.", "speed": bad})
                assert False, f"expected 400 for speed={bad!r}"
            except urllib.error.HTTPError as e:
                assert e.code == 400
    finally:
        server.shutdown()


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


def test_speaker_with_client_stream_buffers_instead_of_playing(tmp_path):
    store = SegmentStore()
    sp = make_speaker([], store=store)
    sp.speak("hello there.")
    assert wait_for(lambda: store.next_after(0, timeout=0)[2] is not None)
    assert store.next_after(0, timeout=0)[2] == b"hello there."
    assert wait_for(lambda: sp.pending() == 0)


def test_speaker_preempt_invalidates_client_stream(tmp_path):
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
      POST /v1/audio/voices            -> registers voice, returns
                                          {"name": ..., "status": "registered"}
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
                    "data": [{"id": "mock-talker", "object": "model",
                              "owned_by": "local"}],
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
                if fmt == "pcm":
                    # 2.5s of s16le 24kHz mono, streamed like the real server
                    data = b"\x00\x01" * (24000 * 5 // 2)
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/pcm")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    for i in range(0, len(data), 16384):
                        self.wfile.write(data[i:i + 16384])
                else:
                    wav_data = _make_wav_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/wav")
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
    server = _make_qwentts_mock_server(port, _wav_b64(), "ref text here",
                                       stop_event)
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

        # Run synth: 2.5s of streamed pcm -> two 1s segments + a 0.5s tail,
        # each a playable wav.
        counter = [0]

        def make_path():
            counter[0] += 1
            return str(tmp_path / f"out_{counter[0]}.wav")

        output_files = []
        for path in synth("Hello world.", make_path):
            output_files.append(path)
            assert Path(path).exists()
            with open(path, "rb") as f:
                assert f.read(4) == b"RIFF"

        assert len(output_files) == 3
        import soundfile as sf
        total = sum(sf.info(p).frames for p in output_files)
        assert total == 24000 * 5 // 2  # no samples lost across segments
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
    server = _make_qwentts_mock_server(port, _wav_b64(), "ref text here",
                                       stop_event)
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


# --- config file ---

def test_default_config_path_per_platform(monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")
    assert default_config_path() == (
        Path.home() / "Library/Application Support/voice-ml/config.json")
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    assert default_config_path() == Path.home() / ".config/voice-ml/config.json"
    monkeypatch.setenv("XDG_CONFIG_HOME", "/x/cfg")
    assert default_config_path() == Path("/x/cfg/voice-ml/config.json")


def test_load_config_missing_file_is_defaults(tmp_path):
    assert load_config(tmp_path / "config.json") == Config()


def test_load_config_merges_partial_file_over_defaults(tmp_path):
    path = tmp_path / "config.json"
    path.write_text('{"speed": 1.4, "fx": true}')
    cfg = load_config(path)
    assert cfg.speed == 1.4 and cfg.fx is True
    assert cfg.port == 8765 and cfg.backend == "auto"  # defaults kept


def test_load_config_bad_json_is_a_clear_error_naming_the_file(tmp_path):
    path = tmp_path / "config.json"
    path.write_text('{"speed": 1.4,,}')
    with pytest.raises(SystemExit) as exc_info:
        load_config(path)
    assert str(path) in str(exc_info.value)


def test_load_config_rejects_unknown_key_and_bad_value(tmp_path):
    path = tmp_path / "config.json"
    path.write_text('{"spede": 1.4}')  # typo must not be silently ignored
    with pytest.raises(SystemExit) as exc_info:
        load_config(path)
    assert "unknown key" in str(exc_info.value)
    path.write_text('{"speed": "fast"}')
    with pytest.raises(SystemExit):
        load_config(path)
    path.write_text('[1, 2]')
    with pytest.raises(SystemExit):
        load_config(path)


def test_flags_override_file_values():
    config = Config(speed=1.4, fx=True, port=9111, backend="qwentts")
    args = argparse.Namespace(speed=2.0, fx=None, port=None, backend=None)
    live = effective_settings(config, args)
    assert live.speed == 2.0  # flag wins
    assert live.fx is True  # file supplies everything not flagged
    assert live.port == 9111
    assert live.backend == "qwentts"


# --- /config endpoints ---

def _voice_files(voices_dir, name):
    (voices_dir / f"{name}.wav").write_bytes(b"RIFF")
    (voices_dir / f"{name}.txt").write_text("ref text")


def start_config_server(tmp_path, overrides=None, token=None, ready=True,
                        config_path=None):
    voices = tmp_path / "voices"
    voices.mkdir(exist_ok=True)
    _voice_files(voices, "alpha")
    _voice_files(voices, "beta")
    if isinstance(overrides, Config):
        config = overrides
    else:
        config = Config(voice="alpha", voices_dir=str(voices),
                        **(overrides or {}))
    config_path = config_path or tmp_path / "config.json"
    app = App(model_id="test-model", token=token,
              config_path=config_path, config=config)
    if ready:
        app.speaker = make_speaker([])
    server = make_server(app, port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], app, config_path


def test_config_file_read_at_startup_serves_values(tmp_path):
    voices = tmp_path / "voices"
    voices.mkdir()
    _voice_files(voices, "alpha")
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(
        {"voice": "alpha", "voices_dir": str(voices), "fx": True}))
    settings = load_config(config_path)
    server, port, app, _ = start_config_server(tmp_path, overrides=settings)
    try:
        body = request(port, "/config")[1]
        assert body["voice"] == "alpha"
        assert body["fx"] is True
        assert body["port"] == 8765  # missing key fell back to the default
        assert body["restart_required"] is False
    finally:
        server.shutdown()


def test_get_config_shape(tmp_path):
    server, port, app, _ = start_config_server(tmp_path)
    try:
        status, body = request(port, "/config")
        assert status == 200
        assert set(body) == ({f.name for f in fields(Config)}
                             | {"restart_required"})
        assert body["voice"] == "alpha"
        assert body["speed"] == 1.0
        assert body["restart_required"] is False
    finally:
        server.shutdown()


def test_post_config_speed_hot_applies_and_persists(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        status, body = request(port, "/config", {"speed": 1.4})
        assert status == 200
        assert body["speed"] == 1.4
        assert body["persisted"] is True
        assert "persist_error" not in body
        assert body["restart_required"] is False  # applied live
        assert app.speaker.speed == 1.4
        assert request(port, "/health")[1]["speed"] == 1.4
        assert json.loads(config_path.read_text())["speed"] == 1.4
    finally:
        server.shutdown()


def test_post_config_fx_hot_applies(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        status, body = request(port, "/config", {"fx": True})
        assert status == 200
        assert body["fx"] is True
        assert body["restart_required"] is False
        assert app.fx_enabled is True  # the wrap_fx gate reads this live
        assert json.loads(config_path.read_text())["fx"] is True
    finally:
        server.shutdown()


def test_post_config_voice_change_sets_restart_required(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        status, body = request(port, "/config", {"voice": "beta"})
        assert status == 200
        assert body["voice"] == "beta"
        assert body["restart_required"] is True  # needs a model reload
        assert request(port, "/config")[1]["restart_required"] is True
        assert json.loads(config_path.read_text())["voice"] == "beta"
        # back to the launch value: nothing pending anymore
        status, body = request(port, "/config", {"voice": "alpha"})
        assert body["restart_required"] is False
    finally:
        server.shutdown()


def test_post_config_port_persists_but_never_hot_applies(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        status, body = request(port, "/config", {"port": 9333})
        assert status == 200
        assert body["restart_required"] is True
        assert json.loads(config_path.read_text())["port"] == 9333
        assert request(port, "/health")[0] == 200  # old port still serving
    finally:
        server.shutdown()


def test_post_config_unknown_key_400_and_nothing_written(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        try:
            request(port, "/config", {"speed": 1.4, "volume": 5})
            assert False, "expected 400"
        except urllib.error.HTTPError as e:
            assert e.code == 400
        assert not config_path.exists()  # rejected posts don't write
        assert app.config.speed == 1.0
        assert app.speaker.speed == 1.0
    finally:
        server.shutdown()


def test_post_config_validation_rejects_bad_values(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    (tmp_path / "voices" / "notext.wav").write_bytes(b"RIFF")
    try:
        for bad in ({"speed": 5}, {"speed": "fast"}, {"speed": True},
                    {"fx": "yes"}, {"fx": 1},
                    {"port": 0}, {"port": "8765"}, {"port": True},
                    {"backend": "gpt"}, {"voice": 5}, {"voices_dir": 5},
                    {"voice": "ghost"},  # no such wav
                    {"voice": "notext"},  # wav without its transcript
                    {"voice": "alpha", "voices_dir": None}):
            try:
                request(port, "/config", bad)
                assert False, f"expected 400 for {bad!r}"
            except urllib.error.HTTPError as e:
                assert e.code == 400
        assert not config_path.exists()
    finally:
        server.shutdown()


def test_config_endpoints_enforce_token_and_origin(tmp_path):
    server, port, app, _ = start_config_server(tmp_path, token="sekrit")
    try:
        for body in (None, {"speed": 1.2}):
            try:
                request(port, "/config", body)
                assert False, "expected 401"
            except urllib.error.HTTPError as e:
                assert e.code == 401
        auth = {"Authorization": "Bearer sekrit"}
        assert request(port, "/config", headers=auth)[0] == 200
        status, body = request(port, "/config", {"speed": 1.2}, headers=auth)
        assert status == 200 and body["speed"] == 1.2
        try:
            request(port, "/config", {"speed": 1.3},
                    headers={**auth, "Origin": "https://evil.example"})
            assert False, "expected 403"
        except urllib.error.HTTPError as e:
            assert e.code == 403
    finally:
        server.shutdown()


def test_config_file_round_trips_pretty_with_no_temp_left(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        request(port, "/config", {"speed": 1.4})
        request(port, "/config", {"voice": "beta", "fx": True})
        text = config_path.read_text()
        assert text.endswith("\n")
        assert text.startswith("{\n  ")  # pretty-printed for hand edits
        on_disk = json.loads(text)
        assert on_disk == asdict(app.config)  # round-trips the live truth
        # stable key order (Config field order)
        assert list(on_disk) == [f.name for f in fields(Config)]
        leftovers = [p.name for p in tmp_path.iterdir()
                     if p.name not in ("config.json", "voices")]
        assert leftovers == []  # atomic replace left no temp files
    finally:
        server.shutdown()


def test_post_config_rejects_path_traversal_voice(tmp_path):
    server, port, app, config_path = start_config_server(tmp_path)
    try:
        for voice in ("../x", "a/b", "/etc/passwd", "..\\x", "..", ".", ""):
            try:
                request(port, "/config", {"voice": voice})
                assert False, f"expected 400 for {voice!r}"
            except urllib.error.HTTPError as e:
                assert e.code == 400
                assert "bare name" in json.loads(e.read())["error"]
        assert not config_path.exists()  # rejected posts don't write
        assert app.config.voice == "alpha"
    finally:
        server.shutdown()


def test_load_config_rejects_path_traversal_voice(tmp_path):
    path = tmp_path / "config.json"
    for voice in ("../x", "a/b", "/etc/passwd"):
        path.write_text(json.dumps(
            {"voice": voice, "voices_dir": str(tmp_path)}))
        with pytest.raises(SystemExit) as exc_info:
            load_config(path)
        assert str(path) in str(exc_info.value)
        assert "bare name" in str(exc_info.value)


def test_post_config_write_failure_still_applies_in_memory(tmp_path):
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o500)  # config writes into here must fail
    server, port, app, config_path = start_config_server(
        tmp_path, config_path=ro / "config.json")
    try:
        status, body = request(port, "/config", {"speed": 1.4, "fx": True})
        assert status == 200  # persist failure is reported, not fatal
        assert body["persisted"] is False
        assert body["persist_error"]
        assert body["speed"] == 1.4
        assert app.speaker.speed == 1.4  # hot-applied despite the failure
        assert app.fx_enabled is True
        assert not config_path.exists()
        assert request(port, "/config")[1]["speed"] == 1.4  # memory truth
        assert request(port, "/health")[0] == 200  # daemon kept running
    finally:
        ro.chmod(0o700)
        server.shutdown()


def test_post_non_object_json_body_is_400(tmp_path):
    server, port, app, _ = start_config_server(tmp_path)
    try:
        for path, raw in (("/config", b"5"), ("/config", b"null"),
                          ("/config", b"true"), ("/config", b"[1, 2]"),
                          ("/speak", b'"hello"')):
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}", data=raw, method="POST")
            try:
                urllib.request.urlopen(req, timeout=5)
                assert False, f"expected 400 for {raw!r} on {path}"
            except urllib.error.HTTPError as e:
                assert e.code == 400
                assert json.loads(e.read())["error"]
    finally:
        server.shutdown()


def test_post_config_503_while_model_loading(tmp_path):
    # /config gets the same loading gate as every other POST route; GET
    # serves throughout so a manager can read settings during load.
    server, port, app, _ = start_config_server(tmp_path, ready=False)
    try:
        assert request(port, "/config")[0] == 200
        try:
            request(port, "/config", {"speed": 1.4})
            assert False, "expected 503"
        except urllib.error.HTTPError as e:
            assert e.code == 503
            assert "loading" in json.loads(e.read())["error"]
    finally:
        server.shutdown()


# --- channels (stage B) ---

class CountingSynth:
    """Word-per-segment stub that records every synth call, so tests can
    assert a waiting channel held text (no call) instead of audio."""

    def __init__(self):
        self.calls = []

    def __call__(self, text, make_path):
        self.calls.append(text)
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            yield path


def start_channel_server(local_store=None, **opts):
    synth = CountingSynth()
    app = App(model_id="test-model", segments=local_store)
    play = local_store if local_store is not None else _recording_play([])
    app.speaker = Speaker(synth, play)
    app.channel_opts = dict(tick=0.02, poll_window=5.0, grace=5.0)
    app.channel_opts.update(opts)
    server = make_server(app, port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], app, synth


def fetch_segment(port, channel=None, after=0, played=None, timeout=2.0):
    """One /segment poll; (seq, epoch, data), data None on 204."""
    qs = f"/segment?after={after}&timeout={timeout}"
    if channel is not None:
        qs += f"&channel={channel}"
    if played is not None:
        qs += f"&played={played}"
    with raw_request(port, qs) as resp:
        if resp.status == 204:
            return None, int(resp.headers["X-Epoch"]), None
        return (int(resp.headers["X-Seq"]), int(resp.headers["X-Epoch"]),
                resp.read())


def prime(port, channel):
    """A first (empty) poll: makes the channel eligible for a turn."""
    fetch_segment(port, channel, after=0, timeout=0.05)


def drain(port, channel, after=0, quiet=1.0):
    """Fetch segments, reporting each played on the next poll, until the
    stream goes quiet. Returns (decoded segments, last seq seen)."""
    got = []
    seq = after
    while True:
        s, _, data = fetch_segment(port, channel, after=seq, played=seq,
                                   timeout=quiet)
        if s is None:
            return got, seq
        seq = s
        got.append(data.decode())


def test_channels_have_isolated_streams_and_epochs():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "aa ab.", "channel": "cha",
                                 "raw": True})
        got_a, _ = drain(port, "cha")
        assert got_a == ["aa", "ab."]
        request(port, "/speak", {"text": "ba bb.", "channel": "chb",
                                 "append": True, "raw": True})
        got_b, _ = drain(port, "chb")
        assert got_b == ["ba", "bb."]
        # seq and epoch spaces are per channel: both streams start at seq
        # 1, and only cha (whose speak preempted) had its epoch bumped.
        seq_a, epoch_a, data_a = fetch_segment(port, "cha", after=0,
                                               timeout=0.05)
        seq_b, epoch_b, data_b = fetch_segment(port, "chb", after=0,
                                               timeout=0.05)
        assert (seq_a, data_a) == (1, b"aa")
        assert (seq_b, data_b) == (1, b"ba")
        assert epoch_a == 1 and epoch_b == 0
    finally:
        server.shutdown()


def test_machine_queue_append_slots_in_and_interrupted_resumes():
    server, port, app, synth = start_channel_server()
    try:
        words = "a1 a2 a3 a4 a5 a6 a7 a8"
        request(port, "/speak", {"text": words, "channel": "cha",
                                 "raw": True})
        seq1, _, d1 = fetch_segment(port, "cha", after=0)
        assert d1 == b"a1"
        prime(port, "chb")
        request(port, "/speak", {"text": "b1 b2.", "channel": "chb",
                                 "append": True, "raw": True})
        # the interrupted holder releases only its rendered lookahead
        got_a, seq_a = drain(port, "cha", after=seq1)
        assert got_a
        assert len(got_a) < 7
        got_b, _ = drain(port, "chb")
        assert got_b == ["b1", "b2."]
        # the interrupted channel resumes exactly where it stopped
        got_a2, _ = drain(port, "cha", after=seq_a, quiet=2.0)
        assert ["a1"] + got_a + got_a2 == words.split()
    finally:
        server.shutdown()


def test_third_channel_queues_behind_and_resume_is_newest_first():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4 a5 a6",
                                 "channel": "cha", "raw": True})
        sa, _, _ = fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "b1 b2 b3 b4 b5 b6",
                                 "channel": "chb", "append": True,
                                 "raw": True})
        got_a, seq_a = drain(port, "cha", after=sa)  # a's lookahead only
        sb, _, db = fetch_segment(port, "chb", after=0)
        assert db == b"b1"
        prime(port, "chc")
        request(port, "/speak", {"text": "c1.", "channel": "chc",
                                 "append": True, "raw": True})
        got_b, seq_b = drain(port, "chb", after=sb)  # b's lookahead only
        assert len(got_b) < 5
        got_c, _ = drain(port, "chc", quiet=2.0)
        assert got_c == ["c1."]
        # newest interruption resumes first: b continues (and finishes)
        # before a gets the machine back
        got_b2, _ = drain(port, "chb", after=seq_b, quiet=2.0)
        assert ["b1"] + got_b + got_b2 == "b1 b2 b3 b4 b5 b6".split()
        got_a2, _ = drain(port, "cha", after=seq_a, quiet=2.0)
        assert ["a1"] + got_a + got_a2 == "a1 a2 a3 a4 a5 a6".split()
    finally:
        server.shutdown()


def test_waiting_channel_holds_text_not_audio():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4", "channel": "cha",
                                 "raw": True})
        s, _, _ = fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "waiting words here.",
                                 "channel": "chb", "append": True,
                                 "raw": True})
        time.sleep(0.3)
        # b lacks the turn: its text was never handed to the synth
        assert all("waiting" not in c for c in synth.calls)
        drain(port, "cha", after=s)
        got_b, _ = drain(port, "chb", quiet=2.0)
        assert got_b == "waiting words here.".split()
        assert any("waiting" in c for c in synth.calls)
    finally:
        server.shutdown()


def test_played_grace_exceeds_poll_timeout():
    import serve
    # Constant relation, not a wall-clock test: a healthy extension only
    # re-polls after its poll cycle, so the dead-client grace must exceed
    # the long-poll timeout or live clients get declared dead.
    assert serve.PLAYED_GRACE == serve.SEGMENT_POLL_TIMEOUT + 10.0
    assert serve.PLAYED_GRACE > serve.SEGMENT_POLL_TIMEOUT


def test_segment_store_played_cursor_is_epoch_scoped(tmp_path):
    store = SegmentStore()
    store.submit(_seg_file(tmp_path, "a.wav", b"aaa"), None)
    store.submit(_seg_file(tmp_path, "b.wav", b"bbb"), None)
    assert store.release_stats()[0] == 2
    store.report_played(1)
    assert store.release_stats()[0] == 1
    assert store.release_stats()[3] == 1
    store.report_played(0)  # backward report: ignored
    assert store.release_stats()[3] == 1
    store.report_played(99)  # cursor never runs past what was released
    assert store.release_stats()[3] == 2
    store.invalidate()  # epoch bump resets the cursor's frame
    store.submit(_seg_file(tmp_path, "c.wav", b"ccc"), None)
    store.report_played(2)  # stale: a seq from the old epoch
    assert store.release_stats()[0] == 1
    store.report_played(3)
    assert store.release_stats()[0] == 0


def test_dead_client_expires_and_queue_moves_on():
    server, port, app, synth = start_channel_server(grace=0.3)
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4 a5 a6",
                                 "channel": "cha", "raw": True})
        fetch_segment(port, "cha", after=0)  # holder; never reports played
        prime(port, "chb")
        request(port, "/speak", {"text": "b1.", "channel": "chb",
                                 "append": True, "raw": True})
        # cha goes silent past its released duration + grace: declared
        # dead, its queue cleared, and the machine moves on to b.
        got_b, _ = drain(port, "chb", quiet=2.0)
        assert got_b == ["b1."]
        assert request(port, "/health")[1]["channels"]["cha"]["pending"] == 0
        # the dead channel's stream was invalidated (epoch bumped)
        _, epoch, data = fetch_segment(port, "cha", after=0, timeout=0.05)
        assert data is None and epoch >= 2
    finally:
        server.shutdown()


def test_paused_channel_is_skipped_and_resume_reenters():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4", "channel": "cha",
                                 "raw": True})
        s, _, _ = fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "b1 b2.", "channel": "chb",
                                 "append": True, "raw": True})
        status, body = request(port, "/pause", {"channel": "chb"})
        assert body == {"ok": True, "paused": True}
        # b is out of the rotation: a plays out its whole message
        got_a, _ = drain(port, "cha", after=s)
        assert ["a1"] + got_a == "a1 a2 a3 a4".split()
        assert fetch_segment(port, "chb", after=0, timeout=0.2)[2] is None
        status, body = request(port, "/resume", {"channel": "chb"})
        assert body == {"ok": True, "paused": False}
        got_b, _ = drain(port, "chb", quiet=2.0)
        assert got_b == ["b1", "b2."]
    finally:
        server.shutdown()


def test_pause_by_holder_yields_turn_immediately():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4 a5 a6",
                                 "channel": "cha", "raw": True})
        s, _, _ = fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "b1.", "channel": "chb",
                                 "append": True, "raw": True})
        # the holder pauses: the turn passes without draining a's audio
        request(port, "/pause", {"channel": "cha"})
        got_b, _ = drain(port, "chb", quiet=2.0)
        assert got_b == ["b1."]
        request(port, "/resume", {"channel": "cha"})
        got_a, _ = drain(port, "cha", after=s, quiet=2.0)
        assert ["a1"] + got_a == "a1 a2 a3 a4 a5 a6".split()
    finally:
        server.shutdown()


def test_pollless_channel_gets_no_turn_until_it_polls():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "quiet until polled.",
                                 "channel": "chx", "raw": True})
        time.sleep(0.3)
        assert synth.calls == []  # no dead-air turn: the text is held
        got, _ = drain(port, "chx", quiet=2.0)
        assert got == "quiet until polled.".split()
    finally:
        server.shutdown()


def test_per_channel_stop_clears_only_that_channel():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4 a5 a6",
                                 "channel": "cha", "raw": True})
        fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "b1.", "channel": "chb",
                                 "append": True, "raw": True})
        request(port, "/stop", {"channel": "cha"})
        got_b, _ = drain(port, "chb", quiet=2.0)
        assert got_b == ["b1."]  # b survived and got the turn
        health = request(port, "/health")[1]
        assert health["channels"]["cha"]["pending"] == 0
    finally:
        server.shutdown()


def test_bare_stop_clears_all_channels():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4 a5 a6",
                                 "channel": "cha", "raw": True})
        fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "b1 b2.", "channel": "chb",
                                 "append": True, "raw": True})
        request(port, "/stop", {})
        health = request(port, "/health")[1]
        assert health["pending"] == 0
        for name in ("cha", "chb"):
            _, epoch, data = fetch_segment(port, name, after=0, timeout=0.05)
            assert data is None and epoch >= 1
    finally:
        server.shutdown()


def test_preempt_all_clears_blocks_and_wakes_parked_polls():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"blocks": ["a1.", "a2."], "channel": "cha"})
        fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"blocks": ["b1.", "b2."], "channel": "chb",
                                 "append": True})
        parked = []
        t = threading.Thread(target=lambda: parked.append(
            fetch_segment(port, "chb", after=99, timeout=5)))
        t.start()
        time.sleep(0.1)
        request(port, "/speak", {"text": "c wins.", "channel": "chc",
                                 "raw": True})
        t.join(timeout=2)  # the epoch bump wakes the parked poll now
        assert not t.is_alive()
        assert parked[0][2] is None  # 204 with the bumped epoch
        # blocks were nuked everywhere: /seek cannot resurrect them
        for name in ("cha", "chb"):
            status, body = request(port, "/seek",
                                   {"block": 0, "channel": name})
            assert body["ok"] is False
        got_c, _ = drain(port, "chc", quiet=2.0)
        assert got_c == ["c", "wins."]
    finally:
        server.shutdown()


def test_seek_rereleases_on_a_client_channel():
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"blocks": ["Zero.", "One.", "Two."],
                                 "channel": "che"})
        got, seq = drain(port, "che")
        assert got == ["Zero.", "One.", "Two."]
        status, body = request(port, "/seek", {"block": 0, "channel": "che"})
        assert body == {"ok": True, "block": 0}
        # re-released from the target on the same (seq-monotonic) stream,
        # under a bumped epoch so the client drops its scheduled audio
        got2, _ = drain(port, "che", after=seq, quiet=2.0)
        assert got2 == ["Zero.", "One.", "Two."]
        assert fetch_segment(port, "che", after=999, timeout=0.05)[1] >= 2
    finally:
        server.shutdown()


def test_channel_name_validation_rejects_bad_names():
    server, port = start_server([])
    try:
        for bad in ("UPPER", "with space", "a" * 33, "", "sp/it", 5):
            for path, body in (("/speak", {"text": "hi.", "channel": bad}),
                               ("/pause", {"channel": bad}),
                               ("/stop", {"channel": bad}),
                               ("/seek", {"delta": 1, "channel": bad})):
                try:
                    request(port, path, body)
                    assert False, f"expected 400 for {bad!r} on {path}"
                except urllib.error.HTTPError as e:
                    assert e.code == 400
        try:
            request(port, "/segment?after=0&timeout=0.05&channel=BAD")
            assert False, "expected 400"
        except urllib.error.HTTPError as e:
            assert e.code == 400
    finally:
        server.shutdown()


def test_health_channels_shape_in_both_local_player_modes():
    # daemon-played local: playback stays "local", channels dict present
    server, port = start_server([])
    try:
        body = request(port, "/health")[1]
        assert body["playback"] == "local"
        assert set(body["channels"]) == {"local"}
        assert set(body["channels"]["local"]) == {"pending", "speaking",
                                                  "paused", "block",
                                                  "active"}
        # daemon-played local has no segment stream, with or without a
        # channel arg
        for path in ("/segment?after=0&timeout=0.05",
                     "/segment?after=0&timeout=0.05&channel=local"):
            try:
                request(port, path)
                assert False, "expected 404"
            except urllib.error.HTTPError as e:
                assert e.code == 404
    finally:
        server.shutdown()
    # client-played local plus a named channel
    store = SegmentStore()
    server, port = start_server([], store=store)
    try:
        request(port, "/speak", {"text": "ext words.", "channel": "ext",
                                 "raw": True})
        body = request(port, "/health")[1]
        assert body["playback"] == "client"
        assert set(body["channels"]) == {"local", "ext"}
        # nothing released yet (never polled): not speaking
        assert body["channels"]["ext"]["speaking"] is False
        seq, _, data = fetch_segment(port, "ext", after=0)
        assert data == b"ext words."
        # released but not yet reported played: speaking
        body = request(port, "/health")[1]
        assert body["channels"]["ext"]["speaking"] is True
        assert body["speaking"] is True
        drain(port, "ext", after=seq)  # report it played
        assert wait_for(lambda: request(
            port, "/health")[1]["channels"]["ext"]["speaking"] is False)
    finally:
        server.shutdown()


def test_turn_waiting_channel_is_active_with_zero_pending():
    # The lie this guards against: a holder interrupted mid-utterance
    # parks its batch outside every queue, so pending reads 0 and
    # released drains to 0, yet the channel is anything but finished.
    # Clients keying off pending/speaking tore their players down here.
    server, port, app, synth = start_channel_server()
    try:
        request(port, "/speak", {"text": "a1 a2 a3 a4 a5 a6 a7 a8",
                                 "channel": "cha", "raw": True})
        s1, _, _ = fetch_segment(port, "cha", after=0)
        prime(port, "chb")
        request(port, "/speak", {"text": "b1 b2.", "channel": "chb",
                                 "append": True, "raw": True})
        # drain cha's rendered lookahead (reporting it played): cha parks
        # mid-utterance in the resume list while chb takes the turn
        _, seq_a = drain(port, "cha", after=s1)

        def parked():
            ch = request(port, "/health")[1]["channels"]["cha"]
            return (ch["pending"] == 0 and not ch["speaking"]
                    and ch["active"])
        assert wait_for(parked)
        # both finish; only then does active drop
        got_b, _ = drain(port, "chb", quiet=2.0)
        assert got_b == ["b1", "b2."]
        drain(port, "cha", after=seq_a, quiet=2.0)
        assert wait_for(lambda: not request(
            port, "/health")[1]["channels"]["cha"]["active"])
    finally:
        server.shutdown()


def test_speak_without_channel_is_local_and_preempts_everything():
    store = SegmentStore()
    server, port = start_server([], store=store)
    try:
        request(port, "/speak", {"text": "x words.", "channel": "chx",
                                 "raw": True})
        fetch_segment(port, "chx", after=0)
        # no channel field: today's request shape, lands on local and
        # preempts every channel (one voice per machine)
        request(port, "/speak", {"text": "local wins.", "raw": True})
        _, epoch, data = fetch_segment(port, "chx", after=0, timeout=0.05)
        assert data is None and epoch >= 2
        got, _ = drain(port, None, quiet=2.0)
        assert got == ["local wins."]
    finally:
        server.shutdown()


def test_idle_unpolled_channel_is_garbage_collected():
    server, port, app, synth = start_channel_server(gc_seconds=0.1)
    try:
        prime(port, "typo")  # a poll alone creates the channel
        assert "typo" in request(port, "/health")[1]["channels"]
        assert wait_for(
            lambda: "typo" not in request(port, "/health")[1]["channels"])
        assert "local" in request(port, "/health")[1]["channels"]
    finally:
        server.shutdown()


def test_playback_flag_is_removed(monkeypatch, capsys):
    # Stage B's deprecation window ended: the old spelling must error
    # loudly instead of being silently ignored by argparse.
    import pytest
    from serve import parse_args
    monkeypatch.setattr(sys, "argv",
                        ["serve.py", "-r", "x.wav", "--playback", "client"])
    with pytest.raises(SystemExit):
        parse_args()
    assert "--playback" in capsys.readouterr().err


# --- stage-B review fixes ---

def test_gc_race_speak_on_idle_channel_never_loses_content():
    # gc_seconds=0 deletes the channel the tick after it goes idle, so
    # every /speak races channel recreation against the janitor. The
    # in-use pin plus atomic lookup must keep every word deliverable and
    # the janitor alive.
    server, port, app, synth = start_channel_server(gc_seconds=0.0,
                                                    tick=0.005)
    try:
        for i in range(25):
            word = f"w{i}."
            request(port, "/speak", {"text": word, "channel": "hammer",
                                     "append": True, "raw": True})
            got, seq = [], 0
            deadline = time.monotonic() + 5.0
            while word not in got:
                assert time.monotonic() < deadline, f"lost {word}"
                s, _, data = fetch_segment(port, "hammer", after=seq,
                                           played=seq, timeout=0.5)
                if s is None:
                    continue
                seq = s
                got.append(data.decode())
            # report it played so the channel goes contentless and the
            # janitor collects it before the next round
            fetch_segment(port, "hammer", after=seq, played=seq,
                          timeout=0.02)
        assert app.channels._janitor.is_alive()
        # the janitor still does its job: a fresh idle channel is
        # collected, and polls keep answering
        prime(port, "leftover")
        assert wait_for(lambda: "leftover" not in
                        request(port, "/health")[1]["channels"])
        assert fetch_segment(port, "hammer", after=0, timeout=0.05)
    finally:
        server.shutdown()


def test_machine_queue_drops_unknown_queued_names(capsys):
    from serve import MachineQueue
    q = MachineQueue(grace=1.0)
    q.enqueue("ghost")  # a GC'd channel's stale slot: no state_fn
    q.poke()  # must not raise: the janitor calls this forever
    assert q.holder() is None
    assert "ghost" in capsys.readouterr().err


class GatedPausablePlayer:
    """Local player whose in-flight segment blocks until released; the
    events list records audible transitions so a test can pin down when
    a paused segment actually resumes."""

    def __init__(self):
        self.events = []
        self.release = threading.Event()

    def pause(self):
        self.events.append("pause")

    def resume(self):
        self.events.append("resume")

    def __call__(self, path):
        player = self
        player.events.append(("play", Path(path).read_text()))

        class Handle:
            def __init__(self):
                self.cancelled = threading.Event()

            def terminate(self):
                self.cancelled.set()

            def wait(self):
                while not (player.release.is_set()
                           or self.cancelled.is_set()):
                    time.sleep(0.01)

        return Handle()


def test_resume_of_inflight_segment_waits_for_turn():
    from serve import ChannelManager

    def synth(text, make_path):
        for word in text.split():
            path = make_path()
            Path(path).write_text(word)
            yield path

    player = GatedPausablePlayer()
    local = Speaker(synth, player)
    mgr = ChannelManager(local, None, tick=0.02, poll_window=5.0,
                         grace=5.0)
    mgr.speak("local", text="l1 l2 l3", append=True)
    assert wait_for(lambda: ("play", "l1") in player.events)
    mgr.pause("local")  # mid-segment: l1's handle is still in wait()
    chb = mgr.poll_begin("chb")  # prime eligibility
    mgr.poll_end(chb)
    mgr.speak("chb", text="b1 b2.", append=True)
    assert wait_for(lambda: mgr.queue.holder() == "chb")
    seq, _, data, _ = chb.store.next_after(0, 2.0)
    assert data is not None
    # resume while B holds the turn: the pause flag clears, but the
    # paused in-flight segment must not become audible yet
    assert mgr.resume("local") is False
    time.sleep(0.3)
    assert "resume" not in player.events
    # B finishes: fetch the rest and report it all played
    while True:
        s, _, data, _ = chb.store.next_after(seq, 0.2)
        if data is None:
            break
        seq = s
    chb.store.report_played(seq)
    mgr.queue.poke()
    # only now, with the turn re-granted, does local audio resume
    assert wait_for(lambda: "resume" in player.events)
    player.release.set()
    assert wait_for(lambda: mgr.queue.holder() != "chb")


def test_segment_poll_timeout_capped_under_grace():
    import serve
    # Constant relation, not a wall-clock test: /segment clamps the
    # accepted long-poll timeout to MAX_POLL_TIMEOUT, which must sit a
    # slack under the dead-client grace (a client parked in one poll is
    # silent for the whole poll) while still admitting the default.
    assert serve.MAX_POLL_TIMEOUT < serve.PLAYED_GRACE
    assert serve.MAX_POLL_TIMEOUT >= serve.SEGMENT_POLL_TIMEOUT


class InstantHandle:
    def terminate(self):
        pass

    def wait(self):
        pass


def test_final_segment_stays_counted_until_delivery_starts(tmp_path):
    # Structural invariant: _pop_segment moves a segment from the play
    # queue into _popped under the queue's own mutex, the same lock
    # rendered_pending() reads under, so the count can never transiently
    # hit zero mid-pop. The sampling below could only flake against an
    # implementation with a two-step (get, then count) pop.
    started = threading.Event()
    round_done = threading.Event()

    def synth(text, make_path):  # unused: segments are injected directly
        return iter(())

    def play(path):
        started.set()
        return InstantHandle()

    sp = Speaker(synth, play)
    sp._on_progress = round_done.set
    for i in range(200):
        started.clear()
        round_done.clear()
        path = tmp_path / f"{i}.wav"
        path.write_text("x")
        sp._play_q.put((sp._epoch, str(path), None))
        deadline = time.monotonic() + 1.0
        while not started.is_set():
            count = sp.rendered_pending()
            # a sample is only about the pre-delivery window if delivery
            # still had not started after it was taken; started is set
            # first thing in play(), so a still-clear flag proves the
            # read happened between enqueue and the player taking over
            if started.is_set():
                break
            assert count >= 1
            assert time.monotonic() < deadline
        assert round_done.wait(1.0)
