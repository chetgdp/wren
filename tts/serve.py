"""Voice-clone TTS daemon: POST text, hear it in the cloned voice.

Loads Qwen3-TTS once and serves speak requests on 127.0.0.1 only. Markdown
is stripped server-side so clients (e.g. the pi `voice` extension) can send
raw agent output. Text is chunked into sentence groups so playback starts
after the first chunk instead of after the whole message. A new /speak or
/stop preempts anything still queued or playing.

Endpoints:
    POST /speak  {"text": "...", "raw": false, "append": false} -> {"queued": n}
                 {"blocks": ["...", ...], ...}: indexed blocks; /health then
                 reports which block range is currently audible (read mode)
    POST /stop                                                  -> {"ok": true}
    POST /pause                                 -> {"ok": true, "paused": true}
    POST /resume                               -> {"ok": true, "paused": false}
    POST /seek   {"delta": 1} | {"block": n} -> {"ok": true, "block": n};
                 skips relative to what is playing, or to an absolute block
                 index (needs a prior blocks speak)
    GET  /health -> {"ok": true, "pending": n, "speaking": b, "paused": b,
                     "block": [lo, hi] | null, "playback": "local"|"client"}
    GET  /segment?after=n[&timeout=s]  (--playback client only) long-poll for
                 the next synthesized segment: audio/wav with X-Seq, X-Epoch,
                 X-Block headers; 204 + X-Epoch on timeout. An epoch change
                 means playback was preempted: drop locally queued audio.

With --token (or $VOICE_ML_TOKEN), every request must carry
"Authorization: Bearer <token>"; use it whenever --host exposes the daemon
beyond loopback.

"append" queues after what is already speaking instead of preempting it;
streaming clients send the first piece without it and the rest with it.

Example:
    uv run tts/serve.py -r samples/bossnass/ref.wav
    curl -X POST localhost:8765/speak -d '{"text": "hello there"}'
"""

import argparse
import hmac
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

# Local 4-bit MLX conversion: only 4-bit runs above realtime here (RTF ~2.4
# streaming vs ~0.55 for bf16/PyTorch at any size), and 1.7B matches 0.6B
# 4-bit for speed while sounding better. Regenerate with:
#   uv run python -m mlx_audio.convert --hf-path Qwen/Qwen3-TTS-12Hz-1.7B-Base \
#       --mlx-path models/Qwen3-TTS-12Hz-1.7B-Base-4bit -q --q-bits 4 --model-domain tts
DEFAULT_MODEL = "models/Qwen3-TTS-12Hz-1.7B-Base-4bit"
HOST = "127.0.0.1"
DEFAULT_PORT = 8765
# With streaming synthesis, playback starts ~1s into each generate call, so
# larger chunks amortize the per-call fixed cost (ref-audio encode + prompt
# prefill, several seconds). Kept moderate rather than maximal: this also
# caps synth-batch coalescing, and a batch is the granularity of the
# /health block position (read-mode highlight) and of /seek responsiveness.
MAX_CHUNK_CHARS = 300
FIRST_CHUNK_CHARS = 200


def sanitize_markdown(text):
    """Strip markdown down to speakable prose. Code blocks are dropped entirely."""
    text = re.sub(r"```.*?(```|\Z)", " ", text, flags=re.S)
    text = re.sub(r"~~~.*?(~~~|\Z)", " ", text, flags=re.S)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)  # images
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)  # links -> their text
    text = re.sub(r"`([^`]*)`", r"\1", text)  # inline code -> bare text
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.M)  # headers
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.M)  # bullets
    text = re.sub(r"^\s*\d+\.\s+", "", text, flags=re.M)  # numbered lists
    text = re.sub(r"^\s*>\s?", "", text, flags=re.M)  # blockquotes
    text = re.sub(r"^[|+\-=:\s]+$", "", text, flags=re.M)  # hr / table separator rows
    text = re.sub(r"\*{1,3}|_{2,3}", "", text)  # bold/italic markers
    # emoji and dingbat/symbol/arrow blocks the model would try to vocalize
    text = re.sub(
        "[\U0001F000-\U0001FBFF☀-➿←-⇿⬀-⯿️]",
        "", text)
    text = text.replace("|", ", ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\s*\n\s*", "\n", text)
    return text.strip()


_SENTENCE_BREAK = re.compile(r"(?<=[.!?;:])\s+")


def estimate_frames(text):
    """English speech runs ~12-14 chars/sec and the codec emits 12 frames/sec,
    so frames ~= chars * 0.9. Same heuristic as progress_bar.estimate_frames,
    duplicated here because that module imports torch (absent in the mlx env)."""
    return round(len(text.strip()) * 0.9)


CHARS_PER_SEC = 12 / 0.9  # inverse of the estimate_frames heuristic


def block_span(layout, sec0, sec1):
    """Sentence-index range estimated audible between sec0..sec1 of a synth
    batch's audio. layout is [(block_idx, char_count), ...] in speech order;
    position is interpolated by character share at ~13 chars/sec."""
    c0 = sec0 * CHARS_PER_SEC
    c1 = sec1 * CHARS_PER_SEC
    sel = []
    pos = 0.0
    for idx, chars in layout:
        start, end = pos, pos + chars
        pos = end + 1  # joining space
        if end <= c0:
            continue
        if start >= c1:
            break
        sel.append(idx)
    if not sel:  # audio ran past the estimate (slow speech); stay on the tail
        sel = [layout[-1][0]]
    return (sel[0], sel[-1])


def _cut(sentence, limit):
    cut = sentence.rfind(" ", 0, limit)
    if cut <= 0:
        cut = limit
    return sentence[:cut].strip(), sentence[cut:].strip()


def chunk_text(text, max_chars=MAX_CHUNK_CHARS, first_chars=FIRST_CHUNK_CHARS):
    """Greedily group sentences into chunks, per line.

    The size limit ramps up (first_chars, doubling to max_chars) so the
    first chunk synthesizes fast and playback starts early.
    """
    chunks = []
    buf = ""
    limit = min(first_chars, max_chars)

    def emit():
        nonlocal buf, limit
        chunks.append(buf)
        buf = ""
        limit = min(limit * 2, max_chars)

    for line in filter(None, (ln.strip() for ln in text.split("\n"))):
        for sentence in _SENTENCE_BREAK.split(line):
            while sentence:
                room = limit - (len(buf) + 1 if buf else 0)
                if len(sentence) <= room:
                    buf = f"{buf} {sentence}" if buf else sentence
                    sentence = ""
                elif buf:
                    emit()
                else:
                    buf, sentence = _cut(sentence, limit)
                    emit()
        if buf:
            emit()
    return chunks


def _afplay(path):
    return subprocess.Popen(
        ["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


class _PCMHandle:
    """Matches the Popen-ish handle API Speaker expects (wait/terminate)."""

    def __init__(self, player, path):
        self._player = player
        self._path = path
        self.cancelled = threading.Event()

    def terminate(self):
        self.cancelled.set()

    def wait(self):
        self._player._write(self._path, self.cancelled)


class PCMPlayer:
    """Gapless playback through one persistent output stream.

    Streamed synthesis yields ~1s segments; playing each through its own
    afplay process inserts an audible startup gap between every segment
    (sounds choppy). Instead, decode each wav and feed its samples into a
    single sounddevice OutputStream in small blocks, checking a cancel flag
    between blocks so preemption still lands within ~0.25s.
    """

    BLOCK_SECONDS = 0.25

    def __init__(self):
        self._stream = None
        self._sr = None
        self._paused = threading.Event()

    def pause(self):
        self._paused.set()

    def resume(self):
        self._paused.clear()

    @property
    def paused(self):
        return self._paused.is_set()

    def __call__(self, path):  # play_fn API
        return _PCMHandle(self, path)

    def _ensure(self, sr, channels):
        import sounddevice as sd
        if self._stream is None or self._sr != sr:
            if self._stream is not None:
                self._stream.stop()
                self._stream.close()
            # Low latency keeps write() roughly in step with what is audible;
            # a deep buffer would let the play loop (and the reported block
            # position that drives highlight/seek) run ahead of the speakers.
            self._stream = sd.OutputStream(samplerate=sr, channels=channels,
                                           dtype="float32", latency="low")
            self._stream.start()
            self._sr = sr

    def _write(self, path, cancelled):
        import soundfile as sf
        data, sr = sf.read(path, dtype="float32", always_2d=True)
        self._ensure(sr, data.shape[1])
        block = max(1, int(sr * self.BLOCK_SECONDS))
        for start in range(0, len(data), block):
            while self._paused.is_set() and not cancelled.is_set():
                time.sleep(0.05)
            if cancelled.is_set():
                break
            self._stream.write(data[start:start + block])


def default_player():
    try:
        import sounddevice  # noqa: F401
        return PCMPlayer()
    except Exception:
        print("sounddevice unavailable; falling back to afplay (may sound "
              "choppy with streamed segments)", file=sys.stderr)
        return _afplay


def _wav_seconds(path):
    try:
        import soundfile as sf
        info = sf.info(path)
        return info.frames / info.samplerate
    except Exception:
        return 0.0


class SegmentStore:
    """Client-playback sink: buffers synthesized segments in memory for
    GET /segment long-polls instead of playing them on this machine.

    Implements the Speaker sink API (submit/invalidate) in place of a
    play_fn. seq is monotonic across the store's life so a client can always
    resume with the last seq it saw; invalidate() (preemption/stop) drops
    buffered segments and bumps epoch so a client knows to also drop
    whatever it has scheduled locally.
    """

    MAX_BYTES = 64 * 1024 * 1024  # a stalled client can't grow us past this

    def __init__(self, max_bytes=MAX_BYTES):
        self._max_bytes = max_bytes
        self._cond = threading.Condition()
        self._segments = []  # [(seq, block, wav bytes)]
        self._bytes = 0
        self._seq = 0
        self.epoch = 0

    def submit(self, path, block):
        with open(path, "rb") as f:
            data = f.read()
        with self._cond:
            self._seq += 1
            self._segments.append((self._seq, block, data))
            self._bytes += len(data)
            while self._bytes > self._max_bytes and len(self._segments) > 1:
                seq, _, dropped = self._segments.pop(0)
                self._bytes -= len(dropped)
                print(f"segment buffer full; dropped seq {seq} "
                      f"({len(dropped)} bytes) unfetched", file=sys.stderr)
            self._cond.notify_all()

    def invalidate(self):
        with self._cond:
            self.epoch += 1
            self._segments.clear()
            self._bytes = 0
            self._cond.notify_all()

    def next_after(self, seq, timeout=20.0):
        """First buffered segment with seq > the given one, waiting up to
        timeout. Returns (seq, block, data, epoch); data is None on timeout."""
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                for s, block, data in self._segments:
                    if s > seq:
                        return s, block, data, self.epoch
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None, None, None, self.epoch
                self._cond.wait(remaining)


class Speaker:
    """Synth + playback pipeline. speak() preempts whatever is queued or playing.

    synth_fn(text, make_path) is a generator yielding wav paths as audio
    segments complete (streaming backends yield several per text; make_path()
    returns a fresh output path). play_fn(path) returns a handle with wait()
    and terminate() (default: afplay Popen). Each speak() bumps an epoch;
    stale-epoch work is dropped at every stage, including mid-generation.

    Pass synth_factory instead of synth_fn to load the model inside the synth
    worker thread (MLX streams are thread-local, so the model must be loaded
    and used by the same thread). `ready` is set once synthesis can proceed;
    a failed load prints the error and exits the process.
    """

    def __init__(self, synth_fn=None, play_fn=None, max_chars=MAX_CHUNK_CHARS,
                 first_chars=FIRST_CHUNK_CHARS, synth_factory=None):
        if (synth_fn is None) == (synth_factory is None):
            raise ValueError("pass exactly one of synth_fn or synth_factory")
        self._synth = synth_fn
        self._synth_factory = synth_factory
        self.ready = threading.Event()
        if synth_fn is not None:
            self.ready.set()
        self._play = play_fn or default_player()
        self._max_chars = max_chars
        self._first_chars = first_chars
        self._lock = threading.Lock()
        self._epoch = 0
        self._synth_q = queue.Queue()
        self._play_q = queue.Queue()
        self._current = None
        self._current_block = None
        self._blocks = None  # last blocks-speak, kept for /seek
        self._last_played = None  # block index most recently started
        self._counter = 0
        self._last_synth_epoch = -1
        self._tmpdir = tempfile.mkdtemp(prefix="voice-serve-")
        threading.Thread(target=self._synth_loop, daemon=True).start()
        threading.Thread(target=self._play_loop, daemon=True).start()

    def speak(self, text=None, append=False, blocks=None):
        """blocks: list of (index, text) pairs; the index of whatever is
        currently audible is exposed via current_block() so clients can
        highlight it. Plain text is a single index-less block."""
        if blocks is None:
            blocks = [(None, text)]
        items = self._chunks_for(blocks)
        with self._lock:
            if not append:
                self._preempt_locked()
                indexed = [(i, t) for i, t in blocks if i is not None]
                self._blocks = indexed or None
            epoch = self._epoch
            for idx, chunk in items:
                self._synth_q.put((epoch, idx, chunk))
        return len(items)

    def _chunks_for(self, blocks):
        items = []
        for idx, block in blocks:
            first = self._first_chars if not items else self._max_chars
            for chunk in chunk_text(block, self._max_chars, first):
                items.append((idx, chunk))
        return items

    def _preempt_locked(self):
        self._epoch += 1
        self._drain()
        self._terminate_current()
        if hasattr(self._play, "invalidate"):  # client-playback sink
            self._play.invalidate()
        self.resume()  # a paused player would sit on the new audio
        self._last_played = None
        # Stop reporting the preempted segment's position now; waiting for
        # the cancelled handle to unwind leaves /health pointing at audio
        # that is no longer meant to play.
        self._current_block = None

    def seek(self, delta=None, target=None):
        """Jump within the last blocks-speak by preempting and requeueing
        from the target: |delta| blocks relative to playback, or an absolute
        block index via target. Returns the (clamped) landing index, or None
        when there is nothing seekable (plain-text speech).

        Relative position is only known at segment granularity, which may
        span blocks. Forward deltas are relative to the segment END (skip
        everything in it), backward to its start; otherwise a small forward
        skip lands inside already-heard audio."""
        with self._lock:
            blocks = self._blocks
            if not blocks:
                return None
            lo, hi = blocks[0][0], blocks[-1][0]
            if target is None:
                playing = self._current_block
                if playing is not None:
                    cur = playing[1] if delta > 0 else playing[0]
                elif self._last_played is not None:
                    cur = self._last_played
                else:
                    cur = lo
                target = cur + delta
            target = min(max(lo, target), hi)
            self._preempt_locked()
            epoch = self._epoch
            for idx, chunk in self._chunks_for(
                    [(i, t) for i, t in blocks if i >= target]):
                self._synth_q.put((epoch, idx, chunk))
            # Until the new audio starts, this target is the position a
            # follow-up relative seek must be based on; leaving it None
            # would send the next j/k back to the start of the document.
            self._last_played = target
        return target

    def stop(self):
        with self._lock:
            self._epoch += 1
            self._drain()
            self._terminate_current()
            if hasattr(self._play, "invalidate"):
                self._play.invalidate()
            self.resume()

    def pause(self):
        """Pause playback between blocks. Only the PCM player supports it;
        with the afplay fallback this is a no-op and returns False."""
        if hasattr(self._play, "pause"):
            self._play.pause()
            return True
        return False

    def resume(self):
        if hasattr(self._play, "resume"):
            self._play.resume()
            return True
        return False

    def paused(self):
        return bool(getattr(self._play, "paused", False))

    def speaking(self):
        return self._current is not None

    def current_block(self):
        """(lo, hi) block-index range of the audio now playing, or None."""
        return self._current_block

    def pending(self):
        return self._synth_q.qsize() + self._play_q.qsize()

    def _drain(self):
        for q in (self._synth_q, self._play_q):
            while True:
                try:
                    q.get_nowait()
                except queue.Empty:
                    break

    def _terminate_current(self):
        current = self._current
        if current is not None:
            try:
                current.terminate()
            except Exception:
                pass

    def _synth_loop(self):
        if self._synth_factory is not None:
            try:
                self._synth = self._synth_factory()
            except Exception:
                import traceback
                traceback.print_exc()
                print("model load failed; exiting", file=sys.stderr)
                os._exit(1)
            self.ready.set()
        carry = None
        while True:
            if carry is not None:
                epoch, idx, text = carry
                carry = None
            else:
                epoch, idx, text = self._synth_q.get()
            if epoch != self._epoch:
                continue
            parts = [text]
            idxs = [] if idx is None else [idx]
            # Coalesce backlog that queued up behind a previous synthesis:
            # every generate call pays a prefill proportional to the
            # reference length, so batching backlog into one call pays it
            # once instead of per sentence. The first chunk of an epoch is
            # never coalesced; it is sized small for fast first audio.
            if epoch == self._last_synth_epoch:
                total = len(text)
                while total < self._max_chars:
                    try:
                        item = self._synth_q.get_nowait()
                    except queue.Empty:
                        break
                    next_epoch, next_idx, next_text = item
                    if next_epoch < epoch:
                        continue  # stale, drop
                    if next_epoch > epoch:
                        # A preemption queued this mid-coalesce; it belongs
                        # to the new epoch, not this dying batch.
                        carry = item
                        break
                    parts.append(next_text)
                    if next_idx is not None:
                        idxs.append(next_idx)
                    total += len(next_text) + 1
                text = " ".join(parts)
            if epoch != self._epoch:  # preempted during coalesce
                continue
            self._last_synth_epoch = epoch
            # A coalesced batch spans several blocks. Each streamed segment
            # is tagged with the sentence range it is estimated to cover, so
            # the reported position tracks the audible sentence, not the
            # whole batch. Falls back to the full range when the parts/index
            # pairing is broken (mixed indexed and plain-text chunks).
            block = (idxs[0], idxs[-1]) if idxs else None
            layout = (list(zip(idxs, (len(p) for p in parts)))
                      if idxs and len(idxs) == len(parts) else None)
            print(f'synthesizing ({len(text)} chars, {self.pending()} queued): "{text}"',
                  flush=True)
            t0 = time.monotonic()
            audio_s = 0.0
            try:
                for path in self._synth(text, self._make_path):
                    if epoch != self._epoch:  # preempted: abandon generation
                        break
                    seg_start = audio_s
                    audio_s += _wav_seconds(path)
                    # Unknown/zero segment duration: report the whole batch.
                    seg_block = (block_span(layout, seg_start, audio_s)
                                 if layout and audio_s > seg_start else block)
                    self._play_q.put((epoch, path, seg_block))
            except Exception as exc:
                print(f"synth failed: {exc}", file=sys.stderr)
                continue
            wall = time.monotonic() - t0
            print(f"  {audio_s:.1f}s audio in {wall:.1f}s (RTF {audio_s / wall:.2f})",
                  flush=True)

    def _make_path(self):
        self._counter += 1
        return os.path.join(self._tmpdir, f"{self._counter}.wav")

    def _play_loop(self):
        while True:
            epoch, path, block = self._play_q.get()
            if epoch != self._epoch:
                continue
            if hasattr(self._play, "submit"):  # client-playback sink
                try:
                    self._play.submit(path, block)
                except Exception as exc:
                    print(f"segment submit failed: {exc}", file=sys.stderr)
                finally:
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
                continue
            try:
                self._current_block = block
                if block is not None:
                    self._last_played = block[0]
                handle = self._play(path)
                self._current = handle
                if epoch != self._epoch:  # preempted between check and start
                    handle.terminate()
                handle.wait()
            except Exception as exc:
                print(f"playback failed: {exc}", file=sys.stderr)
            finally:
                self._current = None
                self._current_block = None
                try:
                    os.unlink(path)
                except OSError:
                    pass


class App:
    """Shared server state. speaker is attached once the model finishes
    loading, so the server can come up (and report status) immediately."""

    def __init__(self, model_id="", token=None, segments=None):
        self.model_id = model_id
        self.token = token
        self.segments = segments  # SegmentStore when --playback client
        self.speaker = None


class _Handler(BaseHTTPRequestHandler):
    app = None  # injected via make_server

    def log_message(self, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        token = self.app.token
        if not token:
            return True
        supplied = self.headers.get("Authorization", "")
        if hmac.compare_digest(supplied, f"Bearer {token}"):
            return True
        self._json(401, {"error": "unauthorized"})
        return False

    def _segment(self, query):
        store = self.app.segments
        if store is None:
            self._json(404, {"error": "server-side playback; start the "
                                      "daemon with --playback client"})
            return
        try:
            after = int(query.get("after", ["0"])[0])
            timeout = min(float(query.get("timeout", ["20"])[0]), 60.0)
        except ValueError:
            self._json(400, {"error": "after/timeout must be numeric"})
            return
        seq, block, data, epoch = store.next_after(after, timeout)
        if data is None:  # long-poll timed out; epoch still lets the
            self.send_response(204)  # client notice a preemption while idle
            self.send_header("X-Epoch", str(epoch))
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

    def do_GET(self):
        if not self._authorized():
            return
        url = urlsplit(self.path)
        if url.path == "/health":
            speaker = self.app.speaker
            ready = speaker is not None and speaker.ready.is_set()
            self._json(200, {
                "ok": True,
                "ready": ready,
                "model": self.app.model_id,
                "playback": "client" if self.app.segments else "local",
                "pending": speaker.pending() if ready else 0,
                "speaking": speaker.speaking() if ready else False,
                "paused": speaker.paused() if ready else False,
                "block": list(speaker.current_block())
                         if ready and speaker.current_block() else None,
            })
        elif url.path == "/segment":
            self._segment(parse_qs(url.query))
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            return
        speaker = self.app.speaker
        if speaker is None or not speaker.ready.is_set():
            self._json(503, {"error": "model still loading"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "invalid JSON"})
            return
        if self.path == "/stop":
            speaker.stop()
            self._json(200, {"ok": True})
            return
        if self.path == "/seek":
            if "block" in body:
                block = body["block"]
                if not isinstance(block, int) or isinstance(block, bool):
                    self._json(400, {"error": "block must be an integer"})
                    return
                target = speaker.seek(target=block)
            else:
                delta = body.get("delta", 1)
                if (not isinstance(delta, int) or isinstance(delta, bool)
                        or delta == 0):
                    self._json(400, {"error": "delta must be a non-zero integer"})
                    return
                target = speaker.seek(delta)
            if target is None:
                self._json(200, {"ok": False, "error": "nothing to seek"})
            else:
                self._json(200, {"ok": True, "block": target})
            return
        if self.path == "/pause":
            ok = speaker.pause()
            self._json(200 if ok else 501,
                       {"ok": ok, "paused": speaker.paused()})
            return
        if self.path == "/resume":
            ok = speaker.resume()
            self._json(200 if ok else 501,
                       {"ok": ok, "paused": speaker.paused()})
            return
        if self.path != "/speak":
            self._json(404, {"error": "not found"})
            return
        append = bool(body.get("append"))
        blocks = body.get("blocks")
        if blocks is not None:
            if not isinstance(blocks, list) or not all(
                    isinstance(b, str) for b in blocks):
                self._json(400, {"error": "blocks must be a list of strings"})
                return
            if not body.get("raw"):
                blocks = [sanitize_markdown(b) for b in blocks]
            # Indices survive sanitize dropping blocks, so they keep lining
            # up with the client's element list.
            indexed = [(i, b) for i, b in enumerate(blocks) if b.strip()]
            if not indexed:
                self._json(200, {"queued": 0})
                return
            self._json(200, {"queued": speaker.speak(blocks=indexed, append=append)})
            return
        text = body.get("text")
        if not isinstance(text, str) or not text.strip():
            self._json(400, {"error": "missing text"})
            return
        if not body.get("raw"):
            text = sanitize_markdown(text)
        if not text:
            self._json(200, {"queued": 0})
            return
        queued = speaker.speak(text, append=append)
        self._json(200, {"queued": queued})


def make_server(app, port=DEFAULT_PORT, host=HOST):
    handler = type("Handler", (_Handler,), {"app": app})
    return ThreadingHTTPServer((host, port), handler)


def resolve_device(device="auto"):
    import torch
    if device != "auto":
        return device
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_qwen_tts_synth(model_id, ref_audio, ref_text, language, device="auto"):
    """PyTorch backend (Qwen/Qwen3-TTS-*): cuda > mps > cpu."""
    import torch
    import soundfile as sf
    from qwen_tts import Qwen3TTSModel

    from progress_bar import attach_progress_bar

    device = resolve_device(device)
    print(f"device: {device}")
    if device == "cpu":
        dtype = torch.float32
    elif device == "cuda" and torch.cuda.get_device_capability()[0] < 8:
        dtype = torch.float16  # pre-Ampere: no native bf16
    else:
        dtype = torch.bfloat16
    model = Qwen3TTSModel.from_pretrained(
        model_id,
        device_map=device,
        dtype=dtype,
        attn_implementation="sdpa",
    )
    attach_progress_bar(model)

    def synth(text, make_path):
        wavs, sr = model.generate_voice_clone(
            text=text,
            language=language,
            ref_audio=str(ref_audio),
            ref_text=ref_text,
        )
        path = make_path()
        sf.write(path, wavs[0], sr)
        yield path

    return synth


def load_mlx_synth(model_id, ref_audio, ref_text, language):
    """MLX backend (mlx-community/Qwen3-TTS-* and other mlx-audio conversions)."""
    import numpy as np
    import soundfile as sf
    from mlx_audio.tts.utils import load_model
    from mlx_audio.utils import load_audio

    # NOTE: MLX streams are thread-local; this must be called from the same
    # thread that will run synth (Speaker's synth_factory handles that).
    model = load_model(model_id)

    # Pay per-ref costs once instead of per request. mlx-audio caches the
    # ref's codec codes and tokens internally, but reloads + resamples the
    # audio file and recomputes the x-vector speaker embedding over the full
    # clip on every generate call; with long refs both are significant.
    ref_audio_arr = load_audio(str(ref_audio), sample_rate=model.sample_rate)
    if hasattr(model, "extract_speaker_embedding"):
        original_spk = model.extract_speaker_embedding
        spk_memo = {}

        def memoized_spk(audio):  # safe: the daemon serves one ref for life
            if "spk" not in spk_memo:
                spk_memo["spk"] = original_spk(audio)
            return spk_memo["spk"]

        model.extract_speaker_embedding = memoized_spk

    def synth(text, make_path):
        # Cap tokens at 2x the expected length: a model that misses the
        # end-of-speech token (more likely when quantized) otherwise babbles
        # until mlx-audio's 4096-token default (~5.5 min of audio).
        # Floor of 32 frames (~2.5s) only matters for very short texts; a
        # generous floor lets the model babble to it (observed: 20-char texts
        # consistently padding out to the old 64-frame floor).
        max_tokens = max(32, estimate_frames(text) * 2)
        cap_samples = None
        emitted = 0
        # stream=True yields audio segments every ~streaming_interval seconds
        # of audio, so playback starts long before generation finishes.
        for result in model.generate(
            text=text,
            ref_audio=ref_audio_arr,
            ref_text=ref_text,
            max_tokens=max_tokens,
            stream=True,
            streaming_interval=1.0,
        ):
            audio = np.asarray(result.audio)
            if audio.size == 0:
                continue
            sr = getattr(result, "sample_rate", 24000)
            cap_samples = (max_tokens - 1) * sr / 12.5  # codec is 12.5 frames/sec
            emitted += audio.size
            path = make_path()
            sf.write(path, audio, sr)
            yield path
        if cap_samples is not None and emitted >= cap_samples:
            print(f"warning: hit token cap ({max_tokens}); output may be "
                  f"truncated babble for: {text[:60]!r}", file=sys.stderr)

    return synth


def wrap_fx(synth, ring_freq, ring_mix):
    """Post-process every synthesized segment through the droid chain.

    One stateful DroidFX per synth call: segments of a stream are played
    gaplessly, so the ring-mod carrier and chorus LFO must continue across
    segment boundaries or the joins click. reset() per call keeps unrelated
    utterances from sharing filter tails.
    """
    import soundfile as sf
    from fx import DroidFX

    fx = DroidFX(ring_freq=ring_freq, ring_mix=ring_mix)

    def wrapped(text, make_path):
        fx.reset()
        for path in synth(text, make_path):
            audio, sr = sf.read(path, dtype="float32")
            if audio.ndim == 2:  # (samples, channels) -> (channels, samples)
                audio = audio.T
            processed = fx.process(audio, sr)
            sf.write(path, processed.T if processed.ndim == 2 else processed, sr)
            yield path

    return wrapped


def pick_backend(backend):
    """auto resolves to whichever backend's library is installed; the mlx and
    torch dependency groups are mutually exclusive, so presence decides."""
    if backend != "auto":
        return backend
    from importlib.util import find_spec
    if find_spec("mlx_audio") is not None:
        return "mlx"
    if find_spec("qwen_tts") is not None:
        return "qwen-tts"
    raise SystemExit(
        "neither mlx_audio nor qwen_tts is installed; run via\n"
        "  uv run tts/serve.py ...                       (mlx, default)\n"
        "  uv run --no-group mlx --group torch tts/serve.py ...  (PyTorch)"
    )


def load_synth(backend, model_id, ref_audio, ref_text, language, device="auto"):
    backend = pick_backend(backend)
    print(f"model: {model_id} (backend: {backend})")
    if backend == "mlx":
        return load_mlx_synth(model_id, ref_audio, ref_text, language)
    return load_qwen_tts_synth(model_id, ref_audio, ref_text, language, device)


def resolve_ref_text(ref_audio, ref_text_path):
    path = ref_text_path or ref_audio.with_suffix(".txt")
    if not path.exists():
        raise SystemExit(
            f"ref-text not found: {path}\n"
            f"transcribe it with:\n"
            f"  uv run transcribe/transcribe.py {ref_audio} --language en"
        )
    return path.read_text().strip()


def parse_args():
    p = argparse.ArgumentParser(
        description="Voice-clone TTS daemon (loads the model once, speaks POSTed text).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("-r", "--ref-audio", required=True, type=Path,
                   help="reference voice clip (~3s wav)")
    p.add_argument("--ref-text", type=Path,
                   help="transcript of --ref-audio (default: its sibling .txt)")
    p.add_argument("-m", "--model", default=DEFAULT_MODEL,
                   help="TTS model id (HF repo)")
    p.add_argument("-b", "--backend", choices=["auto", "mlx", "qwen-tts"],
                   default="auto",
                   help="auto picks whichever backend library is installed")
    p.add_argument("-l", "--language", default="English",
                   help="language of the text (qwen-tts backend only)")
    p.add_argument("-d", "--device", choices=["auto", "cuda", "mps", "cpu"],
                   default="auto",
                   help="torch device (qwen-tts backend only); auto picks "
                        "cuda > mps > cpu")
    p.add_argument("--fx", action="store_true",
                   help="apply the droid effect chain (fx.py) to all output")
    p.add_argument("--fx-ring-freq", type=float, default=40.0,
                   help="droid ring modulator carrier Hz")
    p.add_argument("--fx-ring-mix", type=float, default=0.12,
                   help="droid ring modulator wet mix 0-1")
    p.add_argument("-p", "--port", type=int, default=DEFAULT_PORT,
                   help="port to listen on")
    p.add_argument("--host", default=HOST,
                   help="address to bind (0.0.0.0 to serve the LAN; "
                        "set --token when doing so)")
    p.add_argument("--playback", choices=["local", "client"], default="local",
                   help="local: play audio on this machine; client: buffer "
                        "segments for clients to fetch via GET /segment")
    p.add_argument("--token", default=os.environ.get("VOICE_ML_TOKEN"),
                   help="require 'Authorization: Bearer <token>' on every "
                        "request (default: $VOICE_ML_TOKEN)")
    return p.parse_args()


def main():
    args = parse_args()
    if not args.ref_audio.exists():
        raise SystemExit(f"ref-audio not found: {args.ref_audio}")
    ref_text = resolve_ref_text(args.ref_audio, args.ref_text)

    if args.host not in ("127.0.0.1", "localhost", "::1") and not args.token:
        print("warning: binding beyond loopback with no --token; anyone on "
              "the network can drive synthesis", file=sys.stderr)
    store = SegmentStore() if args.playback == "client" else None

    # Serve immediately so clients can see "loading" via /health; /speak
    # returns 503 until the model is loaded. The model loads inside the
    # Speaker's synth thread because MLX streams are thread-local.
    app = App(model_id=args.model, token=args.token, segments=store)
    server = make_server(app, args.port, args.host)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"listening on http://{args.host}:{args.port}  "
          f"(POST /speak, /stop; GET /health; playback: {args.playback})")

    def factory():
        synth = load_synth(args.backend, args.model, args.ref_audio, ref_text,
                           args.language, args.device)
        if args.fx:
            synth = wrap_fx(synth, args.fx_ring_freq, args.fx_ring_mix)
        # Warm up before reporting ready: the first generation pays JIT and
        # cache costs (observed 4-20s extra) better spent at startup than on
        # the first real request.
        warm_dir = tempfile.mkdtemp(prefix="voice-warmup-")
        t0 = time.monotonic()
        for path in synth("Voice daemon warm up.",
                          lambda: os.path.join(warm_dir, f"{time.monotonic_ns()}.wav")):
            try:
                os.unlink(path)
            except OSError:
                pass
        print(f"warmup synth: {time.monotonic() - t0:.1f}s")
        return synth

    app.speaker = Speaker(synth_factory=factory, play_fn=store)
    app.speaker.ready.wait()
    print("ready")
    threading.Event().wait()


if __name__ == "__main__":
    main()
