"""Tests for the TTS daemon (model mocked). Run: uv run pytest tts/"""

import json
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import asdict
from pathlib import Path

from serve import (MAX_BODY_BYTES, App, EngineHealth, PCMPlayer, SegmentStore,
                   Speaker, SynthesisEngine, VoiceContext, VoiceProfile,
                   activate_voice, block_span, chunk_text, make_server,
                   pick_backend, sanitize_markdown, stretch_wav)


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

class SnapshotRecordingEngine(SynthesisEngine):
    def __init__(self):
        self.calls = []
        self.pins = {}
        self.retain_calls = []
        self.release_calls = []
        self.synth_entered = threading.Event()
        self.synth_gate = threading.Event()
        self.synth_gate.set()
        self.block_retain = False
        self.retain_entered = threading.Event()
        self.retain_gate = threading.Event()
        self.retain_gate.set()
        self.failure = None

    def prepare(self, profile):
        context = VoiceContext(profile, profile.id, profile.id)
        self.pins[profile.id] = self.pins.get(profile.id, 0) + 1
        return context

    def synthesize(self, context, text, make_path, effects=False):
        self.calls.append((context.profile.id, effects, text))
        self.synth_entered.set()
        self.synth_gate.wait(5)
        path = make_path()
        Path(path).write_text(text)
        yield path

    def retain(self, context):
        if self.block_retain:
            self.retain_entered.set()
            self.retain_gate.wait(5)
        profile_id = context.profile.id
        self.retain_calls.append(profile_id)
        self.pins[profile_id] = self.pins.get(profile_id, 0) + 1

    def release(self, context):
        profile_id = context.profile.id
        self.release_calls.append(profile_id)
        self.pins[profile_id] -= 1

    def health(self):
        return EngineHealth(self.failure is None, self.failure)

    def close(self):
        pass


def snapshot_profile(tmp_path, profile_id):
    root = tmp_path / profile_id
    root.mkdir()
    audio = root / "voice.wav"
    transcript = root / "voice.txt"
    audio.write_bytes(b"RIFF")
    transcript.write_text(f"{profile_id} reference")
    return VoiceProfile(
        profile_id, profile_id.title(), str(root), str(audio),
        str(transcript), transcript.read_text())


def snapshot_app(tmp_path):
    engine = SnapshotRecordingEngine()
    profile = snapshot_profile(tmp_path, "alpha")
    played = []
    speaker = Speaker(
        engine=engine, voice_profile=profile,
        play_fn=_recording_play(played))
    assert wait_for(speaker.ready.is_set)
    app = App(model_id="snapshot-test")
    app.speaker = speaker
    return app, speaker, engine, played


def test_append_snapshots_cross_voice_effect_and_rate_boundaries(
        tmp_path, monkeypatch):
    import serve

    app, speaker, engine, played = snapshot_app(tmp_path)
    stretched = []
    monkeypatch.setattr(
        serve, "stretch_wav",
        lambda path, rate: stretched.append((Path(path).read_text(), rate)))
    speaker._gate = lambda: False
    speaker.speak(
        "first.", snapshot=app.capture_synthesis_snapshot())
    app.commit_synthesis_settings(effects=True)
    speaker.speak(
        "second.", append=True,
        snapshot=app.capture_synthesis_snapshot())
    app.commit_synthesis_settings(rate=1.5)
    speaker.speak(
        "third.", append=True,
        snapshot=app.capture_synthesis_snapshot())

    beta = snapshot_profile(tmp_path, "beta")
    activate_voice(
        beta, speaker._worker.prepare, lambda profile: None,
        app.commit_synthesis_context, speaker._worker.retain,
        speaker._worker.release)
    speaker.speak(
        "fourth.", append=True,
        snapshot=app.capture_synthesis_snapshot())
    speaker._gate = None
    speaker._worker.wake()

    assert wait_for(lambda: played == [
        "first.", "second.", "third.", "fourth."])
    assert engine.calls == [
        ("alpha", False, "first."),
        ("alpha", True, "second."),
        ("alpha", True, "third."),
        ("beta", True, "fourth."),
    ]
    assert stretched == [("third.", 1.5), ("fourth.", 1.5)]
    assert not app.is_profile_captured("alpha")
    assert app.is_profile_captured("beta")


def test_settings_commit_waits_for_acceptance_snapshot_retain(tmp_path):
    app, speaker, engine, _ = snapshot_app(tmp_path)
    engine.block_retain = True
    engine.retain_gate.clear()
    captured = []
    committed = threading.Event()

    accept_thread = threading.Thread(
        target=lambda: captured.append(app.capture_synthesis_snapshot()))
    accept_thread.start()
    assert engine.retain_entered.wait(5)

    def commit():
        app.commit_synthesis_settings(effects=True)
        committed.set()

    commit_thread = threading.Thread(target=commit)
    commit_thread.start()
    assert not committed.wait(0.05)
    engine.retain_gate.set()
    accept_thread.join(5)
    commit_thread.join(5)

    assert captured[0].effects is False
    future = app.capture_synthesis_snapshot()
    assert future.effects is True
    speaker._worker.release(captured[0].context)
    speaker._worker.release(future.context)


def test_queue_drain_releases_one_acceptance_pin_for_many_chunks(tmp_path):
    app, speaker, engine, _ = snapshot_app(tmp_path)
    speaker._max_chars = 8
    speaker._first_chars = 8
    speaker._gate = lambda: False
    baseline_retains = len(engine.retain_calls)
    baseline_releases = len(engine.release_calls)

    snapshot = app.capture_synthesis_snapshot()
    assert speaker.speak(
        "one two. three four. five six.", snapshot=snapshot) > 1
    speaker.stop()
    assert speaker._worker.is_profile_pinned("alpha")

    assert len(engine.retain_calls) - baseline_retains == 1
    assert len(engine.release_calls) - baseline_releases == 1
    assert engine.pins["alpha"] == 1


def test_stop_releases_inflight_snapshot_once(tmp_path):
    app, speaker, engine, _ = snapshot_app(tmp_path)
    engine.synth_gate.clear()
    baseline_retains = len(engine.retain_calls)
    baseline_releases = len(engine.release_calls)
    speaker.speak(
        "blocked.", snapshot=app.capture_synthesis_snapshot())
    assert engine.synth_entered.wait(5)

    speaker.stop()
    engine.synth_gate.set()
    assert wait_for(
        lambda: len(engine.release_calls) - baseline_releases == 1)
    assert len(engine.retain_calls) - baseline_retains == 1
    assert engine.pins["alpha"] == 1

def test_engine_failure_is_visible_and_rejects_new_speak(tmp_path):
    app, _, engine, _ = snapshot_app(tmp_path)
    server = make_server(app, port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    try:
        engine.failure = {
            "code": "engine_child_exited",
            "message": "tts-server exited",
        }
        health = request(port, "/health")[1]
        assert health["ready"] is False
        assert health["engine_error"] == engine.failure
        try:
            request(port, "/speak", {"text": "not accepted"})
            assert False, "expected engine-unavailable 503"
        except urllib.error.HTTPError as exc:
            assert exc.code == 503
            assert json.loads(exc.read())["error"] == engine.failure
    finally:
        server.shutdown()


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


def assert_json_contract(port, path, expected, body=None):
    with raw_request(port, path, body) as resp:
        payload = resp.read()
        assert resp.status == 200
        assert resp.headers["Content-Type"] == "application/json"
        assert resp.headers["Content-Length"] == str(len(payload))
    assert json.loads(payload) == expected


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


def test_unversioned_playback_routes_have_stable_json_contracts():
    played = []
    server, port = start_server(played)
    try:
        assert_json_contract(port, "/health", {
            "ok": True,
            "ready": True,
            "model": "test-model",
            "playback": "local",
            "pending": 0,
            "speaking": False,
            "paused": False,
            "block": None,
            "speed": 1.0,
            "channels": {
                "local": {
                    "pending": 0,
                    "speaking": False,
                    "paused": False,
                    "block": None,
                    "active": False,
                },
            },
        })
        assert_json_contract(
            port, "/speak", {"queued": 2},
            {"blocks": ["Zero.", "One."], "raw": True})
        assert wait_for(lambda: played == ["Zero.", "One."])
        assert_json_contract(
            port, "/seek", {"ok": True, "block": 0}, {"block": 0})
        assert_json_contract(
            port, "/pause", {"ok": True, "paused": True}, {})
        assert_json_contract(
            port, "/resume", {"ok": True, "paused": False}, {})
        assert_json_contract(port, "/stop", {"ok": True}, {})
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


def test_speak_speed_field_overrides_only_that_request():
    played = []
    server, port = start_server(played)
    try:
        assert request(port, "/health")[1]["speed"] == 1.0
        status, _ = request(port, "/speak", {"text": "One.", "speed": 1.5})
        assert status == 200
        assert request(port, "/health")[1]["speed"] == 1.0
        request(port, "/speak", {"text": "Two."})
        assert request(port, "/health")[1]["speed"] == 1.0
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
            payload = resp.read()
            assert resp.status == 200
            assert resp.headers["Content-Type"] == "audio/wav"
            assert resp.headers["Content-Length"] == str(len(payload))
            assert resp.headers["X-Seq"] == "1"
            # every non-append /speak preempts, bumping the epoch once
            assert resp.headers["X-Epoch"] == "1"
            assert resp.headers["X-Block"] == "0,0"
            assert payload == b"hello there."
    finally:
        server.shutdown()


def test_segment_endpoint_times_out_204_with_epoch():
    server, port = start_server([], store=SegmentStore())
    try:
        started = time.monotonic()
        with raw_request(port, "/segment?after=0&timeout=0.05") as resp:
            payload = resp.read()
            assert resp.status == 204
            assert resp.headers["X-Epoch"] == "0"
            assert resp.headers.get("Content-Type") is None
            assert payload == b""
        assert time.monotonic() - started >= 0.04
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
# --- concrete synthesis engines and activation transactions ---

import base64
import subprocess
import types
from unittest.mock import patch

import pytest


def _make_wav_bytes(sr=24000, duration=0.05):
    import struct

    n_samples = int(sr * duration)
    data = b"".join(
        struct.pack("<h", ((i % 100) - 50) * 400)
        for i in range(n_samples)
    )
    return (
        b"RIFF"
        + struct.pack("<I", 36 + len(data))
        + b"WAVE"
        + b"fmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16)
        + b"data"
        + struct.pack("<I", len(data))
        + data
    )


class MockSubprocessProc:
    def __init__(self):
        self.returncode = None
        self.terminated = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = 0

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        return self.returncode

    def crash(self, returncode=9):
        self.returncode = returncode


def _free_port():
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _voice_profile(tmp_path, name, transcript=None, wav=None):
    from serve import VoiceProfile

    transcript = transcript or f"reference {name}"
    root = tmp_path / name
    root.mkdir()
    audio_path = root / f"{name}.wav"
    transcript_path = root / f"{name}.txt"
    audio_path.write_bytes(wav or _make_wav_bytes())
    transcript_path.write_text(transcript)
    return VoiceProfile(
        id=name,
        display_name=name.upper(),
        root_path=str(root),
        audio_path=str(audio_path),
        transcript_path=str(transcript_path),
        transcript=transcript)


def _make_qwentts_mock_server(port, events, stop_event):
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.parse import unquote
    import re

    voices = events.setdefault("voices", {})
    events.setdefault("registered", [])
    events.setdefault("deleted", [])
    events.setdefault("spoken", [])

    class MockHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def _reply(self, code, body=b"", content_type="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self._reply(200, b'{"status":"ok"}')
                return
            if self.path == "/v1/audio/voices":
                body = json.dumps({
                    "voices": [
                        {"name": key, "kind": "registered"}
                        for key in voices
                    ],
                }).encode()
                self._reply(200, body)
                return
            self._reply(404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            parsed = json.loads(self.rfile.read(length))
            if self.path == "/v1/audio/voices":
                if events.get("fail_registration"):
                    self._reply(400, b'{"error":{"message":"injected"}}')
                    return
                key = parsed["name"]
                assert key.startswith("wren-")
                assert re.fullmatch(r"[A-Za-z0-9_-]+", key)
                assert base64.b64decode(parsed["wav_b64"]).startswith(b"RIFF")
                voices[key] = parsed
                events["registered"].append(key)
                self._reply(
                    200,
                    json.dumps(
                        {"name": key, "status": "registered"}).encode())
                return
            if self.path == "/v1/audio/speech":
                key = parsed["voice"]
                assert key in voices
                assert parsed["response_format"] == "pcm"
                events["spoken"].append(key)
                pcm = b"\x00\x01" * (24000 * 5 // 2)
                self._reply(200, pcm, "audio/pcm")
                return
            self._reply(404)

        def do_DELETE(self):
            prefix = "/v1/audio/voices/"
            if not self.path.startswith(prefix):
                self._reply(404)
                return
            key = unquote(self.path[len(prefix):])
            assert key in voices
            del voices[key]
            events["deleted"].append(key)
            self._reply(200, b'{"status":"deleted"}')

    server = HTTPServer(("127.0.0.1", port), MockHandler)
    server.timeout = 0.05

    def serve_loop():
        while not stop_event.is_set():
            server.handle_request()

    threading.Thread(target=serve_loop, daemon=True).start()
    return server


def _qwentts_engine(port, process):
    from serve import load_qwentts_engine

    with patch("serve.subprocess.Popen", return_value=process):
        return load_qwentts_engine(
            model_id="unused",
            language="English",
            qwentts_bin="/fake/tts-server",
            qwentts_model="/fake/talker.gguf",
            qwentts_codec="/fake/codec.gguf",
            qwentts_port=port)


def test_qwentts_content_key_streaming_and_resident_child(tmp_path):
    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    process = MockSubprocessProc()
    engine = _qwentts_engine(port, process)
    try:
        profile = _voice_profile(tmp_path, "alpha")
        context = engine.prepare(profile)
        engine.retain(context)
        engine.release(context)
        paths = []

        def make_path():
            path = tmp_path / f"out-{len(paths)}.wav"
            paths.append(path)
            return str(path)

        rendered = list(engine.synthesize(
            context, "Hello world.", make_path))
        assert rendered == [str(path) for path in paths]
        assert len(rendered) == 3
        assert all(path.read_bytes().startswith(b"RIFF") for path in paths)
        assert events["spoken"] == [context.data]
        assert events["registered"] == [context.data]
        assert process.poll() is None
        engine.release(context)
    finally:
        engine.close()
        stop.set()
        server.server_close()
    assert process.terminated


def test_qwentts_startup_child_exit_is_explicit():
    from serve import load_qwentts_engine

    class StartupExit(MockSubprocessProc):
        def __init__(self):
            super().__init__()
            self.polls = 0

        def poll(self):
            self.polls += 1
            if self.polls >= 3:
                self.returncode = 1
            return self.returncode

    with patch("serve.subprocess.Popen", return_value=StartupExit()):
        with pytest.raises(RuntimeError, match="exited during startup"):
            load_qwentts_engine(
                "unused", "English",
                qwentts_bin="/fake/tts-server",
                qwentts_model="/fake/talker.gguf",
                qwentts_codec="/fake/codec.gguf",
                qwentts_port=_free_port())


def test_qwentts_cleanup_terminates_only_resident_child():
    import serve

    process = MockSubprocessProc()
    original = serve._qwentts_process
    serve._qwentts_process = process
    serve._cleanup_qwentts()
    assert process.terminated
    assert serve._qwentts_process is None
    serve._qwentts_process = original


def test_qwentts_loader_requires_all_child_flags():
    from serve import load_qwentts_engine

    with pytest.raises(RuntimeError, match="qwentts backend requires"):
        load_qwentts_engine(
            "unused", "English", qwentts_bin="/fake/tts-server")


def test_qwentts_pressure_never_evicts_pins_then_trims(tmp_path):
    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    engine = _qwentts_engine(port, MockSubprocessProc())
    try:
        contexts = [
            engine.prepare(_voice_profile(
                tmp_path, f"voice-{index}",
                transcript=f"reference {index}"))
            for index in range(20)
        ]
        protected = contexts[0]
        protected_key = protected.data
        # Transfer its preparation pin to active, then add queued and in-flight
        # pins. Every other context remains preparation-pinned.
        engine.retain(protected)
        engine.release(protected)
        engine.retain(protected)
        engine.retain(protected)
        assert len(engine._registrations) == 20
        assert events["deleted"] == []

        for context in contexts[1:]:
            engine.release(context)
        assert len(engine._registrations) <= engine.CACHE_LIMIT
        assert protected_key in engine._registrations
        assert protected_key not in events["deleted"]

        engine.release(protected)
        engine.release(protected)
        engine.release(protected)
        assert len(engine._registrations) <= engine.CACHE_LIMIT
    finally:
        engine.close()
        stop.set()
        server.server_close()


def test_qwentts_activation_a_to_b_to_a_reuses_child_and_key(tmp_path):
    from serve import activate_voice

    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    process = MockSubprocessProc()
    engine = _qwentts_engine(port, process)
    durable = []
    active = {"context": None}

    def persist(profile):
        durable.append(profile.id)

    def swap(context):
        previous, active["context"] = active["context"], context
        return previous

    try:
        profile_a = _voice_profile(tmp_path, "alpha")
        profile_b = _voice_profile(tmp_path, "bravo")
        initial = engine.prepare(profile_a)
        engine.retain(initial)
        engine.release(initial)
        active["context"] = initial
        durable.append("alpha")

        activate_voice(
            profile_b, engine.prepare, persist, swap,
            engine.retain, engine.release)
        activate_voice(
            profile_a, engine.prepare, persist, swap,
            engine.retain, engine.release)

        assert durable == ["alpha", "bravo", "alpha"]
        assert active["context"].profile.id == "alpha"
        assert len(events["registered"]) == 2
        assert process.poll() is None
        engine.release(active["context"])
    finally:
        engine.close()
        stop.set()
        server.server_close()


def test_activation_validation_and_registration_fail_before_commit(tmp_path):
    from serve import activate_voice

    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    engine = _qwentts_engine(port, MockSubprocessProc())
    durable = ["alpha"]
    active = {"context": None}
    try:
        profile_a = _voice_profile(tmp_path, "alpha")
        old = engine.prepare(profile_a)
        engine.retain(old)
        engine.release(old)
        active["context"] = old

        corrupt = _voice_profile(
            tmp_path, "corrupt", wav=b"not a wave file")
        with pytest.raises(ValueError, match="not a WAV"):
            activate_voice(
                corrupt, engine.prepare, lambda profile: durable.append(
                    profile.id),
                lambda context: active.update(context=context),
                engine.retain, engine.release)
        assert active["context"] is old
        assert durable == ["alpha"]

        events["fail_registration"] = True
        candidate = _voice_profile(tmp_path, "bravo")
        with pytest.raises(RuntimeError, match="failed to register"):
            activate_voice(
                candidate, engine.prepare, lambda profile: durable.append(
                    profile.id),
                lambda context: active.update(context=context),
                engine.retain, engine.release)
        assert active["context"] is old
        assert durable == ["alpha"]
        assert engine.health().usable
        engine.release(old)
    finally:
        engine.close()
        stop.set()
        server.server_close()


def test_activation_persistence_failure_rolls_back_preparation_pin(tmp_path):
    from serve import activate_voice

    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    engine = _qwentts_engine(port, MockSubprocessProc())
    durable = ["alpha"]
    active = {"context": None}
    try:
        old = engine.prepare(_voice_profile(tmp_path, "alpha"))
        engine.retain(old)
        engine.release(old)
        active["context"] = old
        candidate = _voice_profile(tmp_path, "bravo")

        def fail_persist(profile):
            raise OSError("disk full")

        with pytest.raises(OSError, match="disk full"):
            activate_voice(
                candidate, engine.prepare, fail_persist,
                lambda context: active.update(context=context),
                engine.retain, engine.release)

        candidate_key = events["registered"][-1]
        assert engine._registrations[candidate_key].pins == 0
        assert active["context"] is old
        assert durable == ["alpha"]
        engine.release(old)
    finally:
        engine.close()
        stop.set()
        server.server_close()


def test_activation_post_commit_crash_keeps_new_durable_choice(tmp_path):
    from serve import activate_voice

    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    engine = _qwentts_engine(port, MockSubprocessProc())
    durable = ["alpha"]
    active = {"context": None}
    try:
        old = engine.prepare(_voice_profile(tmp_path, "alpha"))
        engine.retain(old)
        engine.release(old)
        active["context"] = old
        candidate = _voice_profile(tmp_path, "bravo")

        def persist(profile):
            durable[:] = [profile.id]

        def crash_after_commit(context):
            raise SystemExit("injected crash")

        with pytest.raises(SystemExit, match="injected crash"):
            activate_voice(
                candidate, engine.prepare, persist, crash_after_commit,
                engine.retain, engine.release)
        assert durable == ["bravo"]
        assert active["context"] is old
    finally:
        engine.close()
        stop.set()
        server.server_close()


def test_qwentts_post_ready_child_exit_is_unhealthy_and_fails_synthesis(
        tmp_path):
    port = _free_port()
    events = {}
    stop = threading.Event()
    server = _make_qwentts_mock_server(port, events, stop)
    process = MockSubprocessProc()
    engine = _qwentts_engine(port, process)
    durable = ["alpha"]
    try:
        context = engine.prepare(_voice_profile(tmp_path, "alpha"))
        process.crash(23)
        health = engine.health()
        assert not health.usable
        assert health.error == {
            "code": "engine_child_exited",
            "message": "qwentts tts-server exited unexpectedly",
            "exit_code": 23,
        }
        with pytest.raises(RuntimeError, match="exited unexpectedly"):
            list(engine.synthesize(
                context, "Hello.", lambda: str(tmp_path / "out.wav")))
        assert durable == ["alpha"]
    finally:
        engine.close()
        stop.set()
        server.server_close()


def test_mlx_preparation_and_synthesis_stay_on_owner_thread(
        tmp_path, monkeypatch):
    import numpy as np
    from serve import MLXEngine

    owner = threading.get_ident()
    calls = {"loads": 0, "prepare_threads": [], "synth_threads": []}

    class Result:
        audio = np.zeros(100, dtype=np.float32)
        sample_rate = 24000

    class Model:
        sample_rate = 24000

        def extract_speaker_embedding(self, audio):
            calls["prepare_threads"].append(threading.get_ident())
            return object()

        def generate(self, **kwargs):
            calls["synth_threads"].append(threading.get_ident())
            yield Result()

    def load_model(model_id):
        calls["loads"] += 1
        return Model()

    def load_audio(path, sample_rate):
        return np.zeros(100, dtype=np.float32)

    modules = {
        "mlx_audio": types.ModuleType("mlx_audio"),
        "mlx_audio.tts": types.ModuleType("mlx_audio.tts"),
        "mlx_audio.tts.utils": types.ModuleType("mlx_audio.tts.utils"),
        "mlx_audio.utils": types.ModuleType("mlx_audio.utils"),
    }
    modules["mlx_audio.tts.utils"].load_model = load_model
    modules["mlx_audio.utils"].load_audio = load_audio
    for name, module in modules.items():
        monkeypatch.setitem(sys.modules, name, module)

    engine = MLXEngine("mock-model", "English")
    profiles = [
        _voice_profile(tmp_path, name)
        for name in ("alpha", "bravo", "charlie")
    ]
    contexts = [engine.prepare(profile) for profile in profiles]
    output = tmp_path / "mlx.wav"
    assert list(engine.synthesize(
        contexts[0], "hello", lambda: str(output))) == [str(output)]
    assert calls["loads"] == 1
    assert calls["prepare_threads"] == [owner, owner, owner]
    assert calls["synth_threads"] == [owner]

    errors = []
    thread = threading.Thread(
        target=lambda: _capture_error(
            errors, lambda: engine.prepare(profiles[0])))
    thread.start()
    thread.join()
    assert isinstance(errors[0], RuntimeError)
    assert "outside its SynthWorker" in str(errors[0])
    for context in contexts:
        engine.release(context)
    engine.close()


def _capture_error(errors, action):
    try:
        action()
    except Exception as exc:
        errors.append(exc)


def test_torch_engine_captures_reference_without_model_reload(
        tmp_path, monkeypatch):
    from serve import QwenTTSEngine

    calls = {"loads": 0, "references": []}

    class Model:
        def generate_voice_clone(self, **kwargs):
            calls["references"].append(kwargs["ref_audio"])
            return [[0.0] * 100], 24000

    class QwenModel:
        @classmethod
        def from_pretrained(cls, *args, **kwargs):
            calls["loads"] += 1
            return Model()

    torch = types.ModuleType("torch")
    torch.float32 = object()
    torch.float16 = object()
    torch.bfloat16 = object()
    qwen_tts = types.ModuleType("qwen_tts")
    qwen_tts.Qwen3TTSModel = QwenModel
    progress = types.ModuleType("progress_bar")
    progress.attach_progress_bar = lambda model: None
    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "qwen_tts", qwen_tts)
    monkeypatch.setitem(sys.modules, "progress_bar", progress)

    engine = QwenTTSEngine("mock-model", "English", device="cpu")
    profiles = [
        _voice_profile(tmp_path, name)
        for name in ("alpha", "bravo", "charlie")
    ]
    contexts = [engine.prepare(profile) for profile in profiles]
    assert calls["loads"] == 1
    assert all(isinstance(context.data[0], tuple) for context in contexts)
    original = Path(profiles[0].audio_path)
    original.write_bytes(b"changed after preparation")
    output = tmp_path / "torch.wav"
    assert list(engine.synthesize(
        contexts[0], "hello", lambda: str(output))) == [str(output)]
    assert calls["references"][0] is contexts[0].data[0]
    for context in contexts:
        engine.release(context)
    engine.close()

def test_activate_voice_persists_before_nonfailing_swap_and_releases_in_order():
    from serve import activate_voice

    profile = object()
    prepared = object()
    previous = object()
    events = []

    def prepare(value):
        assert value is profile
        events.append("prepare")
        return prepared

    def persist(value):
        assert value is profile
        events.append("persist")

    def retain(context):
        assert context is prepared
        events.append("retain-new-active")

    def swap(context):
        assert context is prepared
        assert events[-1] == "retain-new-active"
        events.append("swap")
        return previous

    def release(context):
        events.append(
            "release-preparation" if context is prepared
            else "release-previous-active")

    assert activate_voice(
        profile, prepare, persist, swap, retain, release) is prepared
    assert events == [
        "prepare",
        "persist",
        "retain-new-active",
        "swap",
        "release-preparation",
        "release-previous-active",
    ]


# --- management API v2 ---

def _management_profile(root, profile_id, display_name=None):
    import wave

    profile = root / profile_id
    profile.mkdir(parents=True)
    (profile / "profile.json").write_text(json.dumps({
        "schema_version": 2,
        "id": profile_id,
        "display_name": display_name or profile_id.title(),
    }))
    with wave.open(str(profile / "reference.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24000)
        output.writeframes(b"\0\0" * 24)
    (profile / "transcript.txt").write_text(
        f"{profile_id} reference transcript")
    return profile


def _management_stage(root, staging_id):
    import wave

    stage = root / ".staging" / staging_id
    stage.mkdir(parents=True)
    with wave.open(str(stage / "reference.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24000)
        output.writeframes(b"\0\0" * 24)
    (stage / "transcript.txt").write_text("staged reference transcript")
    return stage


def start_management_server(tmp_path, *, token=None, ready=True):
    from serve import SettingsStore, VoiceLibrary
    voices = tmp_path / "voices"
    voices.mkdir(parents=True)
    _management_profile(voices, "alpha")
    _management_profile(voices, "beta")
    library = VoiceLibrary(voices)
    library.initialize()
    settings_store = SettingsStore(
        tmp_path / "settings.json", None, library)
    settings_store.initialize()
    settings_store.set_active_voice("alpha")
    app = App(
        model_id="effective-model", token=token, backend="qwentts",
        host="127.0.0.1", port=0, voices_dir=voices,
        library=library, settings_store=settings_store)
    if ready:
        engine = SnapshotRecordingEngine()
        app.speaker = Speaker(
            engine=engine, voice_profile=library.resolve_ready("alpha"),
            play_fn=_recording_play([]))
        assert wait_for(app.speaker.ready.is_set)
        app.set_lifecycle("ready")
    else:
        engine = None
        app.set_lifecycle("loading", "The synthesis engine is loading.")
    server = make_server(app, port=0)
    app.port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, app.port, app, library, settings_store, engine


def management_headers(request_id=None, token=None):
    headers = {}
    if request_id is not None:
        headers["Idempotency-Key"] = request_id
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def management_error(port, path, *, body=None, method=None, headers=None):
    try:
        request(port, path, body, method, headers)
        assert False, f"expected error for {method or 'GET'} {path}"
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def wait_operation(port, request_id, headers=None):
    result = None

    def completed():
        nonlocal result
        result = request(
            port, f"/operations/{request_id}", headers=headers)[1]
        return result["phase"] in {"succeeded", "failed"}

    assert wait_for(completed)
    return result


def test_management_meta_auth_origin_and_effective_launch_truth(tmp_path):
    server, port, app, _, _, _ = start_management_server(
        tmp_path, token="sekrit", ready=False)
    try:
        status, body = management_error(port, "/meta")
        assert status == 401
        assert body["error"]["code"] == "authorization_required"
        status, body = management_error(
            port, "/meta", headers=management_headers(token="wrong"))
        assert status == 401
        assert body["error"]["message"] == (
            "A valid bearer token is required.")
        status, body = management_error(
            port, "/meta", headers={
                **management_headers(token="sekrit"),
                "Origin": "https://malicious.example",
            })
        assert status == 403
        assert body["error"]["code"] == "origin_not_allowed"

        headers = management_headers(token="sekrit")
        meta = request(port, "/meta", headers=headers)[1]
        state = request(port, "/state", headers=headers)[1]
        assert meta["service"] == "wren"
        assert meta["protocol_version"] == 2
        assert meta["instance_id"] == app.instance_id
        assert "state-v2" in meta["capabilities"]
        assert state["lifecycle"]["phase"] == "loading"
        assert state["synthesis"]["backend"] == "qwentts"
        assert state["synthesis"]["model"] == "effective-model"
        assert state["synthesis"]["host"] == "127.0.0.1"
        assert state["synthesis"]["port"] == port
        assert state["synthesis"]["voices_dir"] == str(
            (tmp_path / "voices").resolve())
        deployment = {
            "backend": "mlx",
            "model": "other-model",
            "host": "0.0.0.0",
            "port": 9999,
            "voices_dir": "/tmp/other-voices",
        }
        status, error = management_error(
            port, "/settings", body=deployment, method="PATCH",
            headers=management_headers(
                "deployment-facts-immutable", token="sekrit"))
        assert status == 400
        assert error["error"]["code"] == "request_field_unknown"
        assert error["error"]["detail"]["fields"] == sorted(deployment)
        unchanged = request(port, "/state", headers=headers)[1]["synthesis"]
        for key in deployment:
            assert unchanged[key] == state["synthesis"][key]
    finally:
        server.shutdown()


def test_management_state_and_voices_survive_loading_and_failure(tmp_path):
    server, port, app, _, settings_store, _ = start_management_server(
        tmp_path, ready=False)
    try:
        loading = request(port, "/state")[1]
        voices = request(port, "/voices")[1]
        assert loading["synthesis"]["ready"] is False
        assert loading["synthesis"]["active_voice"] is None
        assert settings_store.snapshot().active_voice == "alpha"
        assert loading["playback"] == {
            "pending": 0, "speaking": False, "paused": False}
        assert {voice["id"] for voice in voices["voices"]} == {
            "alpha", "beta"}
        failure = {
            "code": "engine_load_failed",
            "message": "The synthesis engine could not be loaded.",
            "detail": "mock load failure",
            "recoverable": True,
        }
        app.set_lifecycle("failed", failure["message"], failure)
        failed = request(port, "/state")[1]
        assert failed["revision"] > loading["revision"]
        assert failed["voices_revision"] == voices["revision"]
        assert failed["lifecycle"]["phase"] == "failed"
        assert failed["synthesis"]["active_voice"] is None
        assert settings_store.snapshot().active_voice == "alpha"
        assert failed["last_error"] == failure
        assert request(port, "/voices")[1] == voices
    finally:
        server.shutdown()


def test_management_settings_sync_replay_conflict_and_required_key(tmp_path):
    server, port, app, _, settings_store, _ = start_management_server(
        tmp_path)
    try:
        status, body = management_error(
            port, "/settings", body={"effects": True}, method="PATCH")
        assert status == 400
        assert body["error"]["code"] == "idempotency_key_required"

        headers = management_headers("settings-1")
        status, first = request(
            port, "/settings", {"effects": True}, "PATCH", headers)
        assert status == 200
        assert first["operation"] is None
        assert first["synthesis"]["effects"] is True
        assert settings_store.snapshot().effects is True
        status, replay = request(
            port, "/settings", {"effects": True}, "PATCH", headers)
        assert status == 200
        assert replay == first
        result = request(port, "/operations/settings-1")[1]
        assert result["phase"] == "succeeded"
        assert result["response"] == first

        status, conflict = management_error(
            port, "/settings", body={"effects": False}, method="PATCH",
            headers=headers)
        assert status == 409
        assert conflict["error"]["code"] == "request_id_conflict"
        assert app.state_snapshot()["synthesis"]["effects"] is True
    finally:
        server.shutdown()

def test_management_settings_completion_freezes_concurrent_replays(
        tmp_path, monkeypatch):
    server, port, app, library, _, _ = start_management_server(tmp_path)
    completion_boundary = threading.Event()
    release_completion = threading.Event()
    rename_entered = threading.Event()
    release_rename = threading.Event()
    original_changed = app.operations._changed
    original_update = library.update_metadata
    gate_lock = threading.Lock()
    completion_gated = [False]

    def gate_completion():
        original_changed()
        result = app.operations.result("settings-boundary")
        if result is None or result["phase"] != "succeeded":
            return
        with gate_lock:
            if completion_gated[0]:
                return
            completion_gated[0] = True
        completion_boundary.set()
        assert release_completion.wait(5)

    def slow_rename(profile_id, display_name):
        rename_entered.set()
        assert release_rename.wait(5)
        return original_update(profile_id, display_name)

    monkeypatch.setattr(app.operations, "_changed", gate_completion)
    monkeypatch.setattr(library, "update_metadata", slow_rename)
    responses = {}

    def send_initial_settings():
        try:
            responses["first"] = request(
                port, "/settings", {"effects": True}, "PATCH",
                management_headers("settings-boundary"))[1]
        except BaseException as exc:
            responses["error"] = exc

    initial = threading.Thread(target=send_initial_settings)
    initial.start()
    try:
        assert completion_boundary.wait(5)
        request(
            port, "/voices/beta", {"display_name": "Boundary Beta"},
            "PATCH", management_headers("rename-boundary"))
        assert rename_entered.wait(5)

        replay = request(
            port, "/settings", {"effects": True}, "PATCH",
            management_headers("settings-boundary"))[1]
        assert replay["operation"] is None
        assert replay == app.operations.result(
            "settings-boundary")["response"]

        release_completion.set()
        initial.join(timeout=5)
        assert not initial.is_alive()
        assert "error" not in responses
        assert responses["first"] == replay
        detached = app.operations.result("settings-boundary")
        detached["response"]["operation"] = {"phase": "committing"}
        assert app.operations.result(
            "settings-boundary")["response"] == replay
    finally:
        release_completion.set()
        release_rename.set()
        initial.join(timeout=5)
        server.shutdown()


@pytest.mark.parametrize(
    "payload",
    (
        b'{"default_synthesis_rate":1e999}',
        b'{"effects":false,"nested":[{"value":-1e999}]}',
    ),
)
def test_management_rejects_recursive_nonfinite_numbers(
        tmp_path, payload):
    server, port, _, _, _, _ = start_management_server(tmp_path)
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/settings",
            data=payload,
            method="PATCH",
            headers={"Idempotency-Key": "nonfinite"})
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(req, timeout=5)
        assert error.value.code == 400
        assert error.value.headers["Content-Type"] == "application/json"
        body = json.loads(error.value.read())
        assert body["error"]["code"] == "request_json_invalid"
        assert request(port, "/state")[0] == 200
    finally:
        server.shutdown()


def test_management_unexpected_exception_is_opaque_json(
        tmp_path, monkeypatch, capsys):
    server, port, app, _, _, _ = start_management_server(tmp_path)

    def unexpected():
        raise RuntimeError("diagnostic secret")

    monkeypatch.setattr(app, "meta_snapshot", unexpected)
    try:
        status, body = management_error(port, "/meta")
        assert status == 500
        assert body == {"error": {
            "code": "internal_error",
            "message": "The daemon could not process the management request.",
            "detail": None,
            "recoverable": True,
        }}
        assert "diagnostic secret" not in json.dumps(body)
        assert "diagnostic secret" in capsys.readouterr().err
    finally:
        server.shutdown()


def test_management_unsupported_methods_enforce_policy_and_json(tmp_path):
    server, port, _, _, _, _ = start_management_server(
        tmp_path, token="sekrit")
    url = f"http://127.0.0.1:{port}/state"
    methods = (
        "HEAD", "POST", "PATCH", "DELETE", "PUT", "OPTIONS", "TRACE", "FROB")

    def rejected(method, headers):
        req = urllib.request.Request(url, method=method, headers=headers)
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(req, timeout=5)
        response = error.value
        payload = response.read()
        assert response.headers["Content-Type"] == "application/json"
        assert response.headers["Content-Length"] != "0"
        if method == "HEAD":
            assert payload == b""
            return response.code, None, response.headers
        return response.code, json.loads(payload), response.headers

    try:
        for method in methods:
            status, body, _ = rejected(method, {})
            assert status == 401
            if body is not None:
                assert body["error"]["code"] == "authorization_required"

            status, body, _ = rejected(method, {
                "Authorization": "Bearer sekrit",
                "Origin": "https://malicious.example",
            })
            assert status == 403
            if body is not None:
                assert body["error"]["code"] == "origin_not_allowed"

            status, body, headers = rejected(
                method, {"Authorization": "Bearer sekrit"})
            assert status == 405
            assert headers["Allow"] == "GET"
            if body is not None:
                assert body["error"]["code"] == "method_not_allowed"
    finally:
        server.shutdown()


def test_management_nonloopback_bind_requires_token():
    from serve import _require_management_token

    for host in ("127.0.0.1", "::1", "localhost"):
        _require_management_token(host, None)
    _require_management_token("0.0.0.0", "sekrit")
    _require_management_token("192.0.2.10", "sekrit")

    with patch("serve.ThreadingHTTPServer") as constructor:
        with pytest.raises(SystemExit, match="set --token"):
            make_server(App(), port=0, host="0.0.0.0")
        constructor.assert_not_called()

    for host in ("0.0.0.0", "::", "192.0.2.10"):
        with pytest.raises(SystemExit, match="set --token"):
            _require_management_token(host, None)


def test_management_concurrent_mutation_busy_and_same_key_replay(
        tmp_path, monkeypatch):
    server, port, _, library, _, _ = start_management_server(tmp_path)
    entered = threading.Event()
    release = threading.Event()
    original = library.update_metadata

    def slow_update(profile_id, display_name):
        entered.set()
        assert release.wait(5)
        return original(profile_id, display_name)

    monkeypatch.setattr(library, "update_metadata", slow_update)
    try:
        headers = management_headers("rename-1")
        first = request(
            port, "/voices/beta", {"display_name": "Slow Beta"},
            "PATCH", headers)[1]
        assert first["id"] == "rename-1"
        assert entered.wait(5)

        replay = request(
            port, "/voices/beta", {"display_name": "Slow Beta"},
            "PATCH", headers)[1]
        assert replay["id"] == first["id"]
        status, busy = management_error(
            port, "/voices/beta", body={}, method="DELETE",
            headers=management_headers("delete-1"))
        assert status == 409
        assert busy["error"]["code"] == "operation_busy"
        assert busy["error"]["detail"]["active_operation"]["id"] == "rename-1"

        release.set()
        result = wait_operation(port, "rename-1")
        assert result["phase"] == "succeeded"
        voices = request(port, "/voices")[1]["voices"]
        assert next(
            voice for voice in voices if voice["id"] == "beta"
        )["display_name"] == "Slow Beta"
    finally:
        release.set()
        server.shutdown()


def test_management_full_voice_route_transitions_and_lookup(tmp_path):
    server, port, app, library, settings_store, _ = start_management_server(
        tmp_path)
    try:
        unknown_status, unknown = management_error(
            port, "/operations/not-known")
        assert unknown_status == 404
        assert unknown["error"]["code"] == "operation_result_unknown"

        _management_stage(library.root, "stage1")
        imported = request(
            port, "/voices/import", {
                "staging_id": "stage1",
                "id": "gamma",
                "display_name": "Gamma",
            }, headers=management_headers("import-1"))[1]
        assert imported["kind"] == "import_voice"
        assert wait_operation(port, "import-1")["phase"] == "succeeded"

        request(
            port, "/voices/gamma", {"display_name": "Gamma Prime"},
            "PATCH", management_headers("rename-gamma"))
        assert wait_operation(
            port, "rename-gamma")["phase"] == "succeeded"
        before_delete = request(port, "/voices")[1]["revision"]
        request(
            port, "/voices/gamma", {}, "DELETE",
            management_headers("delete-gamma"))
        assert wait_operation(
            port, "delete-gamma")["phase"] == "succeeded"
        assert request(port, "/voices")[1]["revision"] > before_delete

        request(
            port, "/voices/activate", {"voice": "beta"},
            headers=management_headers("activate-beta"))
        activated = wait_operation(port, "activate-beta")
        assert activated["phase"] == "succeeded"
        state = request(port, "/state")[1]
        assert state["synthesis"]["active_voice"] == "beta"
        assert settings_store.snapshot().active_voice == "beta"

        request(
            port, "/voices/beta", {}, "DELETE",
            management_headers("delete-active"))
        rejected = wait_operation(port, "delete-active")
        assert rejected["phase"] == "failed"
        assert rejected["error"]["code"] == "voice_delete_active"
        assert app.state_snapshot()["synthesis"]["active_voice"] == "beta"
    finally:
        server.shutdown()


def test_management_activation_failure_preserves_active_and_durable_voice(
        tmp_path, monkeypatch):
    from serve import ManagementFailure

    server, port, app, _, settings_store, _ = start_management_server(
        tmp_path)

    def fail_persist(profile_id):
        raise ManagementFailure(
            "settings_persist_failed",
            "Product settings could not be saved.",
            detail=f"mock failure for {profile_id}", status=500)

    monkeypatch.setattr(settings_store, "set_active_voice", fail_persist)
    try:
        before = request(port, "/state")[1]
        request(
            port, "/voices/activate", {"voice": "beta"},
            headers=management_headers("activate-fails"))
        result = wait_operation(port, "activate-fails")
        after = request(port, "/state")[1]
        assert result["phase"] == "failed"
        assert result["error"]["code"] == "settings_persist_failed"
        assert result["error"]["message"] == (
            "Product settings could not be saved.")
        assert settings_store.snapshot().active_voice == "alpha"
        assert before["synthesis"]["active_voice"] == "alpha"
        assert after["synthesis"]["active_voice"] == "alpha"
    finally:
        server.shutdown()


def test_management_revisions_are_instance_scoped_and_domain_separate(
        tmp_path):
    server, port, app, _, _, _ = start_management_server(tmp_path / "one")
    other_server, other_port, other_app, _, _, _ = start_management_server(
        tmp_path / "two")
    try:
        first = request(port, "/state")[1]
        first_voices = request(port, "/voices")[1]
        other = request(other_port, "/state")[1]
        assert app.instance_id != other_app.instance_id
        assert first["revision"] == other["revision"]
        assert first["voices_revision"] == other["voices_revision"]

        app.set_lifecycle("degraded", "mock degradation")
        state_only = request(port, "/state")[1]
        assert state_only["revision"] > first["revision"]
        assert state_only["voices_revision"] == first_voices["revision"]

        request(
            port, "/voices/alpha", {"display_name": "Alpha Prime"},
            "PATCH", management_headers("rename-alpha"))
        assert wait_operation(port, "rename-alpha")["phase"] == "succeeded"
        changed_voices = request(port, "/voices")[1]
        assert changed_voices["revision"] > first_voices["revision"]
        assert request(other_port, "/voices")[1]["revision"] == (
            other["voices_revision"])
    finally:
        server.shutdown()
        other_server.shutdown()


# --- legacy management cutover ---

def test_config_path_is_not_routed(tmp_path):
    server, port = start_server([])
    try:
        for method, body in ((None, None), ("POST", {})):
            status, response = management_error(
                port, "/config", body=body, method=method)
            assert status == 404
            assert response == {"error": "not found"}
    finally:
        server.shutdown()


def test_post_speak_non_object_json_body_is_400(tmp_path):
    server, port = start_server([])
    try:
        for raw in (b"5", b"null", b"true", b"[1, 2]", b'"hello"'):
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/speak",
                data=raw, method="POST")
            try:
                urllib.request.urlopen(req, timeout=5)
                assert False, f"expected 400 for {raw!r}"
            except urllib.error.HTTPError as error:
                assert error.code == 400
                assert json.loads(error.read())["error"]
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
        for channel, epoch, expected in (
                ("cha", "1", b"aa"), ("chb", "0", b"ba")):
            with raw_request(
                    port,
                    f"/segment?after=0&timeout=0.05&channel={channel}") as resp:
                payload = resp.read()
                assert resp.status == 200
                assert resp.headers["Content-Type"] == "audio/wav"
                assert resp.headers["Content-Length"] == str(len(payload))
                assert resp.headers["X-Seq"] == "1"
                assert resp.headers["X-Epoch"] == epoch
                assert resp.headers.get("X-Block") is None
                assert payload == expected
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


def test_runtime_setting_flags_are_removed(monkeypatch, capsys):
    import pytest
    from serve import parse_args

    for arguments in (["--speed", "1.2"], ["--fx"]):
        monkeypatch.setattr(
            sys, "argv", ["serve.py", "-r", "x.wav", *arguments])
        with pytest.raises(SystemExit):
            parse_args()
        assert arguments[0] in capsys.readouterr().err


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


# --- schema-v2 storage and migration ---

def _storage_profile(root, profile_id, *, display_name=None, audio=None,
                     transcript="reference transcript", metadata=None):
    profile = root / profile_id
    profile.mkdir(parents=True)
    if metadata is not False:
        payload = metadata or {
            "schema_version": 2,
            "id": profile_id,
            "display_name": display_name or profile_id.title(),
        }
        (profile / "profile.json").write_text(json.dumps(payload))
    if audio is not False:
        (profile / "reference.wav").write_bytes(
            _make_wav_bytes() if audio is None else audio)
    if transcript is not False:
        (profile / "transcript.txt").write_text(transcript)
    return profile


def _storage_flat_pair(root, profile_id, *, audio=None,
                       transcript="legacy transcript"):
    wav = root / f"{profile_id}.wav"
    text = root / f"{profile_id}.txt"
    wav.write_bytes(_make_wav_bytes() if audio is None else audio)
    text.write_text(transcript)
    return wav, text


def _voice_entry(snapshot, profile_id):
    return next(voice for voice in snapshot.voices
                if voice.id == profile_id)


def test_storage_scan_lists_ready_incomplete_invalid_and_hides_dot_dirs(
        tmp_path):
    from serve import ManagementFailure, VoiceLibrary, VoiceProfile

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "ready_voice")
    _storage_profile(voices, "missing_text", transcript=False)
    _storage_profile(voices, "broken_audio", audio=b"not a wav")
    _storage_profile(voices, ".hidden")

    library = VoiceLibrary(voices)
    snapshot = library.initialize()

    assert [voice.id for voice in snapshot.voices] == [
        "broken_audio", "missing_text", "ready_voice"]
    assert _voice_entry(snapshot, "ready_voice").status == "ready"
    incomplete = _voice_entry(snapshot, "missing_text")
    assert incomplete.status == "incomplete"
    assert incomplete.issues[0].code == "voice_transcript_missing"
    invalid = _voice_entry(snapshot, "broken_audio")
    assert invalid.status == "invalid"
    assert invalid.issues[0].code == "voice_audio_invalid"
    assert isinstance(library.resolve_ready("ready_voice"), VoiceProfile)
    with pytest.raises(ManagementFailure) as error:
        library.resolve_ready("broken_audio")
    assert error.value.code == "voice_audio_invalid"


def test_storage_legacy_migration_is_atomic_retains_sources_and_manifest(
        tmp_path):
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "old_voice")

    library = VoiceLibrary(voices)
    snapshot = library.initialize()

    entry = _voice_entry(snapshot, "old_voice")
    assert entry.status == "ready"
    profile = voices / "old_voice"
    assert (profile / "reference.wav").read_bytes() == wav.read_bytes()
    assert (profile / "transcript.txt").read_text() == transcript.read_text()
    assert json.loads((profile / "profile.json").read_text()) == {
        "schema_version": 2,
        "id": "old_voice",
        "display_name": "old_voice",
    }
    assert wav.exists() and transcript.exists()
    manifest = json.loads(
        (voices / ".migration-backups-v2.json").read_text())
    assert manifest["legacy_voice_sources"] == [{
        "id": "old_voice",
        "wav": str(wav.resolve()),
        "transcript": str(transcript.resolve()),
    }]
    assert list((voices / ".staging").iterdir()) == []
    assert [voice.id for voice in library.scan().voices] == ["old_voice"]


def test_storage_migration_leaves_incomplete_and_collision_untouched(tmp_path):
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    lone_wav = voices / "no_text.wav"
    lone_wav.write_bytes(_make_wav_bytes())
    existing = _storage_profile(voices, "collision", display_name="Existing")
    flat_wav, flat_text = _storage_flat_pair(voices, "collision")
    original_metadata = (existing / "profile.json").read_bytes()

    snapshot = VoiceLibrary(voices).initialize()

    incomplete = _voice_entry(snapshot, "no_text")
    assert incomplete.status == "incomplete"
    assert incomplete.issues[0].code == "voice_transcript_missing"
    collision = _voice_entry(snapshot, "collision")
    assert collision.status == "ready"
    assert any(issue.code == "legacy_voice_collision"
               for issue in collision.issues)
    assert (existing / "profile.json").read_bytes() == original_metadata
    assert lone_wav.exists() and flat_wav.exists() and flat_text.exists()


def test_storage_migration_rename_failure_cleans_stage_and_keeps_sources(
        tmp_path, monkeypatch):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "reader")

    def fail_rename(source, destination):
        raise OSError("rename unavailable")

    monkeypatch.setattr(storage, "_rename_noreplace", fail_rename)
    library = VoiceLibrary(voices)
    snapshot = library.initialize()

    assert _voice_entry(snapshot, "reader").status == "invalid"
    assert _voice_entry(snapshot, "reader").issues[0].code == (
        "legacy_voice_migration_failed")
    assert wav.exists() and transcript.exists()
    assert not (voices / "reader").exists()
    assert list((voices / ".staging").iterdir()) == []


def test_storage_migration_corrupt_audio_never_commits_profile(tmp_path):
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(
        voices, "corrupt", audio=b"broken")

    snapshot = VoiceLibrary(voices).initialize()

    entry = _voice_entry(snapshot, "corrupt")
    assert entry.status == "invalid"
    assert entry.issues[0].code == "voice_audio_invalid"
    assert wav.exists() and transcript.exists()
    assert not (voices / "corrupt").exists()
    assert list((voices / ".staging").iterdir()) == []


def test_storage_import_commit_writes_authoritative_metadata(tmp_path):
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    library = VoiceLibrary(voices)
    library.initialize()
    stage = voices / ".staging" / "client-stage"
    stage.mkdir()
    (stage / "reference.wav").write_bytes(_make_wav_bytes())
    (stage / "transcript.txt").write_text("client transcript")
    (stage / "profile.json").write_text(
        '{"schema_version": 999, "id": "evil", "display_name": "Evil"}')

    profile = library.import_staged(
        "client-stage", "new_voice", "New Voice", "request-1")

    assert profile.id == "new_voice"
    assert not stage.exists()
    assert json.loads(
        (voices / "new_voice" / "profile.json").read_text()) == {
        "schema_version": 2,
        "id": "new_voice",
        "display_name": "New Voice",
    }
    assert _voice_entry(library.snapshot(), "new_voice").status == "ready"


@pytest.mark.parametrize(
    "profile_id,audio,transcript,expected_code",
    (
        ("unsafe/voice", None, "text", "voice_id_invalid"),
        ("corrupt", b"broken", "text", "voice_audio_invalid"),
        ("missing_text", None, False, "voice_transcript_missing"),
    ),
)
def test_storage_failed_import_removes_staging(
        tmp_path, profile_id, audio, transcript, expected_code):
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    library = VoiceLibrary(voices)
    library.initialize()
    stage_id = "failed-stage"
    stage = voices / ".staging" / stage_id
    stage.mkdir()
    (stage / "reference.wav").write_bytes(
        _make_wav_bytes() if audio is None else audio)
    if transcript is not False:
        (stage / "transcript.txt").write_text(transcript)

    with pytest.raises(ManagementFailure) as error:
        library.import_staged(
            stage_id, profile_id, "Failed Voice", "request-failed")

    assert error.value.code == expected_code
    assert not stage.exists()
    safe_destination = voices / profile_id
    if safe_destination.parent == voices:
        assert not safe_destination.exists()


def test_storage_import_collision_removes_stage_without_overwrite(tmp_path):
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    existing = _storage_profile(voices, "same", display_name="Original")
    original = (existing / "profile.json").read_bytes()
    library = VoiceLibrary(voices)
    library.initialize()
    stage = voices / ".staging" / "collision-stage"
    stage.mkdir()
    (stage / "reference.wav").write_bytes(_make_wav_bytes())
    (stage / "transcript.txt").write_text("replacement")

    with pytest.raises(ManagementFailure) as error:
        library.import_staged(
            "collision-stage", "same", "Replacement", "request-collision")

    assert error.value.code == "voice_id_collision"
    assert not stage.exists()
    assert (existing / "profile.json").read_bytes() == original


def test_storage_import_rejects_arbitrary_stage_path_without_touching_it(
        tmp_path):
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    outside.mkdir()
    marker = outside / "keep"
    marker.write_text("safe")
    library = VoiceLibrary(voices)
    library.initialize()

    with pytest.raises(ManagementFailure) as error:
        library.import_staged(
            "../outside", "voice", "Voice", "request-traversal")

    assert error.value.code == "staging_id_invalid"
    assert marker.read_text() == "safe"


def test_storage_import_metadata_failure_cleans_stage(tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    library = VoiceLibrary(voices)
    library.initialize()
    stage = voices / ".staging" / "metadata-stage"
    stage.mkdir()
    (stage / "reference.wav").write_bytes(_make_wav_bytes())
    (stage / "transcript.txt").write_text("reference")
    original_write = storage._atomic_write_json

    def fail_metadata(path, value):
        if Path(path).name == "profile.json":
            raise OSError("metadata disk full")
        return original_write(path, value)

    monkeypatch.setattr(storage, "_atomic_write_json", fail_metadata)
    with pytest.raises(OSError, match="metadata disk full"):
        library.import_staged(
            "metadata-stage", "voice", "Voice", "request-metadata")

    assert not stage.exists()
    assert not (voices / "voice").exists()


def test_storage_metadata_replacement_failure_preserves_old_profile(
        tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    profile = _storage_profile(voices, "voice", display_name="Before")
    before = (profile / "profile.json").read_bytes()
    library = VoiceLibrary(voices)
    library.initialize()

    def fail_replace(source, destination):
        raise OSError("replace failed")

    monkeypatch.setattr(storage.os, "replace", fail_replace)
    with pytest.raises(ManagementFailure) as error:
        library.update_metadata("voice", "After")

    assert error.value.code == "voice_metadata_write_failed"
    assert (profile / "profile.json").read_bytes() == before
    assert library.resolve_ready("voice").display_name == "Before"


def test_storage_delete_rejects_active_and_captured_profiles(tmp_path):
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "voice")
    library = VoiceLibrary(voices)
    library.initialize()

    with pytest.raises(ManagementFailure) as active:
        library.delete(
            "voice", "delete-active", active_voice="voice",
            defer_cleanup=False)
    assert active.value.code == "voice_delete_active"
    with pytest.raises(ManagementFailure) as captured:
        library.delete(
            "voice", "delete-captured",
            is_captured=lambda profile_id: profile_id == "voice",
            defer_cleanup=False)
    assert captured.value.code == "voice_delete_in_use"
    assert (voices / "voice").is_dir()
    assert list((voices / ".trash").iterdir()) == []


def test_storage_delete_rename_failure_leaves_original(tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "voice")
    library = VoiceLibrary(voices)
    library.initialize()

    def fail_rename(source, destination):
        raise OSError("rename failed")

    monkeypatch.setattr(storage, "_rename_noreplace", fail_rename)
    with pytest.raises(ManagementFailure) as error:
        library.delete("voice", "delete-failed", defer_cleanup=False)

    assert error.value.code == "voice_delete_commit_failed"
    assert (voices / "voice").is_dir()
    assert list((voices / ".trash").iterdir()) == []


def test_storage_delete_moves_atomically_and_startup_resumes_trash_cleanup(
        tmp_path, monkeypatch):
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "voice")
    library = VoiceLibrary(voices)
    library.initialize()

    snapshot = library.delete(
        "voice", "delete-kept", defer_cleanup=False)

    assert not (voices / "voice").exists()
    assert not any(voice.id == "voice" for voice in snapshot.voices)
    assert (voices / ".trash" / "delete-kept").is_dir()

    restarted = VoiceLibrary(voices)
    monkeypatch.setattr(
        restarted, "resume_trash_cleanup", restarted.cleanup_trash)
    restarted.initialize()
    assert list((voices / ".trash").iterdir()) == []


def test_storage_settings_migrate_after_voice_and_preserve_both_backups(
        tmp_path):
    from serve import ProductSettings, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "reader")
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "reader",
        "voices_dir": str(voices),
        "fx": True,
        "speed": 1.25,
        "backend": "qwentts",
        "port": 8765,
    }))
    settings_path = tmp_path / "settings.json"
    library = VoiceLibrary(voices)
    store = SettingsStore(settings_path, legacy, library)

    settings = store.initialize()

    assert settings == ProductSettings(
        active_voice="reader", effects=True,
        default_synthesis_rate=1.25)
    assert json.loads(settings_path.read_text()) == {
        "schema_version": 2,
        "active_voice": "reader",
        "effects": True,
        "default_synthesis_rate": 1.25,
    }
    assert library.resolve_ready("reader").id == "reader"
    assert wav.exists() and transcript.exists() and legacy.exists()
    manifest = json.loads(
        (voices / ".migration-backups-v2.json").read_text())
    assert manifest["legacy_config"] == str(legacy.resolve())

    legacy.write_text(json.dumps({
        "voice": "reader",
        "voices_dir": str(voices),
        "fx": False,
        "speed": 2.5,
        "backend": "mlx",
        "port": 9999,
    }))
    restarted = SettingsStore(settings_path, legacy, library)
    assert restarted.initialize() == settings
    assert json.loads(settings_path.read_text()) == settings.as_dict()


def test_storage_invalid_legacy_json_is_recoverable_without_settings_write(
        tmp_path):
    from serve import ManagementFailure, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "reader")
    legacy = tmp_path / "config.json"
    legacy.write_text('{"voice":')
    settings_path = tmp_path / "settings.json"

    with pytest.raises(ManagementFailure) as error:
        SettingsStore(
            settings_path, legacy, VoiceLibrary(voices)).initialize()

    assert error.value.code == "legacy_config_invalid"
    assert not settings_path.exists()
    assert (voices / "reader").is_dir()
    assert wav.exists() and transcript.exists() and legacy.exists()


def test_storage_unready_legacy_selection_does_not_write_settings(tmp_path):
    from serve import ManagementFailure, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "reader", transcript=False)
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "reader", "voices_dir": str(voices),
        "fx": False, "speed": 1.0,
    }))
    settings_path = tmp_path / "settings.json"

    with pytest.raises(ManagementFailure) as error:
        SettingsStore(
            settings_path, legacy, VoiceLibrary(voices)).initialize()

    assert error.value.code == "settings_active_voice_not_ready"
    assert not settings_path.exists()
    assert legacy.exists()


def test_storage_migration_error_blocks_settings_without_partial_file(
        tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_flat_pair(voices, "reader")
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "reader", "voices_dir": str(voices),
        "fx": False, "speed": 1.0,
    }))
    settings_path = tmp_path / "settings.json"

    def fail_rename(source, destination):
        raise OSError("migration rename failed")

    monkeypatch.setattr(storage, "_rename_noreplace", fail_rename)
    with pytest.raises(ManagementFailure) as error:
        SettingsStore(
            settings_path, legacy, VoiceLibrary(voices)).initialize()

    assert error.value.code == "voice_migration_incomplete"
    assert not settings_path.exists()


def test_storage_settings_write_failure_does_not_apply_memory_or_disk(
        tmp_path, monkeypatch):
    import storage
    from serve import (
        ManagementFailure, ProductSettings, SettingsStore, VoiceLibrary)

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "reader")
    settings_path = tmp_path / "settings.json"
    initial = ProductSettings(active_voice="reader")
    settings_path.write_text(json.dumps(asdict(initial)))
    store = SettingsStore(
        settings_path, None, VoiceLibrary(voices))
    assert store.initialize() == initial
    before = settings_path.read_bytes()

    def fail_write(path, value):
        raise OSError("disk full")

    monkeypatch.setattr(storage, "_atomic_write_json", fail_write)
    with pytest.raises(ManagementFailure) as error:
        store.update(effects=True, default_synthesis_rate=1.5)

    assert error.value.code == "settings_persist_failed"
    assert store.current == initial
    assert settings_path.read_bytes() == before


def test_storage_settings_reject_unknown_and_unready_partial_updates(tmp_path):
    from serve import ManagementFailure, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "reader")
    store = SettingsStore(
        tmp_path / "settings.json", None, VoiceLibrary(voices))
    store.initialize()

    with pytest.raises(ManagementFailure) as unknown:
        store.update(backend="mlx")
    assert unknown.value.code == "settings_key_unknown"
    with pytest.raises(ManagementFailure) as unready:
        store.set_active_voice("missing")
    assert unready.value.code == "settings_active_voice_not_ready"
    assert store.current.active_voice is None
    assert not (tmp_path / "settings.json").exists()


def test_storage_import_rename_failure_removes_stage_and_destination(
        tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    library = VoiceLibrary(voices)
    library.initialize()
    stage = voices / ".staging" / "rename-stage"
    stage.mkdir()
    (stage / "reference.wav").write_bytes(_make_wav_bytes())
    (stage / "transcript.txt").write_text("reference")

    def fail_rename(source, destination):
        raise OSError("rename failed")

    monkeypatch.setattr(storage, "_rename_noreplace", fail_rename)
    with pytest.raises(ManagementFailure) as error:
        library.import_staged(
            "rename-stage", "voice", "Voice", "request-rename")

    assert error.value.code == "voice_import_commit_failed"
    assert not stage.exists()
    assert not (voices / "voice").exists()


def test_storage_settings_migration_write_failure_keeps_legacy_and_no_state(
        tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_flat_pair(voices, "reader")
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "reader",
        "voices_dir": str(voices),
        "fx": False,
        "speed": 1.0,
    }))
    settings_path = tmp_path / "settings.json"
    original_write = storage._atomic_write_json

    def fail_settings(path, value):
        if Path(path) == settings_path:
            raise OSError("settings disk full")
        return original_write(path, value)

    monkeypatch.setattr(storage, "_atomic_write_json", fail_settings)
    store = SettingsStore(
        settings_path, legacy, VoiceLibrary(voices))
    with pytest.raises(ManagementFailure) as error:
        store.initialize()

    assert error.value.code == "settings_persist_failed"
    assert store.current is None
    assert not settings_path.exists()
    assert legacy.exists()
    assert (voices / "reader").is_dir()


def test_storage_settings_file_requires_exact_schema(tmp_path):
    from serve import ManagementFailure, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "reader")
    settings_path = tmp_path / "settings.json"
    settings_path.write_text(json.dumps({
        "schema_version": 2,
        "active_voice": "reader",
        "effects": False,
        "default_synthesis_rate": 1.0,
        "backend": "mlx",
    }))
    store = SettingsStore(
        settings_path, None, VoiceLibrary(voices))

    with pytest.raises(ManagementFailure) as error:
        store.initialize()

    assert error.value.code == "settings_invalid"
    assert store.current is None


def _arm_storage_directory_fsync_failure(monkeypatch, storage, event):
    original_fsync = storage.os.fsync
    state = {"armed": False}

    def hook(current, **details):
        del details
        if current == event:
            state["armed"] = True

    def fsync(fd):
        if (state["armed"]
                and storage.stat.S_ISDIR(storage.os.fstat(fd).st_mode)):
            state["armed"] = False
            raise OSError("injected post-rename directory fsync failure")
        return original_fsync(fd)

    monkeypatch.setattr(storage, "_storage_test_hook", hook)
    monkeypatch.setattr(storage.os, "fsync", fsync)


@pytest.mark.parametrize("control_name", (".staging", ".trash"))
def test_storage_rejects_symlinked_root_and_control_directories(
        tmp_path, control_name):
    from serve import ManagementFailure, VoiceLibrary

    real = tmp_path / "real"
    real.mkdir()
    alias = tmp_path / "alias"
    alias.symlink_to(real, target_is_directory=True)
    with pytest.raises(ManagementFailure) as root_error:
        VoiceLibrary(alias).initialize()
    assert root_error.value.code == "voice_library_unsafe"

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    voices.mkdir()
    outside.mkdir()
    marker = outside / "keep"
    marker.write_text("safe")
    (voices / control_name).symlink_to(outside, target_is_directory=True)

    with pytest.raises(ManagementFailure) as control_error:
        VoiceLibrary(voices).initialize()

    assert control_error.value.code == "voice_library_unsafe"
    assert marker.read_text() == "safe"


def test_storage_rejects_symlinked_operation_children_without_external_access(
        tmp_path):
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    outside.mkdir()
    marker = outside / "keep"
    marker.write_text("safe")
    library = VoiceLibrary(voices)
    library.initialize()
    (voices / ".staging" / "client").symlink_to(
        outside, target_is_directory=True)

    with pytest.raises(ManagementFailure) as staged:
        library.import_staged(
            "client", "voice", "Voice", "symlinked-stage")
    assert staged.value.code == "staged_import_not_found"

    _storage_profile(voices, "voice")
    library.scan()
    (voices / ".trash" / "delete-op").symlink_to(
        outside, target_is_directory=True)
    with pytest.raises(ManagementFailure) as trash:
        library.delete("voice", "delete-op", defer_cleanup=False)
    assert trash.value.code == "voice_trash_collision"
    assert marker.read_text() == "safe"


@pytest.mark.parametrize(
    "file_name,expected_code",
    (
        ("profile.json", "voice_metadata_invalid"),
        ("reference.wav", "voice_audio_missing"),
        ("transcript.txt", "voice_transcript_missing"),
    ),
)
def test_storage_rejects_symlinked_required_profile_files(
        tmp_path, file_name, expected_code):
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    voices.mkdir()
    outside.mkdir()
    profile = _storage_profile(voices, "voice")
    target = outside / file_name
    target.write_bytes((profile / file_name).read_bytes())
    (profile / file_name).unlink()
    (profile / file_name).symlink_to(target)

    entry = _voice_entry(VoiceLibrary(voices).initialize(), "voice")

    assert entry.status != "ready"
    assert entry.issues[0].code == expected_code


def test_storage_ignores_symlinked_profile_directory(tmp_path):
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    voices.mkdir()
    outside.mkdir()
    _storage_profile(outside, "external")
    (voices / "external").symlink_to(
        outside / "external", target_is_directory=True)
    library = VoiceLibrary(voices)

    assert library.initialize().voices == ()
    with pytest.raises(ManagementFailure) as error:
        library.resolve_ready("external")
    assert error.value.code == "voice_not_found"


def test_storage_import_swap_race_never_reads_or_commits_external_stage(
        tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    outside.mkdir()
    marker = outside / "keep"
    marker.write_text("safe")
    library = VoiceLibrary(voices)
    library.initialize()
    stage = voices / ".staging" / "client"
    stage.mkdir()
    (stage / "reference.wav").write_bytes(_make_wav_bytes())
    (stage / "transcript.txt").write_text("reference")

    def swap(event, **details):
        del details
        if event != "import_before_rename":
            return
        moved = voices / ".staging" / "moved"
        stage.rename(moved)
        stage.symlink_to(outside, target_is_directory=True)

    monkeypatch.setattr(storage, "_storage_test_hook", swap)
    with pytest.raises(ManagementFailure) as error:
        library.import_staged("client", "voice", "Voice", "swap-import")

    assert error.value.code == "voice_library_unsafe"
    assert not (voices / "voice").exists()
    assert marker.read_text() == "safe"


def test_storage_delete_swap_race_never_renames_external_profile(
        tmp_path, monkeypatch):
    import storage
    from serve import ManagementFailure, VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    voices.mkdir()
    outside.mkdir()
    marker = _storage_profile(outside, "external") / "transcript.txt"
    profile = _storage_profile(voices, "voice")
    library = VoiceLibrary(voices)
    library.initialize()

    def swap(event, **details):
        del details
        if event != "delete_before_rename":
            return
        profile.rename(voices / "voice-moved")
        profile.symlink_to(outside / "external", target_is_directory=True)

    monkeypatch.setattr(storage, "_storage_test_hook", swap)
    with pytest.raises(ManagementFailure) as error:
        library.delete("voice", "swap-delete", defer_cleanup=False)

    assert error.value.code == "voice_library_unsafe"
    assert marker.read_text() == "reference transcript"
    assert not (voices / ".trash" / "swap-delete").exists()


def test_storage_cleanup_swap_cannot_delete_moved_or_external_tree(
        tmp_path, monkeypatch):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    outside = tmp_path / "outside"
    voices.mkdir()
    outside.mkdir()
    library = VoiceLibrary(voices)
    library.initialize()
    trash = voices / ".trash" / "retained"
    trash.mkdir()
    (trash / "nested").mkdir()
    marker = trash / "nested" / "keep"
    marker.write_text("safe")
    moved = outside / "moved"
    swapped = {"done": False}

    def swap(event, **details):
        del details
        if event != "cleanup_before_child" or swapped["done"]:
            return
        swapped["done"] = True
        trash.rename(moved)
        trash.symlink_to(moved, target_is_directory=True)

    monkeypatch.setattr(storage, "_storage_test_hook", swap)
    library.cleanup_trash()

    assert (moved / "nested" / "keep").read_text() == "safe"
    assert trash.is_symlink()


def test_storage_post_rename_fsync_failure_applies_metadata(
        tmp_path, monkeypatch):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    profile = _storage_profile(voices, "voice", display_name="Before")
    library = VoiceLibrary(voices)
    library.initialize()
    _arm_storage_directory_fsync_failure(
        monkeypatch, storage, "atomic_before_replace")

    updated = library.update_metadata("voice", "After")

    assert updated.display_name == "After"
    assert json.loads((profile / "profile.json").read_text())[
        "display_name"] == "After"
    assert library.durability_diagnostic is not None


def test_storage_post_rename_fsync_failure_applies_import(
        tmp_path, monkeypatch):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    library = VoiceLibrary(voices)
    library.initialize()
    stage = voices / ".staging" / "client"
    stage.mkdir()
    (stage / "reference.wav").write_bytes(_make_wav_bytes())
    (stage / "transcript.txt").write_text("reference")
    _arm_storage_directory_fsync_failure(
        monkeypatch, storage, "import_before_rename")

    profile = library.import_staged(
        "client", "voice", "Voice", "fsync-import")

    assert profile.id == "voice"
    assert (voices / "voice").is_dir()
    assert library.durability_diagnostic is not None


def test_storage_post_rename_fsync_failure_applies_delete(
        tmp_path, monkeypatch):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "voice")
    library = VoiceLibrary(voices)
    library.initialize()
    _arm_storage_directory_fsync_failure(
        monkeypatch, storage, "delete_before_rename")

    snapshot = library.delete(
        "voice", "fsync-delete", defer_cleanup=False)

    assert not any(voice.id == "voice" for voice in snapshot.voices)
    assert (voices / ".trash" / "fsync-delete").is_dir()
    assert library.durability_diagnostic is not None


def test_storage_post_rename_fsync_failure_applies_settings(
        tmp_path, monkeypatch):
    import storage
    from serve import ProductSettings, SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    settings_path = tmp_path / "settings.json"
    settings_path.write_text(json.dumps(asdict(ProductSettings())))
    store = SettingsStore(settings_path, None, VoiceLibrary(voices))
    store.initialize()
    _arm_storage_directory_fsync_failure(
        monkeypatch, storage, "atomic_before_replace")

    settings = store.update(effects=True)

    assert settings.effects is True
    assert json.loads(settings_path.read_text())["effects"] is True
    assert store.durability_diagnostic is not None


def test_storage_pending_voice_journal_repairs_manifest_after_interruption(
        tmp_path, monkeypatch):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "reader")

    def interrupt(event, **details):
        del details
        if event == "migration_after_rename":
            raise RuntimeError("interrupted before manifest")

    monkeypatch.setattr(storage, "_storage_test_hook", interrupt)
    first = VoiceLibrary(voices)
    first.initialize()
    assert (voices / "reader").is_dir()
    assert (voices / ".migration-pending-v2.json").is_file()

    monkeypatch.setattr(storage, "_storage_test_hook", lambda *args, **kw: None)
    restarted = VoiceLibrary(voices)
    snapshot = restarted.initialize()
    manifest = json.loads(
        (voices / ".migration-backups-v2.json").read_text())

    assert _voice_entry(snapshot, "reader").status == "ready"
    assert manifest["legacy_voice_sources"] == [{
        "id": "reader",
        "wav": str(wav.resolve()),
        "transcript": str(transcript.resolve()),
    }]
    assert not (voices / ".migration-pending-v2.json").exists()


def test_storage_pending_settings_journal_repairs_existing_settings_fast_path(
        tmp_path, monkeypatch):
    import storage
    from serve import SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "reader")
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "reader",
        "voices_dir": str(voices),
        "fx": True,
        "speed": 1.25,
    }))
    settings_path = tmp_path / "settings.json"

    def interrupt(event, **details):
        del details
        if event == "settings_after_commit":
            raise RuntimeError("interrupted before manifest")

    monkeypatch.setattr(storage, "_storage_test_hook", interrupt)
    with pytest.raises(RuntimeError, match="interrupted before manifest"):
        SettingsStore(
            settings_path, legacy, VoiceLibrary(voices)).initialize()
    assert settings_path.is_file()
    assert (voices / ".migration-pending-v2.json").is_file()

    monkeypatch.setattr(storage, "_storage_test_hook", lambda *args, **kw: None)
    restarted = SettingsStore(
        settings_path, legacy, VoiceLibrary(voices))
    settings = restarted.initialize()
    manifest = json.loads(
        (voices / ".migration-backups-v2.json").read_text())

    assert settings.active_voice == "reader"
    assert settings.effects is True
    assert manifest["legacy_config"] == str(legacy.resolve())
    assert not (voices / ".migration-pending-v2.json").exists()


def _migrated_install(tmp_path):
    from serve import SettingsStore, VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "reader")
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "reader",
        "voices_dir": str(voices),
        "fx": True,
        "speed": 1.25,
    }))
    settings_path = tmp_path / "settings.json"
    library = VoiceLibrary(voices)
    store = SettingsStore(settings_path, legacy, library)
    store.initialize()
    return library, store, legacy, wav, transcript, settings_path


def _ready_migration_app(library, store, profile_id="reader"):
    from serve import App

    profile = library.resolve_ready(profile_id)
    speaker = Speaker(
        engine=SnapshotRecordingEngine(), voice_profile=profile,
        play_fn=lambda path: FakeHandle())
    assert speaker._worker.initialized.wait(5)
    assert speaker._worker.initialization_error is None
    app = App(library=library, settings_store=store)
    app.speaker = speaker
    return app


def test_ready_cleanup_removes_only_confirmed_migration_backups(tmp_path):
    from serve import App, _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, settings_path = (
        _migrated_install(tmp_path))
    manifest = library.manifest_path
    assert wav.is_file() and transcript.is_file() and legacy.is_file()
    assert manifest.is_file()

    app = App(library=library, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is True

    assert app.state_snapshot()["lifecycle"]["phase"] == "ready"
    assert not wav.exists()
    assert not transcript.exists()
    assert not legacy.exists()
    assert not manifest.exists()
    assert (library.root / "reader").is_dir()
    assert settings_path.is_file()


def test_ready_cleanup_preserves_changed_voice_pair_and_degrades(tmp_path):
    from serve import _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, _ = _migrated_install(tmp_path)
    transcript.write_text("changed after migration")
    app = _ready_migration_app(library, store)

    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is False

    state = app.state_snapshot()
    assert state["lifecycle"]["phase"] == "degraded"
    assert state["synthesis"]["ready"] is True
    assert state["last_error"]["code"] == "migration_backup_unconfirmed"
    assert wav.is_file() and transcript.is_file() and legacy.is_file()
    assert library.manifest_path.is_file()


def test_ready_cleanup_failure_is_resumable_without_redeleting_voice(
        tmp_path, monkeypatch):
    import storage
    from serve import App, VoiceLibrary, _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, _ = _migrated_install(tmp_path)

    def interrupt(event, **details):
        del details
        if event == "backup_cleanup_before_config_unlink":
            raise OSError("injected config cleanup failure")

    monkeypatch.setattr(storage, "_storage_test_hook", interrupt)
    app = App(library=library, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is False
    manifest = json.loads(library.manifest_path.read_text())
    assert manifest["legacy_voice_sources"] == []
    assert manifest["legacy_config"] == str(legacy.resolve())
    assert not wav.exists() and not transcript.exists()
    assert legacy.is_file()
    assert app.state_snapshot()["last_error"]["code"] == (
        "migration_backup_cleanup_failed")

    monkeypatch.setattr(storage, "_storage_test_hook", lambda *args, **kw: None)
    restarted = VoiceLibrary(library.root)
    restarted.initialize()
    retry_app = App(library=restarted, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        retry_app, restarted, legacy) is True
    assert not legacy.exists()
    assert not restarted.manifest_path.exists()


def test_ready_cleanup_rejects_unmatched_legacy_config_path(tmp_path):
    from serve import App, _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, _ = _migrated_install(tmp_path)
    app = App(library=library, settings_store=store)

    assert _reach_ready_and_cleanup_migrations(
        app, library, tmp_path / "other-config.json") is False

    assert not wav.exists() and not transcript.exists()
    assert legacy.is_file()
    manifest = json.loads(library.manifest_path.read_text())
    assert manifest["legacy_voice_sources"] == []
    assert manifest["legacy_config"] == str(legacy.resolve())


def test_startup_initial_voice_bootstraps_empty_settings_atomically(tmp_path):
    from serve import (
        SettingsStore, VoiceLibrary, _resolve_startup_voice)

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "alpha")
    store = SettingsStore(
        tmp_path / "settings.json", None, VoiceLibrary(voices))
    settings = store.initialize()

    selected, profile = _resolve_startup_voice(
        store.library, store, settings, "alpha")

    assert profile.id == "alpha"
    assert selected.active_voice == "alpha"
    assert store.snapshot().active_voice == "alpha"
    assert json.loads(store.path.read_text())["active_voice"] == "alpha"


def test_startup_existing_voice_wins_over_initial_hint(tmp_path):
    from serve import (
        SettingsStore, VoiceLibrary, _resolve_startup_voice)

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "alpha")
    _storage_profile(voices, "beta")
    settings_path = tmp_path / "settings.json"
    settings_path.write_text(json.dumps({
        "schema_version": 2,
        "active_voice": "alpha",
        "effects": False,
        "default_synthesis_rate": 1.0,
    }))
    store = SettingsStore(settings_path, None, VoiceLibrary(voices))
    settings = store.initialize()

    selected, profile = _resolve_startup_voice(
        store.library, store, settings, "beta")

    assert profile.id == "alpha"
    assert selected.active_voice == "alpha"
    assert json.loads(settings_path.read_text())["active_voice"] == "alpha"


def test_startup_initial_voice_failure_keeps_settings_unselected(
        tmp_path, monkeypatch):
    import storage
    from serve import (
        ManagementFailure, SettingsStore, VoiceLibrary,
        _resolve_startup_voice)

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "alpha")
    settings_path = tmp_path / "settings.json"
    store = SettingsStore(settings_path, None, VoiceLibrary(voices))
    settings = store.initialize()
    original = storage._atomic_write_json

    def fail_settings(path, value):
        if str(path) == str(settings_path):
            raise OSError("injected bootstrap persistence failure")
        return original(path, value)

    monkeypatch.setattr(storage, "_atomic_write_json", fail_settings)
    with pytest.raises(ManagementFailure) as error:
        _resolve_startup_voice(
            store.library, store, settings, "alpha")

    assert error.value.code == "settings_persist_failed"
    assert store.snapshot().active_voice is None
    assert not settings_path.exists()


@pytest.mark.parametrize("method", ("GET", "PATCH", "DELETE"))
@pytest.mark.parametrize("path", ("/voices/activate", "/voices/import"))
def test_management_voice_action_routes_are_post_only(
        tmp_path, method, path):
    server, port, _, _, _, _ = start_management_server(
        tmp_path, token="sekrit")
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}{path}", method=method,
            headers={"Authorization": "Bearer sekrit"})
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(req, timeout=5)
        response = error.value
        assert response.code == 405
        assert response.headers["Allow"] == "POST"
        assert json.loads(response.read())["error"]["code"] == (
            "method_not_allowed")
    finally:
        server.shutdown()


def test_management_preparation_failure_is_retained_and_transactional(
        tmp_path, monkeypatch):
    server, port, app, _, settings_store, engine = start_management_server(
        tmp_path)

    def fail_prepare(profile):
        raise RuntimeError(f"injected registration failure for {profile.id}")

    monkeypatch.setattr(engine, "prepare", fail_prepare)
    try:
        before = settings_store.snapshot()
        request(
            port, "/voices/activate", {"voice": "beta"},
            headers=management_headers("prepare-fails"))
        result = wait_operation(port, "prepare-fails")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == "voice_prepare_failed"
        assert result["error"]["recoverable"] is True
        assert settings_store.snapshot() == before
        assert app.state_snapshot()["synthesis"]["active_voice"] == "alpha"
        assert request(port, "/operations/prepare-fails")[1] == result
    finally:
        server.shutdown()


def test_management_failed_import_is_retained_and_leaves_no_residue(
        tmp_path):
    server, port, _, library, _, _ = start_management_server(tmp_path)
    stage = _management_stage(library.root, "bad-stage")
    (stage / "transcript.txt").write_text("")
    before = request(port, "/voices")[1]
    try:
        request(
            port, "/voices/import", {
                "staging_id": "bad-stage",
                "id": "gamma",
                "display_name": "Gamma",
            }, headers=management_headers("import-fails"))
        result = wait_operation(port, "import-fails")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == "voice_transcript_empty"
        assert request(port, "/operations/import-fails")[1] == result
        assert request(port, "/voices")[1] == before
        assert not stage.exists()
        assert not (library.root / "gamma").exists()
    finally:
        server.shutdown()


def test_management_settings_failure_is_retained_without_runtime_apply(
        tmp_path, monkeypatch):
    from serve import ManagementFailure

    server, port, app, _, settings_store, _ = start_management_server(
        tmp_path)
    before = settings_store.snapshot()

    def fail_update(**changes):
        raise ManagementFailure(
            "settings_persist_failed",
            "Product settings could not be saved.",
            detail=sorted(changes), status=500)

    monkeypatch.setattr(settings_store, "update", fail_update)
    try:
        status, error = management_error(
            port, "/settings", body={"effects": not before.effects},
            method="PATCH", headers=management_headers("settings-fails"))
        result = request(port, "/operations/settings-fails")[1]

        assert status == 500
        assert error["error"]["code"] == "settings_persist_failed"
        assert result["phase"] == "failed"
        assert result["error"] == error["error"]
        assert settings_store.snapshot() == before
        assert app.state_snapshot()["synthesis"]["effects"] == before.effects
    finally:
        server.shutdown()


def test_management_metadata_write_failure_preserves_profile(
        tmp_path, monkeypatch):
    import storage

    server, port, _, library, _, _ = start_management_server(tmp_path)
    before = library.resolve_ready("beta")
    original = storage._atomic_write_json

    def fail_beta_metadata(path, value):
        if Path(path) == library.root / "beta" / "profile.json":
            raise OSError("injected metadata write failure")
        return original(path, value)

    monkeypatch.setattr(storage, "_atomic_write_json", fail_beta_metadata)
    try:
        request(
            port, "/voices/beta", {"display_name": "Changed"},
            "PATCH", management_headers("rename-fails"))
        result = wait_operation(port, "rename-fails")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == "voice_metadata_write_failed"
        after = library.resolve_ready("beta")
        assert after.display_name == before.display_name
        assert request(port, "/operations/rename-fails")[1] == result
    finally:
        server.shutdown()


def test_management_delete_commit_failure_preserves_profile(
        tmp_path, monkeypatch):
    import storage

    server, port, _, library, _, _ = start_management_server(tmp_path)

    def fail_rename(source, destination):
        del source, destination
        raise OSError("injected delete rename failure")

    monkeypatch.setattr(storage, "_rename_noreplace", fail_rename)
    try:
        before = request(port, "/voices")[1]
        request(
            port, "/voices/beta", {}, "DELETE",
            management_headers("delete-fails"))
        result = wait_operation(port, "delete-fails")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == "voice_delete_commit_failed"
        assert request(port, "/voices")[1] == before
        assert library.resolve_ready("beta").id == "beta"
        assert request(port, "/operations/delete-fails")[1] == result
    finally:
        server.shutdown()


def test_snapshot_boundary_distinguishes_profiles_sharing_conditioning(
        tmp_path):
    engine = SnapshotRecordingEngine()

    def prepare_shared(profile):
        context = VoiceContext(profile, "shared", "shared-conditioning")
        engine.pins[profile.id] = engine.pins.get(profile.id, 0) + 1
        return context

    engine.prepare = prepare_shared
    alpha = snapshot_profile(tmp_path, "alpha")
    beta = snapshot_profile(tmp_path, "beta")
    played = []
    speaker = Speaker(
        engine=engine, voice_profile=alpha,
        play_fn=_recording_play(played))
    assert wait_for(speaker.ready.is_set)
    app = App(model_id="shared-conditioning")
    app.speaker = speaker
    speaker._gate = lambda: False

    speaker.speak(
        "alpha work.", snapshot=app.capture_synthesis_snapshot())
    activate_voice(
        beta, speaker._worker.prepare, lambda profile: None,
        app.commit_synthesis_context, speaker._worker.retain,
        speaker._worker.release)
    speaker.speak(
        "beta work.", append=True,
        snapshot=app.capture_synthesis_snapshot())

    assert app.is_profile_captured("alpha")
    assert app.is_profile_captured("beta")
    speaker._gate = None
    speaker._worker.wake()

    assert wait_for(lambda: played == ["alpha work.", "beta work."])
    assert engine.calls == [
        ("alpha", False, "alpha work."),
        ("beta", False, "beta work."),
    ]


def test_queued_activation_a_to_b_to_a_preserves_each_snapshot(tmp_path):
    app, speaker, engine, played = snapshot_app(tmp_path)
    alpha = speaker._worker.context.profile
    beta = snapshot_profile(tmp_path, "beta")
    speaker._gate = lambda: False

    speaker.speak(
        "alpha before.", snapshot=app.capture_synthesis_snapshot())
    activate_voice(
        beta, speaker._worker.prepare, lambda profile: None,
        app.commit_synthesis_context, speaker._worker.retain,
        speaker._worker.release)
    speaker.speak(
        "beta middle.", append=True,
        snapshot=app.capture_synthesis_snapshot())
    activate_voice(
        alpha, speaker._worker.prepare, lambda profile: None,
        app.commit_synthesis_context, speaker._worker.retain,
        speaker._worker.release)
    speaker.speak(
        "alpha after.", append=True,
        snapshot=app.capture_synthesis_snapshot())

    assert app.is_profile_captured("alpha")
    assert app.is_profile_captured("beta")
    speaker._gate = None
    speaker._worker.wake()

    assert wait_for(lambda: played == [
        "alpha before.", "beta middle.", "alpha after."])
    assert engine.calls == [
        ("alpha", False, "alpha before."),
        ("beta", False, "beta middle."),
        ("alpha", False, "alpha after."),
    ]


def test_management_voices_reports_invalid_issue_data_and_revision(tmp_path):
    server, port, _, library, _, _ = start_management_server(tmp_path)
    before = request(port, "/voices")[1]
    _storage_profile(library.root, "broken", transcript=False)
    try:
        voices = request(port, "/voices")[1]
        entry = next(
            voice for voice in voices["voices"] if voice["id"] == "broken")
        state = request(port, "/state")[1]

        assert voices["revision"] > before["revision"]
        assert entry["status"] == "incomplete"
        assert entry["issues"] == [{
            "code": "voice_transcript_missing",
            "field": "transcript",
            "message": "Broken needs a transcript file.",
        }]
        assert state["voices_revision"] == voices["revision"]
    finally:
        server.shutdown()


def test_reset_quarantine_recovers_invalid_legacy_config_to_ready(
        tmp_path):
    from serve import (
        ManagementFailure, SettingsStore, VoiceLibrary,
        _reach_ready_and_cleanup_migrations, _resolve_startup_voice)

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "c3po_god")
    legacy = tmp_path / "config.json"
    legacy.write_text('{"voice":')
    settings_path = tmp_path / "settings.json"
    library = VoiceLibrary(voices)
    failed = SettingsStore(settings_path, legacy, library)
    with pytest.raises(ManagementFailure) as error:
        failed.initialize()
    assert error.value.code == "legacy_config_invalid"

    backup = tmp_path / ".config.json.recovery-test"
    legacy.rename(backup)
    recovered = SettingsStore(settings_path, legacy, library)
    settings = recovered.initialize()
    settings, profile = _resolve_startup_voice(
        library, recovered, settings, "c3po_god")
    app = _ready_migration_app(library, recovered, "c3po_god")

    assert profile.id == "c3po_god"
    assert settings.active_voice == "c3po_god"
    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is True
    assert app.state_snapshot()["lifecycle"]["phase"] == "ready"
    assert app.state_snapshot()["synthesis"]["ready"] is True
    assert backup.read_text() == '{"voice":'
    assert not legacy.exists()


def test_reset_quarantine_recovers_migration_collision_without_voice_edits(
        tmp_path):
    from serve import (
        ManagementFailure, SettingsStore, VoiceLibrary,
        _reach_ready_and_cleanup_migrations, _resolve_startup_voice)

    voices = tmp_path / "voices"
    voices.mkdir()
    _storage_profile(voices, "c3po_god")
    wav, transcript = _storage_flat_pair(voices, "c3po_god")
    legacy = tmp_path / "config.json"
    legacy.write_text(json.dumps({
        "voice": "c3po_god",
        "voices_dir": str(voices),
        "fx": False,
        "speed": 1.0,
    }))
    settings_path = tmp_path / "settings.json"
    library = VoiceLibrary(voices)
    failed = SettingsStore(settings_path, legacy, library)
    with pytest.raises(ManagementFailure) as error:
        failed.initialize()
    assert error.value.code == "voice_migration_incomplete"
    assert error.value.detail == [{
        "id": "c3po_god",
        "issue": {
            "code": "legacy_voice_collision",
            "field": "id",
            "message": (
                "Legacy voice 'c3po_god' collides with an existing "
                "profile and was not migrated."),
        },
    }]

    backup = tmp_path / ".config.json.recovery-test"
    legacy.rename(backup)
    recovered = SettingsStore(settings_path, legacy, library)
    settings = recovered.initialize()
    settings, profile = _resolve_startup_voice(
        library, recovered, settings, "c3po_god")
    app = _ready_migration_app(library, recovered, "c3po_god")
    entry = _voice_entry(library.snapshot(), "c3po_god")

    assert profile.id == "c3po_god"
    assert settings.active_voice == "c3po_god"
    assert any(issue.code == "legacy_voice_collision"
               for issue in entry.issues)
    assert wav.is_file() and transcript.is_file()
    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is True
    assert app.state_snapshot()["lifecycle"]["phase"] == "ready"
    assert wav.is_file() and transcript.is_file()
    assert backup.is_file() and not legacy.exists()


def test_ready_cleanup_voice_unlink_failure_preserves_pair(
        tmp_path, monkeypatch):
    import storage
    from serve import App, _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, _ = _migrated_install(tmp_path)

    def interrupt(event, **details):
        del details
        if event == "backup_cleanup_before_voice_unlink":
            raise OSError("injected voice cleanup failure")

    monkeypatch.setattr(storage, "_storage_test_hook", interrupt)
    app = App(library=library, settings_store=store)

    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is False
    assert app.state_snapshot()["last_error"]["code"] == (
        "migration_backup_cleanup_failed")
    assert wav.is_file() and transcript.is_file() and legacy.is_file()
    manifest = json.loads(library.manifest_path.read_text())
    assert len(manifest["legacy_voice_sources"]) == 1


def test_ready_cleanup_manifest_unlink_failure_resumes_from_empty_manifest(
        tmp_path, monkeypatch):
    import storage
    from serve import App, VoiceLibrary, _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, _ = _migrated_install(tmp_path)

    def interrupt(event, **details):
        del details
        if event == "backup_cleanup_before_manifest":
            raise OSError("injected manifest cleanup failure")

    monkeypatch.setattr(storage, "_storage_test_hook", interrupt)
    app = App(library=library, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is False
    assert not wav.exists() and not transcript.exists() and not legacy.exists()
    assert json.loads(library.manifest_path.read_text()) == {
        "schema_version": 2,
        "legacy_voice_sources": [],
        "legacy_config": None,
    }

    monkeypatch.setattr(storage, "_storage_test_hook", lambda *args, **kw: None)
    restarted = VoiceLibrary(library.root)
    restarted.initialize()
    retry_app = App(library=restarted, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        retry_app, restarted, legacy) is True
    assert not restarted.manifest_path.exists()


def test_ready_cleanup_manifest_write_failure_is_retained_and_resumable(
        tmp_path, monkeypatch):
    import storage
    from serve import App, VoiceLibrary, _reach_ready_and_cleanup_migrations

    library, store, legacy, wav, transcript, _ = _migrated_install(tmp_path)
    original = storage._atomic_write_json

    def fail_manifest(path, value):
        if Path(path) == library.manifest_path:
            raise OSError("injected manifest write failure")
        return original(path, value)

    monkeypatch.setattr(storage, "_atomic_write_json", fail_manifest)
    app = App(library=library, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        app, library, legacy) is False
    assert app.state_snapshot()["last_error"]["code"] == (
        "migration_backup_cleanup_failed")
    assert not wav.exists() and not transcript.exists()
    assert legacy.is_file() and library.manifest_path.is_file()

    monkeypatch.setattr(storage, "_atomic_write_json", original)
    restarted = VoiceLibrary(library.root)
    restarted.initialize()
    retry_app = App(library=restarted, settings_store=store)
    assert _reach_ready_and_cleanup_migrations(
        retry_app, restarted, legacy) is True
    assert not legacy.exists()
    assert not restarted.manifest_path.exists()


def test_management_post_ready_engine_failure_preserves_durable_voice(
        tmp_path):
    server, port, app, _, settings_store, engine = start_management_server(
        tmp_path)
    instance_id = app.instance_id
    engine.failure = {
        "code": "engine_child_exited",
        "message": "qwentts tts-server exited unexpectedly",
        "exit_code": 23,
    }
    try:
        state = request(port, "/state")[1]
        meta = request(port, "/meta")[1]

        assert meta["instance_id"] == instance_id
        assert state["lifecycle"]["phase"] == "degraded"
        assert state["synthesis"]["ready"] is False
        assert state["synthesis"]["active_voice"] is None
        assert state["last_error"]["code"] == "engine_child_exited"
        assert settings_store.snapshot().active_voice == "alpha"
        status, error = management_error(
            port, "/speak", body={"text": "not accepted"}, method="POST")
        assert status == 503
        assert error["error"]["code"] == "engine_child_exited"
    finally:
        server.shutdown()


def test_explicit_reference_launch_never_retires_source_pair(tmp_path):
    from serve import App, VoiceLibrary, _reach_ready_and_cleanup_migrations

    voices = tmp_path / "samples"
    voices.mkdir()
    wav, transcript = _storage_flat_pair(voices, "dev_voice")
    library = VoiceLibrary(voices)
    library.initialize()
    app = App(library=library)

    assert _reach_ready_and_cleanup_migrations(
        app, library, None, cleanup_backups=False) is True
    assert app.state_snapshot()["lifecycle"]["phase"] == "ready"
    assert wav.is_file() and transcript.is_file()
    assert library.manifest_path.is_file()
    assert library.resolve_ready("dev_voice").id == "dev_voice"


def test_explicit_reference_settings_are_ephemeral_and_product_isolated(
        tmp_path):
    from serve import (
        SettingsStore, VoiceLibrary, _settings_storage_for_launch)

    product = tmp_path / "product"
    product.mkdir()
    legacy = product / "config.json"
    product_settings = product / "settings.json"
    original = {
        "schema_version": 2,
        "active_voice": "installed_voice",
        "effects": True,
        "default_synthesis_rate": 1.25,
    }
    product_settings.write_text(json.dumps(original))
    samples = tmp_path / "samples"
    samples.mkdir()
    _storage_profile(samples, "dev_voice")

    settings_path, legacy_source, scope = _settings_storage_for_launch(
        samples / "dev_voice.wav", legacy)
    try:
        assert legacy_source is None
        assert settings_path.parent != product
        store = SettingsStore(
            settings_path, legacy_source, VoiceLibrary(samples))
        store.initialize()
        store.set_active_voice("dev_voice")

        assert store.snapshot().active_voice == "dev_voice"
        assert settings_path.is_file()
        assert json.loads(product_settings.read_text()) == original
    finally:
        scope.cleanup()

    managed_path, managed_legacy, managed_scope = (
        _settings_storage_for_launch(None, legacy))
    assert managed_path == product_settings
    assert managed_legacy == legacy
    assert managed_scope is None


def test_explicit_reference_rejects_same_id_profile_collision(tmp_path):
    from serve import (
        ManagementFailure, SettingsStore, VoiceLibrary,
        _resolve_explicit_startup_voice)

    voices = tmp_path / "samples"
    voices.mkdir()
    _storage_profile(voices, "dev_voice")
    _storage_flat_pair(voices, "dev_voice")
    library = VoiceLibrary(voices)
    library.initialize()
    store = SettingsStore(tmp_path / "settings.json", None, library)
    store.initialize()

    with pytest.raises(ManagementFailure) as error:
        _resolve_explicit_startup_voice(
            library, store, "dev_voice")

    assert error.value.code == "legacy_voice_collision"
    assert store.snapshot().active_voice is None


@pytest.mark.parametrize(
    "file_name,limit_name,code,field",
    (
        ("profile.json", "MAX_PROFILE_METADATA_BYTES",
         "voice_metadata_too_large", "profile"),
        ("transcript.txt", "MAX_TRANSCRIPT_BYTES",
         "voice_transcript_too_large", "transcript"),
        ("reference.wav", "MAX_REFERENCE_WAV_BYTES",
         "voice_audio_too_large", "audio"),
    ),
)
def test_storage_scan_reports_bounded_profile_file_issues(
        tmp_path, file_name, limit_name, code, field):
    import storage
    from serve import VoiceLibrary

    voices = tmp_path / "voices"
    voices.mkdir()
    profile = _storage_profile(voices, "oversized")
    with (profile / file_name).open("r+b") as oversized:
        oversized.truncate(getattr(storage, limit_name) + 1)

    entry = _voice_entry(VoiceLibrary(voices).initialize(), "oversized")

    assert entry.status == "invalid"
    assert any(
        issue.code == code and issue.field == field
        for issue in entry.issues)


@pytest.mark.parametrize(
    "file_name,limit_name,code",
    (
        ("transcript.txt", "MAX_TRANSCRIPT_BYTES",
         "voice_transcript_too_large"),
        ("reference.wav", "MAX_REFERENCE_WAV_BYTES",
         "voice_audio_too_large"),
    ),
)
def test_management_staged_import_rejects_oversize_without_residue(
        tmp_path, file_name, limit_name, code):
    import storage

    server, port, _, library, _, _ = start_management_server(tmp_path)
    stage = _management_stage(library.root, "oversized-stage")
    with (stage / file_name).open("r+b") as oversized:
        oversized.truncate(getattr(storage, limit_name) + 1)
    try:
        request(
            port, "/voices/import", {
                "staging_id": "oversized-stage",
                "id": "oversized",
                "display_name": "Oversized",
            }, headers=management_headers("oversized-import"))
        result = wait_operation(port, "oversized-import")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == code
        assert not stage.exists()
        assert not (library.root / "oversized").exists()
    finally:
        server.shutdown()


def test_management_activation_rejects_oversize_before_audio_allocation(
        tmp_path):
    import storage

    server, port, app, library, settings_store, _ = start_management_server(
        tmp_path)
    oversized = library.root / "beta" / "reference.wav"
    with oversized.open("r+b") as audio:
        audio.truncate(storage.MAX_REFERENCE_WAV_BYTES + 1)
    try:
        request(
            port, "/voices/activate", {"voice": "beta"},
            headers=management_headers("oversized-activation"))
        result = wait_operation(port, "oversized-activation")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == "voice_audio_too_large"
        assert settings_store.snapshot().active_voice == "alpha"
        assert app.state_snapshot()["synthesis"]["active_voice"] == "alpha"
    finally:
        server.shutdown()


def test_activation_profile_swap_never_reopens_symlinked_audio(
        tmp_path, monkeypatch):
    import storage

    server, port, app, library, settings_store, _ = start_management_server(
        tmp_path)
    external = tmp_path / "external.wav"
    external.write_bytes(_make_wav_bytes())
    original = library.root / "beta" / "reference.wav"
    backup = library.root / "beta" / "reference-original.wav"
    swapped = [False]

    def swap(event, **details):
        if (event == "resolve_before_capture"
                and details.get("profile_id") == "beta"
                and not swapped[0]):
            swapped[0] = True
            original.rename(backup)
            original.symlink_to(external)

    monkeypatch.setattr(storage, "_storage_test_hook", swap)
    try:
        request(
            port, "/voices/activate", {"voice": "beta"},
            headers=management_headers("swap-activation"))
        result = wait_operation(port, "swap-activation")

        assert result["phase"] == "failed"
        assert result["error"]["code"] == "voice_profile_changed"
        assert settings_store.snapshot().active_voice == "alpha"
        assert app.state_snapshot()["synthesis"]["active_voice"] == "alpha"
        assert external.read_bytes() == _make_wav_bytes()
    finally:
        server.shutdown()