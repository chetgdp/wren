"""Voice-clone TTS daemon: POST text, hear it in the cloned voice.

Loads Qwen3-TTS once and serves speak requests on 127.0.0.1 only. Markdown
is stripped server-side so clients (e.g. the pi `voice` extension) can send
raw agent output. Text is chunked into sentence groups so playback starts
after the first chunk instead of after the whole message. A new /speak or
/stop preempts anything still queued or playing.

Endpoints (every playback POST takes an optional "channel"; see Channels):
    POST /speak  {"text": "...", "raw": false, "append": false,
                  "speed": 1.5, "channel": "name"} -> {"queued": n}
                 speed (0.5-3.0) time-stretches only this request's output,
                 pitch-preserved (otherwise the product setting applies)
                 {"blocks": ["...", ...], ...}: indexed blocks; /health then
                 reports which block range is currently audible (read mode)
    POST /stop   {"channel": "name"} stops that channel only; without a
                 channel it stops every channel              -> {"ok": true}
    POST /pause  {"channel": "name"}           -> {"ok": true, "paused": true}
                 pauses that channel's playback (omitted = local); the
                 playhead stops, so synthesis parks on its own once the
                 lookahead budget is spent
    POST /resume {"channel": "name"}          -> {"ok": true, "paused": false}
    POST /seek   {"delta": 1} | {"block": n}, plus optional "channel"
                 -> {"ok": true, "block": n}; skips relative to what that
                 channel is playing, or to an absolute block index (needs a
                 prior blocks speak on the channel)
    GET  /health -> {"ok": true, "ready": b, "model": "...", "pending": n,
                     "speaking": b, "paused": b,
                     "block": [lo, hi] | null, "playback": "local"|"client",
                     "speed": f, "channels": {name: {"pending": n,
                     "speaking": b, "paused": b, "block": [lo, hi] | null,
                     "active": b}}}
                 top-level pending/speaking are machine-wide sums; paused
                 and block are the local channel's, so pre-channel clients
                 keep their old reading. A channel's "active" is true while
                 it holds ANY unfinished content, including what pending
                 misses (a batch parked mid-utterance, segments awaiting
                 the machine turn): waiting must not read as finished
    GET  /segment?after=n[&timeout=s][&channel=name][&played=k]  long-poll
                 for the next synthesized segment of a channel's stream:
                 audio/wav with X-Seq, X-Epoch, X-Block headers; 204 +
                 X-Epoch on timeout. An epoch change means playback was
                 preempted: drop locally queued audio. played=k reports the
                 client finished playing through seq k (the machine queue's
                 progress signal). Without channel this is the local
                 channel's stream, which only exists under
                 --local-player client (404 otherwise, exactly as before
                 channels).

With --token (or $VOICE_ML_TOKEN), every request must carry
"Authorization: Bearer <token>"; use it whenever --host exposes the daemon
beyond loopback.

Requests with an http(s) Origin header are rejected (403): web pages can
otherwise CSRF the loopback port. Browser-extension origins and clients
that send no Origin (curl, scripts) pass. Bodies over 1 MiB return 413.

"append" queues after what is already speaking instead of preempting it;
streaming clients send the first piece without it and the rest with it.

Channels: every /speak (and /pause, /resume, /seek, /stop) may carry an
optional "channel" name ([a-z0-9_-]{1,32}; omitted = "local"). Each channel
has its own content queue, epoch, and /segment stream, and exactly one
player; a machine-wide playback queue lets at most one channel be audible
at a time (see MachineQueue). A /speak without append clears every
channel - one voice per machine. Channels are created on first use and die
with the daemon. The local channel is played by the daemon itself unless
--local-player client; all other channels are always client-played
streams.

Example:
    uv run tts/serve.py -r samples/bossnass/ref.wav
    curl -X POST localhost:8765/speak -d '{"text": "hello there"}'
"""

from abc import ABC, abstractmethod
import argparse
import copy
import hmac
import io
import ipaddress
import json
import math
import os
import queue
import re
import subprocess
import socket
import stat
import sys
import tempfile
import threading
import time
import traceback
import uuid
from datetime import datetime, timezone
from dataclasses import asdict, dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit
try:
    from storage import (
        MAX_REFERENCE_WAV_BYTES, ManagementFailure, ProductSettings,
        SettingsStore, VoiceIssue, VoiceLibrary, VoiceLibraryEntry,
        VoiceLibrarySnapshot,
    )
except ModuleNotFoundError:  # package/module execution convenience
    from .storage import (
        MAX_REFERENCE_WAV_BYTES, ManagementFailure, ProductSettings,
        SettingsStore, VoiceIssue, VoiceLibrary, VoiceLibraryEntry,
        VoiceLibrarySnapshot,
    )

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

# Local 4-bit MLX conversion: only 4-bit runs above realtime here (RTF ~2.4
# streaming vs ~0.55 for bf16/PyTorch at any size), and 1.7B matches 0.6B
# 4-bit for speed while sounding better. Regenerate with:
#   uv run python -m mlx_audio.convert --hf-path Qwen/Qwen3-TTS-12Hz-1.7B-Base \
#       --mlx-path models/Qwen3-TTS-12Hz-1.7B-Base-4bit \
#       -q --q-bits 4 --model-domain tts
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
# Requests carry short prose; anything near this is abuse, and an uncapped
# read is a memory/CPU (sanitize regex) hole for whatever can reach the port.
MAX_BODY_BYTES = 1 * 1024 * 1024
# Browsers stamp cross-site requests with the page's Origin and JS cannot
# strip or spoof it, so rejecting http(s) origins kills drive-by CSRF from
# web pages against the loopback port. Extension clients pass (their Origin
# is an extension scheme) and non-browser clients send no Origin at all.
ALLOWED_ORIGIN_SCHEMES = (
    "chrome-extension:", "moz-extension:", "safari-web-extension:")
# Rubber Band artifacts dominate outside this range and extreme values are
# more likely a client bug than intent.
SPEED_MIN, SPEED_MAX = 0.5, 3.0
BACKEND_CHOICES = ("auto", "mlx", "qwen-tts", "qwentts")
# GET /segment's default long-poll length. The played-report grace window
# derives from it: a healthy client may sit a full poll cycle before its
# next played report, so a deadline shorter than the poll timeout would
# declare live clients dead; +10s absorbs network and scheduling slack.
SEGMENT_POLL_TIMEOUT = 20.0
PLAYED_GRACE = SEGMENT_POLL_TIMEOUT + 10.0
# A client parked in one long poll is silent for that whole poll, so a
# poll longer than the grace window would get a healthy client declared
# dead mid-poll and its queue cleared. /segment therefore caps the
# accepted timeout a slack under the grace instead of scaling deadlines
# per client (simpler, and the constant relation is testable).
MAX_POLL_TIMEOUT = PLAYED_GRACE - 5.0
# Channels are created on first use by name, so typo'd names must not
# accumulate speaker threads forever: idle and unpolled ones are deleted.
CHANNEL_GC_SECONDS = 600.0
CHANNEL_NAME_RE = re.compile(r"[a-z0-9_-]{1,32}\Z")
LOCAL_CHANNEL = "local"
@dataclass(frozen=True)
class VoiceProfile:
    """Validated daemon-owned voice metadata and stable source files."""

    id: str
    display_name: str
    root_path: str
    audio_path: str
    transcript_path: str
    transcript: str
    audio: bytes | None = None
    def __post_init__(self):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", self.id):
            raise ValueError(
                "voice id must be 1-128 URL-safe filename characters")
        if not isinstance(self.display_name, str) or not self.display_name.strip():
            raise ValueError("voice display name must not be empty")
        if not isinstance(self.transcript, str) or not self.transcript.strip():
            raise ValueError("voice transcript must not be empty")
        if self.audio is not None and not isinstance(self.audio, bytes):
            raise ValueError("voice audio payload must be bytes")
        if self.audio is None:
            root = Path(self.root_path).expanduser().resolve()
            audio = Path(self.audio_path).expanduser().resolve()
            transcript = Path(self.transcript_path).expanduser().resolve()
            if not root.is_dir():
                raise ValueError(f"voice root does not exist: {root}")
            for kind, path in (("audio", audio),
                               ("transcript", transcript)):
                try:
                    path.relative_to(root)
                except ValueError as exc:
                    raise ValueError(
                        f"voice {kind} path is outside its root: "
                        f"{path}") from exc
                if not path.is_file():
                    raise ValueError(
                        f"voice {kind} file does not exist: {path}")
        else:
            root = Path(os.path.abspath(
                os.path.expanduser(self.root_path)))
            audio = Path(os.path.abspath(
                os.path.expanduser(self.audio_path)))
            transcript = Path(os.path.abspath(
                os.path.expanduser(self.transcript_path)))
        object.__setattr__(self, "root_path", str(root))
        object.__setattr__(self, "audio_path", str(audio))
        object.__setattr__(self, "transcript_path", str(transcript))



@dataclass(frozen=True)
class VoiceContext:
    """Immutable prepared voice state; data is opaque to the daemon."""

    profile: VoiceProfile
    data: object
    identity: object


@dataclass(frozen=True)
class SynthesisSnapshot:
    """One semantic synthesis state captured atomically at acceptance."""

    context: VoiceContext
    effects: bool
    rate: float
    identity: object = field(init=False)

    def __post_init__(self):
        object.__setattr__(
            self, "identity",
            (self.context.profile.id, self.context.identity,
             self.effects, self.rate))


@dataclass(frozen=True)
class EngineHealth:
    """Whether synthesis is usable and, when not, its structured error."""

    usable: bool
    error: object | None = None


class SynthesisEngine(ABC):
    """Backend contract. Every method executes on its SynthWorker."""

    @abstractmethod
    def prepare(self, profile):
        """Return a preparation-pinned immutable VoiceContext."""

    @abstractmethod
    def synthesize(self, context, text, make_path, effects=False):
        """Yield audio paths using only the supplied immutable context."""

    @abstractmethod
    def retain(self, context):
        """Acquire one context pin."""

    @abstractmethod
    def release(self, context):
        """Release one context pin."""

    @abstractmethod
    def health(self):
        """Return EngineHealth without raising for a known engine failure."""

    @abstractmethod
    def close(self):
        """Release backend resources owned by the engine."""






def stretch_wav(path, speed):
    """Time-stretch a wav in place by speed (>1 = faster), preserving pitch.
    Counterpart of the extension's soundtouch stretch, but server-side so it
    also covers local playback and the /segment client feed."""
    import soundfile as sf
    from pedalboard import time_stretch
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    stretched = time_stretch(data.T, sr, stretch_factor=speed)
    sf.write(path, stretched.T, sr)


def sanitize_markdown(text):
    """Strip markdown down to speakable prose. Code blocks are dropped
    entirely."""
    text = re.sub(r"```.*?(```|\Z)", " ", text, flags=re.S)
    text = re.sub(r"~~~.*?(~~~|\Z)", " ", text, flags=re.S)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)  # images
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)  # links -> their text
    text = re.sub(r"`([^`]*)`", r"\1", text)  # inline code -> bare text
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.M)  # headers
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.M)  # bullets
    text = re.sub(r"^\s*\d+\.\s+", "", text, flags=re.M)  # numbered lists
    text = re.sub(r"^\s*>\s?", "", text, flags=re.M)  # blockquotes
    # hr / table separator rows
    text = re.sub(r"^[|+\-=:\s]+$", "", text, flags=re.M)
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
    duplicated here because that module imports torch (absent in the mlx
    env)."""
    return round(len(text.strip()) * 0.9)


CHARS_PER_SEC = 12 / 0.9  # inverse of the estimate_frames heuristic


def block_span(layout, sec0, sec1, chars_per_sec=CHARS_PER_SEC):
    """Sentence-index range estimated audible between sec0..sec1 of a synth
    batch's audio. layout is [(block_idx, char_count), ...] in speech order;
    position is interpolated by character share at chars_per_sec."""
    c0 = sec0 * chars_per_sec
    c1 = sec1 * chars_per_sec
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
    """Client-playback buffer: holds synthesized segments in memory for
    GET /segment long-polls instead of playing them on this machine.

    Implements the Speaker client-stream API (submit/invalidate) in place
    of a play_fn. seq is monotonic across the store's life so a client can
    always resume with the last seq it saw; invalidate() (preemption/stop)
    drops buffered segments and bumps epoch so a client knows to also drop
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
        # The daemon never learns what the client's player has finished, so
        # the last seq handed out is the playhead proxy the synth lookahead
        # budget measures against; the played cursor below is coarser (one
        # report per poll cycle) so it stays the machine queue's signal, not
        # the budget's.
        self._fetched = 0
        self.on_fetch = None  # budget freed on fetch; wakes the worker
        # Machine-queue progress: highest seq the client reports finished
        # playing, valid only within the current epoch. Durations of
        # released-but-unplayed segments back the dead-client deadline.
        self._played = 0
        self._epoch_base = 0
        self._durations = {}  # seq -> seconds

    def submit(self, path, block):
        seconds = _wav_seconds(path)
        with open(path, "rb") as f:
            data = f.read()
        with self._cond:
            self._seq += 1
            self._segments.append((self._seq, block, data))
            self._durations[self._seq] = seconds
            self._bytes += len(data)
            while self._bytes > self._max_bytes and len(self._segments) > 1:
                seq, _, dropped = self._segments.pop(0)
                self._bytes -= len(dropped)
                # The client can never play a dropped segment, so keeping
                # its duration would hold the machine queue's turn forever.
                self._durations.pop(seq, None)
                print(f"segment buffer full; dropped seq {seq} "
                      f"({len(dropped)} bytes) unfetched", file=sys.stderr)
            self._cond.notify_all()

    def invalidate(self):
        with self._cond:
            self.epoch += 1
            self._segments.clear()
            self._bytes = 0
            # Re-base the played cursor: reports about pre-bump seqs are
            # stale by definition and must not count as progress.
            self._epoch_base = self._seq
            self._played = self._seq
            self._durations.clear()
            self._cond.notify_all()

    def report_played(self, seq):
        """Client's played cursor: max within the current epoch. Reports
        about pre-bump seqs (stale epoch) and backward reports are ignored;
        the cursor never runs past what was actually released."""
        with self._cond:
            seq = min(seq, self._seq)
            if seq <= self._epoch_base or seq <= self._played:
                return
            self._played = seq
            for s in [s for s in self._durations if s <= seq]:
                del self._durations[s]

    def release_stats(self):
        """(released-unplayed count, their seconds, last released seq,
        played seq): the machine queue's view of this stream's progress."""
        with self._cond:
            return (len(self._durations), sum(self._durations.values()),
                    self._seq, self._played)

    def unfetched(self):
        """Buffered segments past the last-fetched seq: how far synthesis
        has run ahead of the client-playback playhead proxy."""
        with self._cond:
            return sum(1 for s, _, _ in self._segments if s > self._fetched)

    def next_after(self, seq, timeout=20.0):
        """First buffered segment with seq > the given one, waiting up to
        timeout. Returns (seq, block, data, epoch); data is None on timeout."""
        deadline = time.monotonic() + timeout
        found = None
        with self._cond:
            entry_epoch = self.epoch
            while found is None:
                if self.epoch != entry_epoch:
                    # Preempted while parked: return now (204 + new epoch)
                    # so the client drops its scheduled audio immediately
                    # instead of at the end of its poll cycle.
                    return None, None, None, self.epoch
                for s, block, data in self._segments:
                    if s > seq:
                        self._fetched = max(self._fetched, s)
                        found = (s, block, data, self.epoch)
                        break
                else:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return None, None, None, self.epoch
                    self._cond.wait(remaining)
        # Outside the lock: the callback takes the worker's lock, and the
        # worker holds its lock while calling unfetched() - nesting the two
        # here would be a lock-order inversion.
        if self.on_fetch is not None:
            self.on_fetch()
        return found


class _FunctionEngine(SynthesisEngine):
    """Internal adapter preserving direct Speaker construction in tests."""

    def __init__(self, synth):
        self._synth = synth

    def prepare(self, profile):
        return VoiceContext(
            profile, self._synth, ("function", id(self._synth), profile.id))

    def synthesize(self, context, text, make_path, effects=False):
        synth = context.data
        if getattr(synth, "_snapshot_effects", False):
            return synth(text, make_path, effects)
        return synth(text, make_path)

    def retain(self, context):
        pass

    def release(self, context):
        pass

    def health(self):
        return EngineHealth(True)

    def close(self):
        pass


def _legacy_profile():
    # Direct Speaker construction is an internal test convenience and has
    # no daemon-owned files to validate.
    profile = object.__new__(VoiceProfile)
    for name, value in (
            ("id", "legacy"), ("display_name", "Legacy"),
            ("root_path", ""), ("audio_path", ""),
            ("transcript_path", ""), ("transcript", ""),
            ("audio", None)):
        object.__setattr__(profile, name, value)
    return profile


class _ControlCall:
    __slots__ = ("fn", "args", "kwargs", "done", "result", "error")

    def __init__(self, fn, args, kwargs, wait):
        self.fn = fn
        self.args = args
        self.kwargs = kwargs
        self.done = threading.Event() if wait else None
        self.result = None
        self.error = None

    def run(self):
        try:
            self.result = self.fn(*self.args, **self.kwargs)
        except BaseException as exc:
            self.error = exc
            if self.done is None:
                traceback.print_exc()
        finally:
            if self.done is not None:
                self.done.set()


class _SnapshotLease:
    """One acceptance pin shared by all chunks of that accepted request."""

    __slots__ = ("snapshot", "_worker", "_remaining", "_lock",
                 "_release_context")

    def __init__(self, snapshot, worker, count, release_context=True):
        self.snapshot = snapshot
        self._worker = worker
        self._remaining = count
        self._lock = threading.Lock()
        self._release_context = release_context

    def release_one(self):
        release = False
        with self._lock:
            if self._remaining <= 0:
                return
            self._remaining -= 1
            release = self._remaining == 0
        if release and self._release_context:
            self._worker.release(self.snapshot.context, wait=False)


class _QueueItem:
    __slots__ = ("epoch", "index", "text", "snapshot", "_lease",
                 "_released")

    def __init__(self, epoch, index, text, lease):
        self.epoch = epoch
        self.index = index
        self.text = text
        self.snapshot = lease.snapshot
        self._lease = lease
        self._released = False

    def release(self):
        if not self._released:
            self._released = True
            self._lease.release_one()


class _Batch:
    """One resumable synthesis call and the snapshot-bound queue items."""

    __slots__ = ("epoch", "gen", "text", "layout", "block", "snapshot",
                 "items", "t0", "audio_s", "_released")

    def __init__(self, epoch, gen, text, layout, block, snapshot, items):
        self.epoch = epoch
        self.gen = gen
        self.text = text
        self.layout = layout
        self.block = block
        self.snapshot = snapshot
        self.items = items
        self.t0 = time.monotonic()
        self.audio_s = 0.0
        self._released = False

    def release(self):
        if self._released:
            return
        self._released = True
        for item in self.items:
            item.release()


class SynthWorker:
    """The engine-owning executor shared by every Speaker."""

    LOOKAHEAD = 2

    def __init__(self, synth_fn=None, synth_factory=None, engine=None,
                 engine_factory=None, voice_profile=None):
        sources = (synth_fn, synth_factory, engine, engine_factory)
        if sum(source is not None for source in sources) != 1:
            raise ValueError("pass exactly one synthesis source")
        self._source = next(source for source in sources
                            if source is not None)
        self._source_kind = next(
            name for name, source in zip(
                ("synth", "synth_factory", "engine", "engine_factory"),
                sources) if source is not None)
        self.initialized = threading.Event()
        self.initialization_error = None
        self._profile = voice_profile or _legacy_profile()
        self._engine = None
        self._context = None
        self._profile_pins = {}
        self._owner = None
        self.ready = threading.Event()
        self._cond = threading.Condition()
        self._controls = []
        self._prefer_synth = False
        self._speakers = []
        self._rr = 0
        threading.Thread(target=self._run, daemon=True).start()

    @property
    def context(self):
        return self._context

    def control(self, fn, *args, wait=True, **kwargs):
        """Run backend work on the engine owner, alternating with synthesis."""
        if threading.get_ident() == self._owner:
            return fn(*args, **kwargs)
        call = _ControlCall(fn, args, kwargs, wait)
        with self._cond:
            self._controls.append(call)
            self._cond.notify_all()
        if not wait:
            return None
        call.done.wait()
        if call.error is not None:
            raise call.error
        return call.result

    def prepare(self, profile):
        return self.control(self._prepare_owned, profile)

    def retain(self, context, wait=True):
        return self.control(self._retain_owned, context, wait=wait)

    def release(self, context, wait=True):
        return self.control(self._release_owned, context, wait=wait)

    def is_profile_pinned(self, profile_id):
        return self.control(
            lambda: self._profile_pins.get(profile_id, 0) > 0)

    def _prepare_owned(self, profile):
        context = self._engine.prepare(profile)
        profile_id = context.profile.id
        self._profile_pins[profile_id] = (
            self._profile_pins.get(profile_id, 0) + 1)
        return context

    def _retain_owned(self, context):
        self._engine.retain(context)
        profile_id = context.profile.id
        self._profile_pins[profile_id] = (
            self._profile_pins.get(profile_id, 0) + 1)

    def _release_owned(self, context):
        self._engine.release(context)
        profile_id = context.profile.id
        remaining = self._profile_pins.get(profile_id, 0) - 1
        if remaining > 0:
            self._profile_pins[profile_id] = remaining
        else:
            self._profile_pins.pop(profile_id, None)

    def health(self):
        return self.control(self._engine.health)

    def close(self):
        return self.control(self._engine.close)

    def register(self, speaker):
        with self._cond:
            self._speakers.append(speaker)
            self._cond.notify_all()

    def unregister(self, speaker):
        self.control(self._unregister_owned, speaker)

    def _unregister_owned(self, speaker):
        batch, speaker._batch = speaker._batch, None
        if batch is not None:
            try:
                batch.gen.close()
            except Exception as exc:
                print(f"synth failed: {exc}", file=sys.stderr)
            finally:
                batch.release()
        carry, speaker._carry = speaker._carry, None
        if carry is not None:
            carry.release()
        with self._cond:
            if speaker in self._speakers:
                self._speakers.remove(speaker)
                self._rr = 0
            self._cond.notify_all()

    def wake(self):
        with self._cond:
            self._cond.notify_all()

    def segment_taken(self, speaker, epoch):
        with self._cond:
            if epoch == speaker._inflight_epoch and speaker._inflight > 0:
                speaker._inflight -= 1
            self._cond.notify_all()

    def reset_budget(self, speaker):
        with self._cond:
            speaker._inflight = 0
            speaker._inflight_epoch = speaker._epoch
            self._cond.notify_all()

    def _initialize(self):
        source = self._source
        if self._source_kind.endswith("factory"):
            source = source()
        if not isinstance(source, SynthesisEngine):
            source = _FunctionEngine(source)
        self._engine = source
        prepared = self._prepare_owned(self._profile)
        self._retain_owned(prepared)
        self._release_owned(prepared)
        self._context = prepared

    def _run(self):
        self._owner = threading.get_ident()
        try:
            self._initialize()
        except BaseException as exc:
            self.initialization_error = exc
            traceback.print_exc()
            print("model load failed; daemon remains available",
                  file=sys.stderr)
            _cleanup_qwentts()
            self.initialized.set()
            return
        self.ready.set()
        self.initialized.set()
        while True:
            kind, value = self._next_action()
            if kind == "control":
                value.run()
                continue
            speaker = value
            speaker._synth_busy = True
            try:
                self._advance(speaker)
            except Exception:
                traceback.print_exc()
                print("synth failed; batch discarded", file=sys.stderr)
                batch, speaker._batch = speaker._batch, None
                if batch is not None:
                    try:
                        batch.gen.close()
                    except Exception:
                        pass
                    batch.release()
                self.reset_budget(speaker)
            finally:
                speaker._synth_busy = False

    def _next_action(self):
        """Alternate ready controls and synthesis so neither can starve."""
        with self._cond:
            while True:
                runnable = None
                count = len(self._speakers)
                for i in range(count):
                    candidate = self._speakers[(self._rr + i) % count]
                    if candidate._synth_runnable():
                        self._rr = (self._rr + i + 1) % count
                        runnable = candidate
                        break
                if self._controls and (
                        runnable is None or not self._prefer_synth):
                    self._prefer_synth = True
                    return "control", self._controls.pop(0)
                if runnable is not None:
                    self._prefer_synth = False
                    return "synth", runnable
                self._cond.wait()

    def _advance(self, speaker):
        batch = speaker._batch
        if batch is not None and batch.epoch != speaker._epoch:
            self._discard(speaker, batch)
            return
        if batch is None:
            batch = self._start_batch(speaker)
            if batch is None:
                return
            speaker._batch = batch
        self._pump(speaker, batch)

    def _start_batch(self, speaker):
        if speaker._carry is not None:
            item = speaker._carry
            speaker._carry = None
        else:
            try:
                item = speaker._synth_q.get_nowait()
            except queue.Empty:
                return None
        if item.epoch != speaker._epoch:
            item.release()
            return None
        epoch = item.epoch
        snapshot = item.snapshot
        items = [item]
        parts = [item.text]
        idxs = [] if item.index is None else [item.index]
        if epoch == speaker._last_synth_epoch:
            total = len(item.text)
            while total < speaker._max_chars:
                try:
                    next_item = speaker._synth_q.get_nowait()
                except queue.Empty:
                    break
                if next_item.epoch < epoch:
                    next_item.release()
                    continue
                if (next_item.epoch > epoch
                        or next_item.snapshot.identity != snapshot.identity):
                    speaker._carry = next_item
                    break
                items.append(next_item)
                parts.append(next_item.text)
                if next_item.index is not None:
                    idxs.append(next_item.index)
                total += len(next_item.text) + 1
        if epoch != speaker._epoch:
            for queued in items:
                queued.release()
            return None
        text = " ".join(parts)
        speaker._last_synth_epoch = epoch
        block = (idxs[0], idxs[-1]) if idxs else None
        layout = (list(zip(idxs, (len(part) for part in parts)))
                  if idxs and len(idxs) == len(parts) else None)
        print(f'synthesizing ({len(text)} chars, '
              f'{speaker.pending()} queued): "{text}"', flush=True)
        try:
            gen = self._engine.synthesize(
                snapshot.context, text, speaker._make_path, snapshot.effects)
        except Exception:
            for queued in items:
                queued.release()
            raise
        return _Batch(epoch, gen, text, layout, block, snapshot, items)

    def _pump(self, speaker, batch):
        while True:
            if batch.epoch != speaker._epoch:
                self._discard(speaker, batch)
                return
            if not speaker._synth_schedulable():
                return
            try:
                path = next(batch.gen)
            except StopIteration:
                self._finish(speaker, batch)
                return
            if batch.epoch != speaker._epoch:
                self._discard(speaker, batch)
                return
            if batch.snapshot.rate != 1.0:
                try:
                    stretch_wav(path, batch.snapshot.rate)
                except Exception as exc:
                    print(f"time-stretch failed ({exc}); playing at "
                          "1.0x", file=sys.stderr)
            seg_start = batch.audio_s
            batch.audio_s += _wav_seconds(path)
            seg_block = (block_span(
                batch.layout, seg_start, batch.audio_s,
                speaker._chars_per_sec)
                if batch.layout and batch.audio_s > seg_start
                else batch.block)
            with self._cond:
                if batch.epoch == speaker._inflight_epoch:
                    speaker._inflight += 1
            speaker._play_q.put((batch.epoch, path, seg_block))
            # Re-enter the fair scheduler between streamed segments so
            # queued controls and other Speakers cannot starve.
            return

    def _discard(self, speaker, batch):
        speaker._batch = None
        try:
            batch.gen.close()
        except Exception as exc:
            print(f"synth failed: {exc}", file=sys.stderr)
        finally:
            batch.release()

    def _finish(self, speaker, batch):
        speaker._batch = None
        batch.release()
        wall = time.monotonic() - batch.t0
        print(f"  {batch.audio_s:.1f}s audio in {wall:.1f}s"
              f" (RTF {batch.audio_s / wall:.2f})", flush=True)
        if batch.epoch == speaker._epoch and batch.audio_s > 0:
            measured = len(batch.text) / batch.audio_s
            if 5.0 <= measured <= 30.0:
                speaker._chars_per_sec = (
                    0.5 * speaker._chars_per_sec + 0.5 * measured)

class Speaker:
    """Per-utterance queue and playback state; synthesis itself runs on a
    SynthWorker. speak() preempts whatever is queued or playing.

    synth_fn(text, make_path) is a generator yielding wav paths as audio
    segments complete (streaming backends yield several per text; make_path()
    returns a fresh output path). play_fn(path) returns a handle with wait()
    and terminate() (default: afplay Popen). Each speak() bumps an epoch;
    stale-epoch work is dropped at every stage, including mid-generation.

    Pass synth_factory instead of synth_fn to load the model inside the
    worker thread (MLX streams are thread-local, so the model must be loaded
    and used by the same thread). `ready` is set once synthesis can proceed;
    a failed load prints the error and exits the process. Pass worker to
    share an existing SynthWorker instead of creating one.
    """

    def __init__(self, synth_fn=None, play_fn=None, max_chars=MAX_CHUNK_CHARS,
                 first_chars=FIRST_CHUNK_CHARS, synth_factory=None, speed=1.0,
                 worker=None, engine=None, engine_factory=None,
                 voice_profile=None):
        if worker is None:
            sources = (synth_fn, synth_factory, engine, engine_factory)
            if sum(source is not None for source in sources) != 1:
                raise ValueError("pass exactly one synthesis source")
            worker = SynthWorker(
                synth_fn=synth_fn, synth_factory=synth_factory,
                engine=engine, engine_factory=engine_factory,
                voice_profile=voice_profile)
        self._worker = worker
        self.ready = worker.ready
        self._play = play_fn or default_player()
        self._max_chars = max_chars
        self._first_chars = first_chars
        # Daemon default rate. Request overrides live only in their snapshot.
        self.speed = speed
        self._lock = threading.Lock()
        self._epoch = 0
        self._pause = threading.Event()
        self._synth_q = queue.Queue()
        self._play_q = queue.Queue()
        self._current = None
        self._current_block = None
        self._blocks = None  # last blocks-speak, kept for /seek
        self._blocks_snapshot = None
        self._last_played = None  # block index most recently started
        self._counter = 0
        self._last_synth_epoch = -1
        # Worker-side synthesis state: the parked in-flight batch, an item
        # rescued mid-coalesce, and how many rendered segments sit unplayed
        # (the lookahead budget's measure of "ahead of the playhead").
        # _inflight only counts segments of _inflight_epoch, the epoch as of
        # the last reset_budget: a stale segment popped after a preemption
        # must not free budget the new epoch is charged for.
        self._batch = None
        self._carry = None
        self._inflight = 0
        self._inflight_epoch = 0
        # Channel hooks, attached by ChannelManager. Without them (bare
        # Speaker, pre-channels behavior) nothing is gated. _gate answers
        # "may this channel render right now"; _turn_wait blocks a release
        # until the machine queue grants the turn; _on_progress tells the
        # queue the playhead moved. _popped counts a segment that sits
        # between the play queue and its player so the machine queue still
        # sees it as rendered audio.
        self._gate = None
        self._turn_wait = None
        self._on_progress = None
        self._popped = 0
        self._synth_busy = False  # worker mid-advance for this Speaker
        # Speech rate used to place the read-mode highlight inside a batch
        # (block_span). Starts at the heuristic and is recalibrated from
        # each completed batch, because the fixed value drifts by whole
        # sentences over a ~20s batch when the active voice speaks faster
        # or slower than ~13 chars/sec.
        self._chars_per_sec = CHARS_PER_SEC
        self._tmpdir = tempfile.mkdtemp(prefix="voice-serve-")
        # In client mode a fetch moves the playhead proxy, freeing budget.
        if hasattr(self._play, "on_fetch"):
            self._play.on_fetch = self._worker.wake
        threading.Thread(target=self._play_loop, daemon=True).start()
        self._worker.register(self)

    def speak(self, text=None, append=False, blocks=None, speed=None,
              snapshot=None):
        """Queue text with one immutable, already-retained snapshot.

        Direct Speaker callers may omit snapshot; that internal convenience
        captures and retains the worker's current context here. HTTP callers
        always pass the App-captured snapshot.
        """
        if blocks is None:
            blocks = [(None, text)]
        chunks = self._chunks_for(blocks)
        release_context = snapshot is not None
        if snapshot is None:
            self.ready.wait()
            snapshot = SynthesisSnapshot(
                self._worker.context, False,
                self.speed if speed is None else speed)
            # The legacy callable adapter has no backend registration to pin.
            # Keeping this direct-test convenience synchronous preserves the
            # pre-existing acceptance/preemption and backlog timing.
            release_context = not isinstance(
                self._worker._engine, _FunctionEngine)
            if release_context:
                self._worker.retain(snapshot.context)
        if not chunks:
            if release_context:
                self._worker.release(snapshot.context, wait=False)
            return 0
        lease = _SnapshotLease(
            snapshot, self._worker, len(chunks),
            release_context=release_context)
        with self._lock:
            if not append:
                self._preempt_locked()
                self._replace_blocks_locked(blocks, snapshot)
            epoch = self._epoch
            for idx, chunk in chunks:
                self._synth_q.put(_QueueItem(
                    epoch, idx, chunk, lease))
        self._worker.wake()
        return len(chunks)

    def _replace_blocks_locked(self, blocks, snapshot):
        old = self._blocks_snapshot
        indexed = [(index, text) for index, text in blocks
                   if index is not None]
        if indexed:
            self._worker.retain(snapshot.context)
            self._blocks = indexed
            self._blocks_snapshot = snapshot
        else:
            self._blocks = None
            self._blocks_snapshot = None
        if old is not None:
            self._worker.release(old.context, wait=False)

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
        # The drained play queue held everything counted in flight; the
        # wake also lets the worker discard a now-stale parked batch.
        self._worker.reset_budget(self)
        self._terminate_current()
        if hasattr(self._play, "invalidate"):  # client segment stream
            self._play.invalidate()
        self._resume_locked()  # a paused player would sit on the new audio
        self._last_played = None
        # Stop reporting the preempted segment's position now; waiting for
        # the cancelled handle to unwind leaves /health pointing at audio
        # that is no longer meant to play.
        self._current_block = None

    def clear_blocks(self):
        """Prevent a later seek from resurrecting preempted channel text."""
        with self._lock:
            old = self._blocks_snapshot
            self._blocks = None
            self._blocks_snapshot = None
        if old is not None:
            self._worker.release(old.context, wait=False)

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
            snapshot = self._blocks_snapshot
            chunks = self._chunks_for(
                [(i, t) for i, t in blocks if i >= target])
            self._worker.retain(snapshot.context)
            lease = _SnapshotLease(snapshot, self._worker, len(chunks))
            self._preempt_locked()
            epoch = self._epoch
            for idx, chunk in chunks:
                self._synth_q.put(_QueueItem(
                    epoch, idx, chunk, lease))
            # Until the new audio starts, this target is the position a
            # follow-up relative seek must be based on; leaving it None
            # would send the next j/k back to the start of the document.
            self._last_played = target
        self._worker.wake()
        return target

    def stop(self):
        with self._lock:
            self._epoch += 1
            self._drain()
            old = self._blocks_snapshot
            self._blocks = None
            self._blocks_snapshot = None
            self._worker.reset_budget(self)
            self._terminate_current()
            if hasattr(self._play, "invalidate"):
                self._play.invalidate()
            self._resume_locked()
        if old is not None:
            self._worker.release(old.context, wait=False)
        self._worker.wake()

    def pause(self):
        """Pause playback. The playhead stops, so the worker parks on its
        own once the LOOKAHEAD budget is spent - resume has that audio ready
        instead of waiting on a cold generate call. Local playback pauses
        via the PCM player; the afplay fallback keeps playing its current
        segment."""
        # Flag and player pause move as one unit under the lock: a
        # deferred cross-channel resume re-checks the flag under this
        # same lock, so a re-pause can never be undone by a resume that
        # lost the race.
        with self._lock:
            self._pause.set()
            if hasattr(self._play, "pause"):
                self._play.pause()
        return True

    def resume(self):
        # Flag and player state move as one unit under the same lock
        # pause() takes, so an interleaved pause/resume flurry can never
        # leave the flag and the player disagreeing.
        with self._lock:
            self._resume_locked()
        self._worker.wake()  # a parked batch is schedulable again
        return True

    def _resume_locked(self):
        """resume() for callers already holding self._lock (preempt/stop
        paths); the lock is not reentrant."""
        self._pause.clear()
        if hasattr(self._play, "resume"):
            self._play.resume()

    def paused(self):
        return self._pause.is_set()

    def speaking(self):
        return self._current is not None

    def current_block(self):
        """(lo, hi) block-index range of the audio now playing, or None."""
        return self._current_block

    def pending(self):
        return self._synth_q.qsize() + self._play_q.qsize()

    def _synth_runnable(self):
        """Run stale parked state even when the channel gate is closed."""
        if self._batch is not None and self._batch.epoch != self._epoch:
            return True
        if self._carry is not None and self._carry.epoch != self._epoch:
            return True
        has_work = (self._batch is not None or self._carry is not None
                    or not self._synth_q.empty())
        return has_work and self._synth_schedulable()

    def _synth_schedulable(self):
        """May the worker render another segment? Not once LOOKAHEAD
        segments sit unplayed: synthesis tracks the playhead instead of
        free-running a whole message's audio into memory. Pause needs no
        rule of its own - it stops the playhead, so this budget parks the
        worker a couple of segments later. The channel gate extends the
        same idea machine-wide: a channel that does not hold the audible
        turn keeps its text unrendered instead of piling up audio."""
        if self._gate is not None and not self._gate():
            return False
        return self._lookahead_used() < SynthWorker.LOOKAHEAD

    def has_queued_text(self):
        """Unrendered content: what an interrupted channel resumes with."""
        return (self._synth_busy or not self._synth_q.empty()
                or self._carry is not None
                or (self._batch is not None
                    and self._batch.epoch == self._epoch))

    def rendered_pending(self):
        """Rendered segments not yet at (or past) the player: the audio an
        interrupted channel is allowed to finish before going quiet.

        Read under the play queue's own mutex: _pop_segment moves a
        segment from the queue's size into _popped under that same lock,
        so the sum can never transiently read 0 for a segment in hand
        (the arbiter would retire the channel and its final segment
        would play after someone else's turn)."""
        with self._play_q.mutex:
            limbo = self._play_q._qsize() + self._popped
        return limbo + (1 if self._current is not None else 0)

    def _lookahead_used(self):
        """Segments rendered but not yet reached by the playhead. Local
        playback: what still sits in the play queue (the playing segment
        already left it). Client playback: the play queue drains into the
        segment store immediately, so count what no client has fetched."""
        used = self._inflight
        unfetched = getattr(self._play, "unfetched", None)
        if unfetched is not None:
            used += unfetched()
        return used

    def _drain(self):
        while True:
            try:
                item = self._synth_q.get_nowait()
            except queue.Empty:
                break
            item.release()
        while True:
            try:
                self._play_q.get_nowait()
            except queue.Empty:
                break

    def _terminate_current(self):
        current = self._current
        if current is not None:
            try:
                current.terminate()
            except Exception:
                pass

    def _make_path(self):
        self._counter += 1
        return os.path.join(self._tmpdir, f"{self._counter}.wav")

    def close(self):
        """Stop, release seek state, detach, and end the play loop."""
        self.stop()
        self.clear_blocks()
        self._worker.unregister(self)
        self._play_q.put(None)

    def _play_loop(self):
        while True:
            item = self._pop_segment()
            if item is None:  # close(): the channel was deleted
                return
            try:
                self._deliver(*item)
            finally:
                with self._play_q.mutex:
                    self._popped -= 1
                if self._on_progress is not None:
                    self._on_progress()

    def _pop_segment(self):
        """Dequeue plus the in-limbo count as one atomic step. A plain
        blocking get() opens an instant where the segment is counted by
        neither qsize nor _popped; rendered_pending() reads under this
        same mutex, which makes the no-transient-zero invariant
        structural rather than timing-dependent. Uses queue.Queue's
        documented-for-subclassing internals (mutex/not_empty/_get) so
        every other queue operation keeps working unchanged."""
        q = self._play_q
        with q.not_empty:
            while not q._qsize():
                q.not_empty.wait()
            item = q._get()
            q.not_full.notify()
            if item is not None:
                self._popped += 1
        return item

    def _deliver(self, epoch, path, block):
        if epoch != self._epoch:
            # Frees the stale segment's own charge; a no-op once a
            # preemption re-based the budget onto the new epoch.
            self._worker.segment_taken(self, epoch)
            return
        # A channel without the audible turn parks here with its rendered
        # segment until the machine queue grants it; a preemption (epoch
        # bump) aborts the wait and the segment is dropped as stale.
        if self._turn_wait is not None and not self._turn_wait(epoch):
            self._worker.segment_taken(self, epoch)
            return
        if hasattr(self._play, "submit"):  # client segment stream
            try:
                self._play.submit(path, block)
            except Exception as exc:
                print(f"segment submit failed: {exc}", file=sys.stderr)
            finally:
                # Only after submit: until then the segment is counted
                # by neither the play queue nor the store's unfetched
                # tally, and dropping it from the budget early lets
                # synthesis run a segment past the lookahead.
                self._worker.segment_taken(self, epoch)
                try:
                    os.unlink(path)
                except OSError:
                    pass
            return
        # Local playback: dequeue means this segment plays now, so the
        # playhead advanced and a lookahead slot is free.
        self._worker.segment_taken(self, epoch)
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


class MachineQueue:
    """The machine-wide playback line: at most one channel is audible at a
    time, FIFO by arrival at segment granularity.

    Fresh arrivals wait in _line. A holder that still has unrendered text
    when an eligible fresh arrival waits finishes only its rendered
    lookahead, goes quiet, and parks on _resume; _resume drains
    newest-interruption-first once the line is empty, so interrupted
    content re-enters behind everything that arrived meanwhile.
    Enforcement is segment release: a channel's Speaker consults
    may_render before synthesizing and wait_turn before releasing, so a
    channel without the turn holds text, not audio.

    Client channels prove liveness with their played cursor: once nothing
    is progressing and someone else is waiting, the holder gets its
    remaining released audio duration plus PLAYED_GRACE to report played;
    silence past that means the client died and the queue moves on. With
    no one waiting the clock never runs - a sole client that never reports
    played (today's extension) keeps working.

    Lock ordering: this queue's lock nests inside the manager's and the
    Speakers' locks (state_fns read Speaker attributes lock-free and take
    only SegmentStore's condition); worker wakeups happen outside it.
    """

    def __init__(self, clock=time.monotonic, grace=PLAYED_GRACE):
        self._clock = clock
        self._grace = grace
        self._cond = threading.Condition()
        self._state_fns = {}
        self._holder = None
        self._line = []    # fresh arrivals, FIFO
        self._resume = []  # interrupted channels, resumed LIFO
        self._progress = None    # (released seq, played seq) last seen
        self._progress_t = 0.0   # when it last changed
        # Lock-free snapshot (holder, challenged) for the synth gate: it is
        # read under the worker's condition, where taking this queue's lock
        # would invert the ordering with poke()'s worker wakeup.
        self._grant = (None, False)
        self.on_change = None  # SynthWorker.wake; called outside the lock
        self.on_dead = None    # dead-client cleanup; called outside the lock

    def register(self, name, state_fn):
        with self._cond:
            self._state_fns[name] = state_fn

    def unregister(self, name, fn=None):
        """fn, when given, must match the live registration: GC hands in
        the state_fn it registered, so a channel recreated under the same
        name between GC's delete and this call keeps its registration
        instead of being silently torn down."""
        with self._cond:
            if fn is not None and self._state_fns.get(name) is not fn:
                return
            self._state_fns.pop(name, None)
            self._drop_locked(name)
            kills, changed = self._advance_locked()
        self._after(kills, changed)

    def enqueue(self, name):
        """The channel has content and wants the speakers. Already queued
        (or holding) channels keep their place; their new content simply
        extends their own queue."""
        with self._cond:
            if (name != self._holder and name not in self._line
                    and name not in self._resume):
                self._line.append(name)
            kills, changed = self._advance_locked()
        self._after(kills, changed)

    def remove(self, name):
        """Pause/stop took this channel out of contention; /resume or new
        content re-enters it at the tail."""
        with self._cond:
            self._drop_locked(name)
            kills, changed = self._advance_locked()
        self._after(kills, changed)

    def clear(self):
        """Preempt-all: the waiter list and all resume state go; channels
        whose epochs the caller bumps are out of the line entirely."""
        with self._cond:
            self._line.clear()
            self._resume.clear()
            self._holder = None
            self._progress = None
            self._grant = (None, False)
            self._cond.notify_all()
        if self.on_change is not None:
            self.on_change()

    def poke(self):
        """Scheduling inputs changed (release, played report, poll, timer
        tick): re-evaluate whose turn it is."""
        with self._cond:
            kills, changed = self._advance_locked()
        self._after(kills, changed)

    def holder(self):
        return self._holder

    def queued(self, name):
        """Turn membership: holding the turn, waiting in line, or parked
        mid-utterance for a resume."""
        with self._cond:
            return (name == self._holder or name in self._line
                    or name in self._resume)

    def may_render(self, name):
        """Synth gate: only the unchallenged holder renders new segments.
        A challenged holder finishes its rendered lookahead and yields."""
        holder, challenged = self._grant
        return holder == name and not challenged

    def wait_turn(self, name, cancelled):
        """Block a release until the turn arrives; cancelled() (an epoch
        bump) aborts. Waits in short slices so preemption paths that
        cannot reach this condition still land promptly."""
        with self._cond:
            while self._holder != name:
                if cancelled():
                    return False
                self._cond.wait(0.05)
            return True

    def _drop_locked(self, name):
        if self._holder == name:
            self._holder = None
            self._progress = None
        if name in self._line:
            self._line.remove(name)
        if name in self._resume:
            self._resume.remove(name)

    def _eligible_waiting_locked(self):
        return any(self._state_fns[n]()["eligible"] for n in self._line
                   if n in self._state_fns)

    def _advance_locked(self):
        kills = []
        now = self._clock()
        moved = True
        while moved:
            moved = False
            holder = self._holder
            if holder is not None and holder in self._state_fns:
                st = self._state_fns[holder]()
                waiting = self._eligible_waiting_locked()
                if st["paused"]:
                    # Explicit pause yields immediately; /resume re-enters
                    # at the tail via the manager.
                    self._holder = None
                elif st["released"] > 0:
                    progress = (st["released_seq"], st["played_seq"])
                    if progress != self._progress:
                        self._progress = progress
                        self._progress_t = now
                    elif (waiting and now - self._progress_t
                            > st["released_s"] + self._grace):
                        # Duration is the deadline, not the progress
                        # signal: silence past it means a dead client.
                        kills.append(holder)
                        self._holder = None
                elif st["rendered"] == 0:
                    if not st["has_text"]:
                        self._holder = None  # finished; next in line
                    elif waiting:
                        # Rendered lookahead is spent and someone eligible
                        # waits: park with the remaining text.
                        self._resume.append(holder)
                        self._holder = None
                if self._holder != holder:
                    self._progress = None
                    moved = True
            if self._holder is None and self._grant_locked(now):
                moved = True
        grant = (self._holder, self._eligible_waiting_locked())
        changed = grant != self._grant
        if changed:
            self._grant = grant
            self._cond.notify_all()
        return kills, changed

    def _grant_locked(self, now):
        # A queued name can outlive its registration (GC racing an
        # enqueue): granting it would KeyError on every poke from then
        # on, killing the janitor. Drop such names instead of trusting
        # every enqueue/unregister interleaving to be airtight.
        for group in (self._line, self._resume):
            for name in [n for n in group if n not in self._state_fns]:
                group.remove(name)
                print(f"channel {name}: queued without state; dropped",
                      file=sys.stderr)
        for i, name in enumerate(self._line):
            if self._state_fns[name]()["eligible"]:
                self._holder = self._line.pop(i)
                break
        else:
            # Newest interruption resumes first: it was cut mid-utterance
            # most recently, like a stack of nested interruptions.
            for i in range(len(self._resume) - 1, -1, -1):
                if self._state_fns[self._resume[i]]()["eligible"]:
                    self._holder = self._resume.pop(i)
                    break
            else:
                # Last resort, self-healing: a channel that lost its queue
                # slot to a state-read race but still holds content must
                # not sit silent forever. Only reached when nobody else
                # wants the machine.
                for name, fn in self._state_fns.items():
                    st = fn()
                    if st["eligible"] and (st["has_text"]
                                           or st["rendered"] > 0):
                        self._holder = name
                        break
                else:
                    return False
        self._progress = None
        self._progress_t = now
        return True

    def _after(self, kills, changed):
        if changed and self.on_change is not None:
            self.on_change()
        for name in kills:
            print(f"channel {name}: client stopped reporting played; "
                  "cleared", file=sys.stderr)
            if self.on_dead is not None:
                self.on_dead(name)
        if kills:
            self.poke()


class Channel:
    """One name's queue, stream, and poll liveness. Client channels stream
    through their own SegmentStore; the daemon-played local channel has
    none and plays through the machine's speakers directly."""

    __slots__ = ("name", "speaker", "store", "active_polls", "last_poll",
                 "created", "last_used", "busy", "state_fn")

    def __init__(self, name, speaker, store, created):
        self.name = name
        self.speaker = speaker
        self.store = store
        self.active_polls = 0
        self.last_poll = None  # None: never polled -> not turn-eligible
        self.created = created
        # GC inputs beyond polls: any request touching the channel is
        # liveness, and busy pins it while a request is mid-operation so
        # deletion can never interleave with a speak/pause/seek in hand.
        self.last_used = created
        self.busy = 0
        # The state_fn registered with the MachineQueue, kept so GC can
        # unregister exactly what it registered (a recreated same-name
        # channel must keep its own registration).
        self.state_fn = None


class ChannelManager:
    """Per-utterance routing on top of the one shared SynthWorker: each
    /speak lands in exactly one channel, each channel has exactly one
    player, and the MachineQueue arbitrates the single machine voice.
    Channels are created on first use by name and die with the daemon
    (idle unpolled ones earlier, via GC)."""

    def __init__(self, local_speaker, local_store, grace=PLAYED_GRACE,
                 poll_window=PLAYED_GRACE, gc_seconds=CHANNEL_GC_SECONDS,
                 tick=0.5, clock=time.monotonic):
        self._lock = threading.Lock()
        self._clock = clock
        self._poll_window = poll_window
        self._gc_seconds = gc_seconds
        self._tick = tick
        self._worker = local_speaker._worker
        self.speed = local_speaker.speed
        self.queue = MachineQueue(clock=clock, grace=grace)
        self.queue.on_change = self._worker.wake
        self.queue.on_dead = self._kill
        local = Channel(LOCAL_CHANNEL, local_speaker, local_store, clock())
        self._channels = {LOCAL_CHANNEL: local}
        self._attach(local)
        # A local speaker already mid-utterance when channels come up owns
        # the turn it was implicitly using.
        if self._has_content(local):
            self.queue.enqueue(LOCAL_CHANNEL)
        self._janitor = threading.Thread(target=self._maintain, daemon=True)
        self._janitor.start()

    def channel(self, name):
        with self._lock:
            return self._channel_locked(name)

    def _channel_locked(self, name):
        ch = self._channels.get(name)
        if ch is None:
            store = SegmentStore()
            speaker = Speaker(play_fn=store, worker=self._worker,
                              speed=self.speed)
            ch = Channel(name, speaker, store, self._clock())
            self._channels[name] = ch
            self._attach(ch)
        # Any touch is liveness: GC must not collect a channel a request
        # just used.
        ch.last_used = self._clock()
        return ch

    def _acquire(self, name):
        """Lookup plus an in-use pin in one locked step: GC eligibility
        and removal take the same lock, so a channel handed out here can
        never be deleted while the request still operates on it."""
        with self._lock:
            ch = self._channel_locked(name)
            ch.busy += 1
        return ch

    def _release(self, ch):
        with self._lock:
            ch.busy -= 1
            ch.last_used = self._clock()

    def _attach(self, ch):
        speaker, name = ch.speaker, ch.name
        speaker._gate = lambda: self.queue.may_render(name)

        def turn_wait(epoch):
            # A segment in hand means this channel wants the speakers;
            # re-enqueueing (idempotent) heals the race where the turn was
            # released in the instant between queue-empty and this pop.
            if self.queue.holder() != name:
                self.queue.enqueue(name)
            return self.queue.wait_turn(
                name, lambda: speaker._epoch != epoch)

        speaker._turn_wait = turn_wait
        speaker._on_progress = self.queue.poke
        ch.state_fn = lambda: self._state(ch)
        self.queue.register(name, ch.state_fn)

    def _state(self, ch):
        """The MachineQueue's per-channel scheduling inputs, read without
        the Speaker's lock (all are single reads; a stale value only
        delays a decision to the next poke)."""
        speaker, store = ch.speaker, ch.store
        paused = speaker.paused()
        state = {
            "rendered": speaker.rendered_pending(),
            "has_text": speaker.has_queued_text(),
            "paused": paused,
            "released": 0, "released_s": 0.0,
            "released_seq": 0, "played_seq": 0,
        }
        if store is None:  # daemon-played local: always poll-eligible
            state["eligible"] = not paused
            return state
        released, released_s, seq, played = store.release_stats()
        state.update(released=released, released_s=released_s,
                     released_seq=seq, played_seq=played)
        # No dead-air turns: a client channel earns eligibility with an
        # outstanding or recent poll, so a typo'd name just holds text.
        polled = ch.active_polls > 0 or (
            ch.last_poll is not None
            and self._clock() - ch.last_poll < self._poll_window)
        state["eligible"] = polled and not paused
        return state

    def _has_content(self, ch):
        st = self._state(ch)
        return st["rendered"] > 0 or st["released"] > 0 or st["has_text"]

    def speak(self, name, text=None, blocks=None, append=False, speed=None,
              snapshot=None):
        ch = self._acquire(name)
        try:
            if not append:
                self.preempt_all(keep=name)
            queued = ch.speaker.speak(
                text=text, blocks=blocks, append=append, speed=speed,
                snapshot=snapshot)
            self.queue.enqueue(name)
            return queued
        finally:
            self._release(ch)

    def preempt_all(self, keep=None):
        """One voice per machine: a non-append /speak silences and clears
        every channel (the keep channel's own preemption happens in its
        speak()). Lock order: manager -> speaker -> worker/store; the
        machine queue's lock is never held around any of those."""
        self.queue.clear()
        with self._lock:
            channels = [ch for ch in self._channels.values()
                        if ch.name != keep]
        for ch in channels:
            ch.speaker.stop()
            ch.speaker.clear_blocks()

    def set_speed(self, speed):
        with self._lock:
            self.speed = speed
            for ch in self._channels.values():
                ch.speaker.speed = speed

    def pause(self, name):
        ch = self._acquire(name)
        try:
            ch.speaker.pause()
            # A paused holder yields immediately; a paused waiter leaves
            # the line and re-enters at the tail on /resume.
            self.queue.remove(name)
            return ch.speaker.paused()
        finally:
            self._release(ch)

    def resume(self, name):
        ch = self._acquire(name)
        try:
            speaker = ch.speaker
            if (speaker._current is not None
                    and hasattr(speaker._play, "resume")
                    and self.queue.holder() != name):
                # The in-flight segment already passed wait_turn under an
                # earlier grant; audibly un-pausing it now would speak
                # over whoever holds the turn. Clear the pause flag (the
                # arbiter sees the channel as eligible again) but keep
                # the player muted until the turn actually comes back.
                # Under the speaker's lock: pause() moves flag and player
                # as one unit there, so this clear must too, or a racing
                # pause lands between them and is silently undone.
                with speaker._lock:
                    speaker._pause.clear()
                self._resume_when_granted(name, speaker)
                speaker._worker.wake()
            else:
                speaker.resume()
            if self._has_content(ch):
                self.queue.enqueue(name)
            else:
                self.queue.poke()
            return speaker.paused()
        finally:
            self._release(ch)

    def _resume_when_granted(self, name, speaker):
        """Park a mid-segment resume until the machine queue grants the
        turn back; a preempt/stop (epoch bump, which resumes the player
        itself) or a re-pause abandons the wait."""
        epoch = speaker._epoch

        def cancelled():
            return speaker._epoch != epoch or speaker._pause.is_set()

        def waiter():
            if not self.queue.wait_turn(name, cancelled):
                return
            # Re-check under the Speaker's lock: pause() flips the flag
            # and pauses the player under it, so a resume that raced a
            # fresh pause can never audibly override it.
            with speaker._lock:
                if speaker._epoch == epoch and not speaker._pause.is_set():
                    speaker._play.resume()

        threading.Thread(target=waiter, daemon=True).start()

    def seek(self, name, delta=None, target=None):
        ch = self._acquire(name)
        try:
            result = ch.speaker.seek(delta=delta, target=target)
            if result is not None:
                # Re-queues content at the tail; a seek lines up but
                # never steals the turn from whoever holds it.
                self.queue.enqueue(name)
            return result
        finally:
            self._release(ch)

    def stop(self, name=None):
        if name is None:  # the hammer: all channels
            self.queue.clear()
            with self._lock:
                channels = list(self._channels.values())
            for ch in channels:
                ch.speaker.stop()
            return
        ch = self._acquire(name)
        try:
            ch.speaker.stop()
            self.queue.remove(name)
        finally:
            self._release(ch)

    def poll_begin(self, name, played=None):
        """Lookup and poll-mark in one locked step, returning the pinned
        channel: an outstanding poll blocks GC, so the store the caller
        long-polls can never belong to a deleted channel."""
        with self._lock:
            ch = self._channel_locked(name)
            ch.active_polls += 1
            ch.last_poll = self._clock()
        if played is not None and ch.store is not None:
            ch.store.report_played(played)
        self.queue.poke()
        return ch

    def poll_end(self, ch):
        with self._lock:
            ch.active_polls -= 1
            ch.last_poll = self._clock()
        self.queue.poke()

    def snapshot(self):
        """/health's channels dict. A client channel is speaking iff it
        has released segments not yet reported played and is not paused;
        the daemon-played local channel is speaking when its player is.

        "active" tells clients whether ANY content is unfinished. pending
        alone lies about a channel parked waiting for its playback turn:
        a mid-utterance batch and in-limbo popped segments sit in no
        queue, and released can be 0, so a waiting channel would read as
        finished and clients would tear their players down mid-read."""
        with self._lock:
            channels = dict(self._channels)
        out = {}
        for name, ch in channels.items():
            speaker = ch.speaker
            st = self._state(ch)
            if ch.store is not None:
                speaking = st["released"] > 0 and not st["paused"]
            else:
                speaking = speaker.speaking()
            active = (st["has_text"] or st["rendered"] > 0
                      or st["released"] > 0 or self.queue.queued(name))
            block = speaker.current_block()
            out[name] = {"pending": speaker.pending(), "speaking": speaking,
                         "paused": st["paused"],
                         "block": list(block) if block else None,
                         "active": active}
        return out

    def _kill(self, name):
        with self._lock:
            ch = self._channels.get(name)
        if ch is not None:
            ch.speaker.stop()

    def _maintain(self):
        # Timer tick: dead-client deadlines and GC must fire even when no
        # request arrives to poke the queue.
        while True:
            time.sleep(self._tick)
            # The janitor is load-bearing (dead-client deadlines, GC):
            # one bad tick must never end it for the daemon's lifetime,
            # so failures are logged and the next tick retries.
            try:
                self.queue.poke()
                self._gc()
            except Exception:
                traceback.print_exc()
                print("channel maintenance tick failed; retrying",
                      file=sys.stderr)

    def _gc(self):
        now = self._clock()
        dead = []
        with self._lock:
            for name, ch in list(self._channels.items()):
                # busy: a request holds this channel right now; deleting
                # under it is the race that strands its queued text.
                if (name == LOCAL_CHANNEL or ch.active_polls > 0
                        or ch.busy > 0):
                    continue
                last_seen = max(ch.last_used, ch.last_poll or 0.0)
                if now - last_seen <= self._gc_seconds:
                    continue
                if self._has_content(ch):
                    continue
                dead.append(ch)
                del self._channels[name]
        for ch in dead:
            self.queue.unregister(ch.name, ch.state_fn)
            ch.speaker.close()


@dataclass(frozen=True)
class _SynthesisState:
    context: VoiceContext
    effects: bool
    rate: float


@dataclass
class _ManagementOperation:
    id: str
    kind: str
    phase: str
    fingerprint: str = field(repr=False)
    target: str | None = None
    progress: object | None = None
    error: dict | None = None
    response: dict | None = None
    status: int = field(default=202, repr=False)
    done: threading.Event = field(
        default_factory=threading.Event, repr=False)

    def snapshot(self):
        result = {"id": self.id, "kind": self.kind, "phase": self.phase}
        if self.target is not None:
            result["target"] = self.target
        if self.progress is not None:
            result["progress"] = copy.deepcopy(self.progress)
        if self.error is not None:
            result["error"] = copy.deepcopy(self.error)
        if self.response is not None:
            result["response"] = copy.deepcopy(self.response)
        return result


class ManagementOperations:
    """Instance-local idempotency and single-mutation coordinator."""

    def __init__(self, changed=None):
        self._changed = changed or (lambda: None)
        self._lock = threading.RLock()
        self._records = {}
        self._active_id = None

    @staticmethod
    def fingerprint(method, path, body):
        canonical = json.dumps(
            body, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            allow_nan=False)
        return f"{method.upper()}\n{path}\n{canonical}"

    def _conflict(self, code, message, detail):
        raise ManagementFailure(
            code, message, detail=detail, recoverable=True, status=409)

    def _reserve(self, request_id, kind, method, path, body, target):
        fingerprint = self.fingerprint(method, path, body)
        with self._lock:
            existing = self._records.get(request_id)
            if existing is not None:
                if existing.fingerprint != fingerprint:
                    self._conflict(
                        "request_id_conflict",
                        "That request ID was already used for another action.",
                        {"request_id": request_id})
                return existing, True
            if self._active_id is not None:
                active = self._records[self._active_id]
                self._conflict(
                    "operation_busy",
                    "Another voice or settings action is still in progress.",
                    {"active_operation": active.snapshot()})
            operation = _ManagementOperation(
                request_id, kind, "pending", fingerprint, target=target)
            self._records[request_id] = operation
            self._active_id = request_id
        self._changed()
        return operation, False

    def _set_phase(self, operation, phase, *, progress=None):
        with self._lock:
            operation.phase = phase
            operation.progress = progress
        self._changed()

    @staticmethod
    def _safe_error(exc):
        if isinstance(exc, ManagementFailure):
            return exc.as_dict(), exc.status
        traceback.print_exc()
        return {
            "code": "management_internal_error",
            "message": "The daemon could not complete the action.",
            "detail": None,
            "recoverable": True,
        }, 500

    def _finish(self, operation, runner):
        try:
            self._set_phase(operation, "preparing")

            def transition(phase, progress=None):
                self._set_phase(operation, phase, progress=progress)

            response = copy.deepcopy(runner(operation.id, transition))
            with self._lock:
                operation.response = response
                operation.status = 200
                operation.phase = "succeeded"
                if self._active_id == operation.id:
                    self._active_id = None
                operation.done.set()
        except BaseException as exc:
            error, status = self._safe_error(exc)
            with self._lock:
                operation.error = copy.deepcopy(error)
                operation.status = status
                operation.phase = "failed"
                if self._active_id == operation.id:
                    self._active_id = None
                operation.done.set()
        self._changed()

    def submit(self, request_id, kind, method, path, body, target, runner):
        operation, replay = self._reserve(
            request_id, kind, method, path, body, target)
        if not replay:
            threading.Thread(
                target=self._finish, args=(operation, runner),
                name=f"management-{kind}", daemon=True).start()
        return operation.snapshot(), replay

    def execute(self, request_id, kind, method, path, body, target, runner):
        operation, replay = self._reserve(
            request_id, kind, method, path, body, target)
        if not replay:
            self._finish(operation, runner)
        else:
            operation.done.wait()
        with self._lock:
            return operation.snapshot(), operation.status, replay


    def active(self):
        with self._lock:
            operation = (self._records.get(self._active_id)
                         if self._active_id is not None else None)
            return operation.snapshot() if operation is not None else None

    def result(self, request_id):
        with self._lock:
            operation = self._records.get(request_id)
            return operation.snapshot() if operation is not None else None


class App:
    """Shared server state. speaker is attached once the model finishes
    loading, so the server can come up (and report status) immediately."""

    def __init__(self, model_id="", token=None, segments=None, *,
                 backend="auto", host=HOST, port=DEFAULT_PORT,
                 voices_dir=None, library=None, settings_store=None,
                 settings=None):
        self.instance_id = str(uuid.uuid4()).upper()
        self.started_at = (
            datetime.now(timezone.utc).isoformat(timespec="seconds")
            .replace("+00:00", "Z"))
        self.capabilities = [
            "state-v2", "voice-list", "voice-activate", "settings-v2",
            "staged-import", "segment-player",
        ]
        self.model_id = model_id
        self.backend = backend
        self.host = host
        self.port = port
        self.voices_dir = str(
            Path(voices_dir).expanduser().resolve()
            if voices_dir is not None else "")
        self.token = token
        self.segments = segments
        self.speaker = None
        self._startup_settings = settings or ProductSettings()
        self.library = library
        self.settings_store = settings_store
        self._state_lock = threading.RLock()
        self._revision = 1
        self._lifecycle = {"phase": "starting", "message": None}
        self._last_error = None
        self.operations = ManagementOperations(self._operation_changed)
        # Acceptance, settings commits, and active-context swaps linearize
        # on this one lock.
        self._synthesis_lock = threading.RLock()
        self._synthesis_state = None
        self.channels = None
        self.channel_opts = {}
        self._channels_lock = threading.Lock()

    def ensure_channels(self):
        with self._channels_lock:
            if self.channels is None and self.speaker is not None:
                self.channels = ChannelManager(self.speaker, self.segments,
                                               **self.channel_opts)
        return self.channels

    def _state_locked(self):
        state = self._synthesis_state
        if state is None:
            if self.speaker is None or not self.speaker.ready.is_set():
                raise RuntimeError("synthesis engine is not ready")
            settings = self._settings_snapshot()
            state = _SynthesisState(
                self.speaker._worker.context, settings["effects"],
                settings["default_synthesis_rate"])
            # The worker's startup-active pin is adopted by this state.
            self._synthesis_state = state
        return state

    def capture_synthesis_snapshot(self, rate=None):
        """Linearization point for one accepted /speak request."""
        with self._synthesis_lock:
            state = self._state_locked()
            snapshot = SynthesisSnapshot(
                state.context, state.effects,
                state.rate if rate is None else rate)
            self.speaker._worker.retain(snapshot.context)
            return snapshot

    def commit_synthesis_settings(self, rate=None, effects=None):
        """Atomically publish daemon defaults for future acceptances."""
        with self._synthesis_lock:
            state = self._state_locked()
            state = _SynthesisState(
                state.context,
                state.effects if effects is None else effects,
                state.rate if rate is None else rate)
            self._synthesis_state = state
            self.speaker.speed = state.rate
            if self.channels is not None:
                self.channels.set_speed(state.rate)

    def commit_synthesis_context(self, context):
        """Non-failing active pointer swap; caller owns pin transitions."""
        with self._synthesis_lock:
            old = self._state_locked()
            self._synthesis_state = _SynthesisState(
                context, old.effects, old.rate)
            self.speaker._worker._context = context
            return old.context

    def synthesis_settings(self):
        with self._synthesis_lock:
            state = self._state_locked()
            return state.rate, state.effects

    def is_profile_captured(self, profile_id):
        """Guard deletion while any preparation/state/work pin exists."""
        speaker = self.speaker
        if speaker is None or not speaker.ready.is_set():
            return False
        return speaker._worker.is_profile_pinned(profile_id)

    def _bump_revision(self):
        with self._state_lock:
            self._revision += 1

    def _operation_changed(self):
        self._bump_revision()

    def configure_storage(self, library, settings_store):
        with self._state_lock:
            self.library = library
            self.settings_store = settings_store
            self._revision += 1

    def set_lifecycle(self, phase, message=None, error=None):
        if phase not in {
                "starting", "loading", "ready", "degraded", "failed"}:
            raise ValueError(f"invalid lifecycle phase: {phase}")
        lifecycle = {"phase": phase, "message": message}
        with self._state_lock:
            if (lifecycle == self._lifecycle
                    and error == self._last_error):
                return
            self._lifecycle = lifecycle
            self._last_error = error
            self._revision += 1

    def meta_snapshot(self):
        return {
            "service": "wren",
            "protocol_version": 2,
            "instance_id": self.instance_id,
            "started_at": self.started_at,
            "capabilities": list(self.capabilities),
        }

    @staticmethod
    def _snapshot_value(value):
        if isinstance(value, dict):
            return dict(value)
        if hasattr(value, "to_dict"):
            return value.to_dict()
        try:
            return asdict(value)
        except TypeError:
            return value

    def voices_snapshot(self):
        library = self.library
        if library is None:
            return {"revision": 0, "voices": []}
        snapshot = library.snapshot()
        if isinstance(snapshot, dict):
            return snapshot
        voices = [
            self._snapshot_value(voice)
            for voice in snapshot.voices
        ]
        return {"revision": snapshot.revision, "voices": voices}

    def _settings_snapshot(self):
        store = self.settings_store
        if store is None:
            settings = self._startup_settings.as_dict()
            if self._synthesis_state is not None:
                settings.update(
                    active_voice=(
                        self._synthesis_state.context.profile.id),
                    effects=self._synthesis_state.effects,
                    default_synthesis_rate=self._synthesis_state.rate,
                )
            return settings
        settings = store.snapshot()
        return self._snapshot_value(settings)

    def _engine_failure(self):
        speaker = self.speaker
        if speaker is None or not speaker.ready.is_set():
            return None
        health = speaker._worker.health()
        if health.usable:
            return None
        raw = health.error if isinstance(health.error, dict) else {}
        detail = raw or {"engine_error": repr(health.error)}
        return {
            "code": raw.get("code", "engine_unavailable"),
            "message": "The synthesis engine is unavailable.",
            "detail": detail,
            "recoverable": True,
        }

    def _playback_snapshot(self, ready):
        speaker = self.speaker
        if not ready or speaker is None:
            return {"pending": 0, "speaking": False, "paused": False}
        manager = self.channels
        if manager is None:
            return {
                "pending": speaker.pending(),
                "speaking": speaker.speaking(),
                "paused": speaker.paused(),
            }
        channels = manager.snapshot()
        local = channels.get(LOCAL_CHANNEL, {})
        return {
            "pending": sum(channel["pending"]
                           for channel in channels.values()),
            "speaking": any(channel["speaking"]
                            for channel in channels.values()),
            "paused": bool(local.get("paused", False)),
        }

    def state_snapshot(self, *, include_operation=True):
        engine_error = self._engine_failure()
        if engine_error is not None:
            self.set_lifecycle(
                "degraded", "The synthesis engine is unavailable.",
                engine_error)
        with self._synthesis_lock:
            speaker_ready = (
                self.speaker is not None and self.speaker.ready.is_set()
                and engine_error is None)
            if speaker_ready and self._synthesis_state is None:
                self._state_locked()
            settings = self._settings_snapshot()
            active_voice = None
            if speaker_ready and self._synthesis_state is not None:
                active_voice = self._synthesis_state.context.profile.id
                effects = self._synthesis_state.effects
                rate = self._synthesis_state.rate
            else:
                effects = settings["effects"]
                rate = settings["default_synthesis_rate"]
            synthesis = {
                "ready": speaker_ready,
                "active_voice": active_voice,
                "effects": effects,
                "default_synthesis_rate": rate,
                "backend": self.backend,
                "model": self.model_id,
                "host": self.host,
                "port": self.port,
                "voices_dir": self.voices_dir,
            }
        voices_revision = self.voices_snapshot()["revision"]
        with self._state_lock:
            return {
                "revision": self._revision,
                "voices_revision": voices_revision,
                "lifecycle": dict(self._lifecycle),
                "synthesis": synthesis,
                "operation": (
                    self.operations.active() if include_operation else None),
                "playback": self._playback_snapshot(speaker_ready),
                "last_error": (
                    dict(self._last_error)
                    if self._last_error is not None else None),
            }

    def activate_voice_runner(self, voice_id):
        def run(operation_id, transition):
            del operation_id
            profile = self.library.resolve_ready(voice_id)
            speaker = self.speaker
            if speaker is None or not speaker.ready.is_set():
                raise ManagementFailure(
                    "engine_not_ready",
                    "The synthesis engine is not ready.",
                    recoverable=True, status=503)
            worker = speaker._worker
            try:
                prepared = worker.prepare(profile)
            except ManagementFailure:
                raise
            except BaseException as exc:
                raise ManagementFailure(
                    "voice_prepare_failed",
                    f"{profile.display_name} could not be prepared.",
                    detail=repr(exc), recoverable=True, status=500) from exc
            with self._synthesis_lock:
                transition("committing")
                activate_voice(
                    profile, lambda ignored: prepared,
                    lambda ignored: self.settings_store.set_active_voice(
                        voice_id),
                    self.commit_synthesis_context,
                    worker.retain, worker.release)
                self._bump_revision()
            return self.state_snapshot()
        return run

    def import_voice_runner(self, staging_id, voice_id, display_name):
        def run(operation_id, transition):
            transition("committing")
            self.library.import_staged(
                staging_id, voice_id, display_name, operation_id)
            self._bump_revision()
            return self.voices_snapshot()
        return run

    def update_voice_runner(self, voice_id, display_name):
        def run(operation_id, transition):
            del operation_id
            transition("committing")
            self.library.update_metadata(voice_id, display_name)
            self._bump_revision()
            return self.voices_snapshot()
        return run

    def delete_voice_runner(self, voice_id):
        def run(operation_id, transition):
            active = self._settings_snapshot().get("active_voice")
            transition("committing")
            self.library.delete(
                voice_id, operation_id, active_voice=active,
                is_captured=self.is_profile_captured)
            self._bump_revision()
            return self.voices_snapshot()
        return run

    def settings_runner(self, changes):
        def run(operation_id, transition):
            del operation_id
            transition("committing")
            with self._synthesis_lock:
                settings = self.settings_store.update(**changes)
                rate = settings.default_synthesis_rate
                effects = settings.effects
                if self.speaker is not None and self.speaker.ready.is_set():
                    self.commit_synthesis_settings(
                        rate=rate, effects=effects)
                self._bump_revision()
            return self.state_snapshot(include_operation=False)
        return run


class _Handler(BaseHTTPRequestHandler):
    app = None  # injected via make_server

    def log_message(self, *args):
        pass

    def _json(self, code, obj, *, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _is_v2_path(self):
        path = urlsplit(self.path).path
        return (
            path in {"/meta", "/state", "/voices", "/settings"}
            or path.startswith("/voices/")
            or path.startswith("/operations/"))

    def _v2_error(self, failure):
        self._json(failure.status, {"error": failure.as_dict()})

    def _route_failure(self, code, message, *, status=400, detail=None):
        self._v2_error(ManagementFailure(
            code, message, detail=detail, recoverable=True, status=status))

    @staticmethod
    def _reject_json_constant(value):
        raise ValueError(f"non-finite JSON number: {value}")

    @classmethod
    def _reject_nonfinite(cls, value):
        if isinstance(value, float):
            if not math.isfinite(value):
                raise ValueError("non-finite JSON number")
            return
        if isinstance(value, dict):
            for child in value.values():
                cls._reject_nonfinite(child)
        elif isinstance(value, list):
            for child in value:
                cls._reject_nonfinite(child)

    def _management_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._route_failure(
                "request_content_length_invalid",
                "The request Content-Length is invalid.")
            return None
        if length < 0 or length > MAX_BODY_BYTES:
            remaining = min(max(length, 0), 8 * MAX_BODY_BYTES)
            while remaining:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
            self._route_failure(
                "request_body_too_large",
                "The request body is too large.", status=413)
            return None
        try:
            body = json.loads(
                self.rfile.read(length) or b"{}",
                parse_constant=self._reject_json_constant)
            self._reject_nonfinite(body)
        except (ValueError, json.JSONDecodeError):
            self._route_failure(
                "request_json_invalid",
                "The request body is not valid JSON.")
            return None
        if not isinstance(body, dict):
            self._route_failure(
                "request_body_invalid",
                "The request body must be a JSON object.")
            return None
        return body

    def _request_id(self):
        request_id = self.headers.get("Idempotency-Key", "")
        if request_id.strip():
            return request_id
        self._route_failure(
            "idempotency_key_required",
            "A nonempty Idempotency-Key header is required.")
        return None

    @staticmethod
    def _validate_body(body, allowed, required=()):
        unknown = sorted(set(body) - set(allowed))
        missing = sorted(set(required) - set(body))
        if unknown:
            raise ManagementFailure(
                "request_field_unknown",
                "The request contains an unknown field.",
                detail={"fields": unknown}, recoverable=True, status=400)
        if missing:
            raise ManagementFailure(
                "request_field_required",
                "The request is missing a required field.",
                detail={"fields": missing}, recoverable=True, status=400)

    @staticmethod
    def _voice_id(value, field_name="voice"):
        if (not isinstance(value, str)
                or CHANNEL_NAME_RE.fullmatch(value) is None):
            raise ManagementFailure(
                "voice_id_invalid",
                "The voice ID must use lowercase letters, digits, _ or -.",
                detail={"field": field_name}, recoverable=True, status=400)
        return value

    @staticmethod
    def _display_name(value):
        if not isinstance(value, str) or not value.strip():
            raise ManagementFailure(
                "voice_display_name_invalid",
                "The voice display name must not be empty.",
                detail={"field": "display_name"},
                recoverable=True, status=400)
        return value.strip()

    def _management_get(self, path):
        if path == "/meta":
            self._json(200, self.app.meta_snapshot())
            return
        if path == "/state":
            self._json(200, self.app.state_snapshot())
            return
        if path == "/voices":
            self._json(200, self.app.voices_snapshot())
            return
        if path.startswith("/operations/"):
            request_id = unquote(path[len("/operations/"):])
            operation = self.app.operations.result(request_id)
            if operation is None:
                raise ManagementFailure(
                    "operation_result_unknown",
                    "No operation with that ID exists in this daemon "
                    "instance.",
                    detail={"request_id": request_id},
                    recoverable=True, status=404)
            self._json(200, operation)
            return
        raise ManagementFailure(
            "route_not_found",
            "The management route does not exist.",
            recoverable=True, status=404)

    def _origin_allowed(self):
        origin = self.headers.get("Origin", "")
        if not origin or origin.startswith(ALLOWED_ORIGIN_SCHEMES):
            return True
        if self._is_v2_path():
            self._route_failure(
                "origin_not_allowed",
                "This browser Origin is not allowed.", status=403)
        else:
            self._json(403, {"error": "origin not allowed"})
        return False

    def _authorized(self):
        token = self.app.token
        if not token:
            return True
        supplied = self.headers.get("Authorization", "")
        if hmac.compare_digest(supplied, f"Bearer {token}"):
            return True
        if self._is_v2_path():
            self._route_failure(
                "authorization_required",
                "A valid bearer token is required.", status=401)
        else:
            self._json(401, {"error": "unauthorized"})
        return False

    @staticmethod
    def _management_methods(path):
        if path in {"/meta", "/state", "/voices"}:
            return ("GET",)
        if path == "/settings":
            return ("PATCH",)
        if path.startswith("/operations/"):
            return ("GET",)
        if path in {"/voices/activate", "/voices/import"}:
            return ("POST",)
        if path.startswith("/voices/"):
            return ("PATCH", "DELETE")
        return ()

    def _management_exception(self, exc):
        if isinstance(exc, ManagementFailure):
            self._v2_error(exc)
            return
        traceback.print_exception(type(exc), exc, exc.__traceback__)
        self._route_failure(
            "internal_error",
            "The daemon could not process the management request.",
            status=500)

    def _method_not_allowed(self, allowed):
        self._json(
            405,
            {"error": {
                "code": "method_not_allowed",
                "message": "The HTTP method is not allowed for this route.",
                "detail": None,
                "recoverable": True,
            }},
            headers={"Allow": ", ".join(allowed)})

    def _dispatch_management(self, method, path):
        if not self._is_v2_path():
            return False
        try:
            if not self._origin_allowed() or not self._authorized():
                return True
            allowed = self._management_methods(path)
            if method not in allowed:
                self._method_not_allowed(allowed)
            elif method == "GET":
                self._management_get(path)
            else:
                self._management_mutation(method, path)
        except Exception as exc:
            self._management_exception(exc)
        return True

    def _unsupported_method(self):
        path = urlsplit(self.path).path
        if self._dispatch_management(self.command, path):
            return
        if not self._origin_allowed() or not self._authorized():
            return
        self._method_not_allowed(("GET", "POST"))

    def send_error(self, code, message=None, explain=None):
        if int(code) == 501:
            self._unsupported_method()
            return
        super().send_error(code, message, explain)

    def _accept_speak(self, mgr, speaker, channel, speed, **kwargs):
        """Capture exactly once, then transfer that pin to the queue."""
        snapshot = self.app.capture_synthesis_snapshot(rate=speed)
        try:
            if mgr is not None:
                return mgr.speak(
                    channel or LOCAL_CHANNEL, snapshot=snapshot, **kwargs)
            return speaker.speak(snapshot=snapshot, **kwargs)
        except BaseException:
            speaker._worker.release(snapshot.context, wait=False)
            raise

    def _segment(self, query):
        channel = query.get("channel", [None])[0]
        if channel is not None and CHANNEL_NAME_RE.fullmatch(channel) is None:
            self._json(400, {"error": "invalid channel name"})
            return
        try:
            after = int(query.get("after", ["0"])[0])
            timeout = min(float(
                query.get("timeout", [str(SEGMENT_POLL_TIMEOUT)])[0]),
                MAX_POLL_TIMEOUT)
            played = query.get("played", [None])[0]
            played = int(played) if played is not None else None
        except ValueError:
            self._json(400, {"error": "after/timeout/played must be numeric"})
            return
        mgr = self.app.channels
        if mgr is None and channel is not None:
            mgr = self.app.ensure_channels()
        if mgr is None:
            # Pre-channels server (or model still loading): the local
            # stream exists only under client playback, exactly as before.
            store = self.app.segments
            if store is None:
                self._json(404, {"error": "server-side playback; start the "
                                          "daemon with --local-player "
                                          "client"})
                return
            seq, block, data, epoch = store.next_after(after, timeout)
        else:
            # poll_begin looks up and pins in one step: a bare channel()
            # lookup here could hand back an object GC deletes before
            # the poll marks it in use.
            ch = mgr.poll_begin(channel or LOCAL_CHANNEL, played)
            try:
                if ch.store is None:  # daemon-played local has no stream
                    self._json(404, {"error": "server-side playback; "
                                              "start the daemon with "
                                              "--local-player client"})
                    return
                seq, block, data, epoch = ch.store.next_after(after, timeout)
            finally:
                mgr.poll_end(ch)
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

    def _management_mutation(self, method, path):
        body = self._management_body()
        if body is None:
            return
        request_id = self._request_id()
        if request_id is None:
            return
        try:
            if self.app.library is None or self.app.settings_store is None:
                raise ManagementFailure(
                    "storage_not_ready",
                    "Voice storage is not ready.",
                    recoverable=True, status=503)
            if method == "POST" and path == "/voices/activate":
                self._validate_body(body, {"voice"}, {"voice"})
                voice_id = self._voice_id(body["voice"])
                operation, _ = self.app.operations.submit(
                    request_id, "activate_voice", method, path, body,
                    voice_id, self.app.activate_voice_runner(voice_id))
                self._json(202, operation)
                return
            if method == "POST" and path == "/voices/import":
                self._validate_body(
                    body, {"staging_id", "id", "display_name"},
                    {"staging_id", "id", "display_name"})
                staging_id = self._voice_id(
                    body["staging_id"], "staging_id")
                voice_id = self._voice_id(body["id"], "id")
                display_name = self._display_name(body["display_name"])
                operation, _ = self.app.operations.submit(
                    request_id, "import_voice", method, path, body,
                    voice_id, self.app.import_voice_runner(
                        staging_id, voice_id, display_name))
                self._json(202, operation)
                return
            if method == "PATCH" and path.startswith("/voices/"):
                voice_id = self._voice_id(
                    unquote(path[len("/voices/"):]), "id")
                self._validate_body(
                    body, {"display_name"}, {"display_name"})
                display_name = self._display_name(body["display_name"])
                operation, _ = self.app.operations.submit(
                    request_id, "update_voice", method, path, body,
                    voice_id, self.app.update_voice_runner(
                        voice_id, display_name))
                self._json(202, operation)
                return
            if method == "DELETE" and path.startswith("/voices/"):
                voice_id = self._voice_id(
                    unquote(path[len("/voices/"):]), "id")
                self._validate_body(body, set())
                operation, _ = self.app.operations.submit(
                    request_id, "delete_voice", method, path, body,
                    voice_id, self.app.delete_voice_runner(voice_id))
                self._json(202, operation)
                return
            if method == "PATCH" and path == "/settings":
                allowed = {"effects", "default_synthesis_rate"}
                self._validate_body(body, allowed)
                if not body:
                    raise ManagementFailure(
                        "request_field_required",
                        "At least one settings field is required.",
                        detail={"fields": sorted(allowed)},
                        recoverable=True, status=400)
                operation, status, _ = self.app.operations.execute(
                    request_id, "update_settings", method, path, body,
                    None, self.app.settings_runner(body))
                if operation["phase"] == "failed":
                    self._json(status, {"error": operation["error"]})
                else:
                    self._json(status, operation["response"])
                return
            raise ManagementFailure(
                "route_not_found",
                "The management route does not exist.",
                recoverable=True, status=404)
        except ManagementFailure as failure:
            self._v2_error(failure)

    def do_GET(self):
        url = urlsplit(self.path)
        if self._dispatch_management("GET", url.path):
            return
        if not self._origin_allowed() or not self._authorized():
            return
        if url.path == "/health":
            speaker = self.app.speaker
            loaded = speaker is not None and speaker.ready.is_set()
            engine_health = (speaker._worker.health() if loaded else None)
            ready = loaded and engine_health.usable
            payload = {
                "ok": True,
                "ready": ready,
                "model": self.app.model_id,
                "playback": "client" if self.app.segments else "local",
                "pending": speaker.pending() if ready else 0,
                "speaking": speaker.speaking() if ready else False,
                "paused": speaker.paused() if ready else False,
                "block": list(speaker.current_block())
                         if ready and speaker.current_block() else None,
                "speed": speaker.speed if ready else None,
            }
            if engine_health is not None and not engine_health.usable:
                payload["engine_error"] = engine_health.error
            mgr = self.app.channels
            if ready and mgr is not None:
                channels = mgr.snapshot()
                local = channels[LOCAL_CHANNEL]
                payload.update(
                    pending=sum(c["pending"] for c in channels.values()),
                    speaking=any(c["speaking"] for c in channels.values()),
                    paused=local["paused"],
                    block=local["block"],
                    channels=channels,
                )
            elif ready:
                payload["channels"] = {LOCAL_CHANNEL: {
                    "pending": payload["pending"],
                    "speaking": payload["speaking"],
                    "paused": payload["paused"],
                    "block": payload["block"],
                    "active": (payload["pending"] > 0
                               or payload["speaking"]),
                }}
            self._json(200, payload)
        elif url.path == "/segment":
            self._segment(parse_qs(url.query))
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlsplit(self.path).path
        if self._dispatch_management("POST", path):
            return
        if not self._origin_allowed() or not self._authorized():
            return
        speaker = self.app.speaker
        if speaker is None or not speaker.ready.is_set():
            self._json(503, {"error": "model still loading"})
            return
        if self.path == "/speak":
            engine_health = speaker._worker.health()
            if not engine_health.usable:
                self._json(503, {"error": engine_health.error})
                return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._json(400, {"error": "invalid Content-Length"})
            return
        if length < 0 or length > MAX_BODY_BYTES:
            # Drain (bounded, discarded in chunks) before responding, else
            # the close mid-upload turns into a RST and the client sees a
            # connection reset instead of the 413.
            remaining = min(length, 8 * MAX_BODY_BYTES)
            while remaining > 0:
                read = self.rfile.read(min(remaining, 65536))
                if not read:
                    break
                remaining -= len(read)
            self._json(413, {"error": "body too large"})
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "invalid JSON"})
            return
        if not isinstance(body, dict):
            self._json(400, {"error": "body must be a JSON object"})
            return
        channel = body.get("channel")
        if channel is not None and (
                not isinstance(channel, str)
                or CHANNEL_NAME_RE.fullmatch(channel) is None):
            self._json(400, {"error": "invalid channel name"})
            return
        # Channel routing engages on first channelled request; until then
        # the pre-channels code paths serve no-channel requests unchanged.
        mgr = self.app.channels
        if mgr is None and channel is not None:
            mgr = self.app.ensure_channels()
        if self.path == "/stop":
            if mgr is not None:
                mgr.stop(channel)  # no channel: the hammer, all channels
            else:
                speaker.stop()
            self._json(200, {"ok": True})
            return
        if self.path == "/seek":
            if "block" in body:
                block = body["block"]
                if not isinstance(block, int) or isinstance(block, bool):
                    self._json(400, {"error": "block must be an integer"})
                    return
                delta = None
            else:
                block = None
                delta = body.get("delta", 1)
                if (not isinstance(delta, int) or isinstance(delta, bool)
                        or delta == 0):
                    self._json(
                        400, {"error": "delta must be a non-zero integer"})
                    return
            if mgr is not None:
                target = mgr.seek(channel or LOCAL_CHANNEL,
                                  delta=delta, target=block)
            else:
                target = speaker.seek(delta=delta, target=block)
            if target is None:
                self._json(200, {"ok": False, "error": "nothing to seek"})
            else:
                self._json(200, {"ok": True, "block": target})
            return
        if self.path == "/pause":
            if mgr is not None:
                paused = mgr.pause(channel or LOCAL_CHANNEL)
            else:
                speaker.pause()
                paused = speaker.paused()
            self._json(200, {"ok": True, "paused": paused})
            return
        if self.path == "/resume":
            if mgr is not None:
                paused = mgr.resume(channel or LOCAL_CHANNEL)
            else:
                speaker.resume()
                paused = speaker.paused()
            self._json(200, {"ok": True, "paused": paused})
            return
        if self.path != "/speak":
            self._json(404, {"error": "not found"})
            return
        append = bool(body.get("append"))
        speed = body.get("speed")
        if speed is not None:
            if (not isinstance(speed, (int, float)) or isinstance(speed, bool)
                    or not SPEED_MIN <= speed <= SPEED_MAX):
                self._json(400, {"error": "speed must be a number in "
                                          f"[{SPEED_MIN}, {SPEED_MAX}]"})
                return
            speed = float(speed)
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
            queued = self._accept_speak(
                mgr, speaker, channel, speed, blocks=indexed,
                append=append)
            self._json(200, {"queued": queued})
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
        queued = self._accept_speak(
            mgr, speaker, channel, speed, text=text, append=append)
        self._json(200, {"queued": queued})

    def do_PATCH(self):
        path = urlsplit(self.path).path
        if self._dispatch_management("PATCH", path):
            return
        if not self._origin_allowed() or not self._authorized():
            return
        self._json(404, {"error": "not found"})

    def do_DELETE(self):
        path = urlsplit(self.path).path
        if self._dispatch_management("DELETE", path):
            return
        if not self._origin_allowed() or not self._authorized():
            return
        self._json(404, {"error": "not found"})


def make_server(app, port=DEFAULT_PORT, host=HOST):
    _require_management_token(host, app.token)
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


def _effect_paths(paths, enabled, ring_freq, ring_mix):
    if not enabled:
        yield from paths
        return
    import soundfile as sf
    from fx import DroidFX

    fx = DroidFX(ring_freq=ring_freq, ring_mix=ring_mix)
    for path in paths:
        audio, sr = sf.read(path, dtype="float32")
        if audio.ndim == 2:
            audio = audio.T
        processed = fx.process(audio, sr)
        sf.write(
            path, processed.T if processed.ndim == 2 else processed, sr)
        yield path


class _ResidentEngine(SynthesisEngine):
    """Shared lifecycle for in-process resident models."""

    def __init__(self, backend, ring_freq=40.0, ring_mix=0.12):
        self.backend = backend
        self._owner = threading.get_ident()
        self._pins = {}
        self._closed = False
        self._ring_freq = ring_freq
        self._ring_mix = ring_mix

    def _check_owner(self):
        if threading.get_ident() != self._owner:
            raise RuntimeError(
                f"{self.backend} engine accessed outside its SynthWorker")
        if self._closed:
            raise RuntimeError(f"{self.backend} engine is closed")

    def _context(self, profile, data, digest):
        context = VoiceContext(
            profile=profile, data=data,
            identity=(self.backend, digest))
        self._pins[id(context)] = 1
        return context

    def retain(self, context):
        self._check_owner()
        key = id(context)
        pins = self._pins.get(key)
        if pins is None:
            raise RuntimeError("cannot retain a released voice context")
        self._pins[key] = pins + 1

    def release(self, context):
        self._check_owner()
        key = id(context)
        pins = self._pins.get(key)
        if pins is None or pins <= 0:
            raise RuntimeError("voice context pin underflow")
        if pins == 1:
            del self._pins[key]
            self._released(context)
        else:
            self._pins[key] = pins - 1

    def _released(self, context):
        pass

    def _effects(self, paths, enabled):
        yield from _effect_paths(
            paths, enabled, self._ring_freq, self._ring_mix)

    def health(self):
        self._check_owner()
        return EngineHealth(usable=True)

    def close(self):
        self._check_owner()
        self._pins.clear()
        self._closed = True


def _profile_digest(profile, audio):
    """Stable identity for conditioning content, independent of its path."""
    import hashlib

    transcript = profile.transcript.encode("utf-8")
    digest = hashlib.sha256()
    digest.update(b"wren-voice-context-v1\0")
    digest.update(len(audio).to_bytes(8, "big"))
    digest.update(audio)
    digest.update(len(transcript).to_bytes(8, "big"))
    digest.update(transcript)
    return digest.hexdigest()


def _read_profile_audio(profile):
    if not profile.transcript.strip():
        raise ValueError("voice transcript must not be empty")
    if profile.audio is not None:
        return profile.audio
    path = Path(profile.audio_path)
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError("voice audio is not a regular file")
        if info.st_size > MAX_REFERENCE_WAV_BYTES:
            raise ManagementFailure(
                "voice_audio_too_large",
                f"{profile.display_name} reference audio is too large.",
                detail={
                    "size": info.st_size,
                    "limit": MAX_REFERENCE_WAV_BYTES,
                },
                status=422)
        payload = bytearray()
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            if len(payload) + len(chunk) > MAX_REFERENCE_WAV_BYTES:
                raise ManagementFailure(
                    "voice_audio_too_large",
                    f"{profile.display_name} reference audio is too large.",
                    detail={"limit": MAX_REFERENCE_WAV_BYTES},
                    status=422)
            payload.extend(chunk)
        audio = bytes(payload)
    except ManagementFailure:
        raise
    except OSError as exc:
        raise ValueError(f"cannot read voice audio {path}: {exc}") from exc
    finally:
        if fd is not None:
            os.close(fd)
    if (len(audio) < 12 or audio[:4] != b"RIFF"
            or audio[8:12] != b"WAVE"):
        raise ValueError(f"voice audio is not a WAV file: {path}")
    return audio


class QwenTTSEngine(_ResidentEngine):
    """Resident PyTorch Qwen engine with immutable captured references."""

    def __init__(self, model_id, language, device="auto",
                 ring_freq=40.0, ring_mix=0.12):
        super().__init__("qwen-tts", ring_freq, ring_mix)
        import torch
        from qwen_tts import Qwen3TTSModel
        from progress_bar import attach_progress_bar

        self._sf = __import__("soundfile")
        self._language = language
        device = resolve_device(device)
        print(f"device: {device}")
        if device == "cpu":
            dtype = torch.float32
        elif device == "cuda" and torch.cuda.get_device_capability()[0] < 8:
            dtype = torch.float16
        else:
            dtype = torch.bfloat16
        self._model = Qwen3TTSModel.from_pretrained(
            model_id,
            device_map=device,
            dtype=dtype,
            attn_implementation="sdpa",
        )
        attach_progress_bar(self._model)

    def prepare(self, profile):
        self._check_owner()
        encoded = _read_profile_audio(profile)
        try:
            audio, sample_rate = self._sf.read(
                io.BytesIO(encoded), dtype="float32")
        except Exception as exc:
            raise ValueError(
                f"cannot decode captured voice audio: {exc}") from exc
        if getattr(audio, "size", 0) == 0:
            raise ValueError("voice audio contains no samples")
        data = ((audio, sample_rate), profile.transcript)
        return self._context(
            profile, data, _profile_digest(profile, encoded))

    def synthesize(self, context, text, make_path, effects=False):
        self._check_owner()
        ref_audio, ref_text = context.data

        def generate():
            wavs, sr = self._model.generate_voice_clone(
                text=text,
                language=self._language,
                ref_audio=ref_audio,
                ref_text=ref_text,
            )
            path = make_path()
            self._sf.write(path, wavs[0], sr)
            yield path

        yield from self._effects(generate(), effects)


class MLXEngine(_ResidentEngine):
    """Resident MLX model; loading and conditioning stay on its owner thread."""

    def __init__(self, model_id, language,
                 ring_freq=40.0, ring_mix=0.12):
        super().__init__("mlx", ring_freq, ring_mix)
        import numpy as np
        import soundfile as sf
        from mlx_audio.tts.utils import load_model
        from mlx_audio.utils import load_audio

        self._np = np
        self._sf = sf
        self._load_audio = load_audio
        self._language = language
        self._model = load_model(model_id)
        self._embedding_cache = {}
        self._extract_embedding = getattr(
            self._model, "extract_speaker_embedding", None)
        if self._extract_embedding is not None:
            original = self._extract_embedding

            def cached_embedding(audio):
                cached = self._embedding_cache.get(id(audio))
                if cached is not None:
                    return cached
                return original(audio)

            self._model.extract_speaker_embedding = cached_embedding

    def prepare(self, profile):
        self._check_owner()
        encoded = _read_profile_audio(profile)
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav") as captured:
                captured.write(encoded)
                captured.flush()
                audio = self._load_audio(
                    captured.name, sample_rate=self._model.sample_rate)
        except Exception as exc:
            raise ValueError(
                f"cannot decode captured voice audio: {exc}") from exc
        if getattr(audio, "size", 0) == 0:
            raise ValueError("voice audio contains no samples")
        if self._extract_embedding is not None:
            self._embedding_cache[id(audio)] = self._extract_embedding(audio)
        data = (audio, profile.transcript)
        return self._context(
            profile, data, _profile_digest(profile, encoded))

    def _released(self, context):
        audio, _ = context.data
        self._embedding_cache.pop(id(audio), None)

    def synthesize(self, context, text, make_path, effects=False):
        self._check_owner()
        ref_audio, ref_text = context.data
        max_tokens = max(32, estimate_frames(text) * 2)

        def generate():
            cap_samples = None
            emitted = 0
            for result in self._model.generate(
                text=text,
                ref_audio=ref_audio,
                ref_text=ref_text,
                max_tokens=max_tokens,
                stream=True,
                streaming_interval=1.0,
            ):
                audio = self._np.asarray(result.audio)
                if audio.size == 0:
                    continue
                sr = getattr(result, "sample_rate", 24000)
                cap_samples = (max_tokens - 1) * sr / 12.5
                emitted += audio.size
                path = make_path()
                self._sf.write(path, audio, sr)
                yield path
            if cap_samples is not None and emitted >= cap_samples:
                print(
                    f"warning: hit token cap ({max_tokens}); output may be "
                    f"truncated babble for: {text[:60]!r}",
                    file=sys.stderr)

        yield from self._effects(generate(), effects)


@dataclass
class _QwenttsRegistration:
    pins: int
    last_used: int


# qwentts is a single resident child. Kept for signal/atexit cleanup and for
# startup error paths that cannot yet hold the engine instance.
_qwentts_process: subprocess.Popen | None = None


def _pick_free_port():
    """Bind an ephemeral localhost port and return its number."""
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _cleanup_qwentts():
    """Terminate the resident tts-server child if it is still running."""
    global _qwentts_process
    process, _qwentts_process = _qwentts_process, None
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


class QwenttsEngine(SynthesisEngine):
    """Resident qwentts child with content-addressed, explicitly pinned voices."""

    CACHE_LIMIT = 16
    SAMPLE_RATE = 24000
    SEGMENT_BYTES = SAMPLE_RATE * 2

    def __init__(self, qwentts_bin, qwentts_model, qwentts_codec,
                 qwentts_port, language, ring_freq=40.0, ring_mix=0.12,
                 startup_timeout=60):
        global _qwentts_process
        import atexit
        import urllib.error
        import urllib.request

        if not all([
                qwentts_bin, qwentts_model, qwentts_codec, qwentts_port]):
            raise RuntimeError(
                "qwentts backend requires --qwentts-bin, --qwentts-model, "
                "--qwentts-codec, and --qwentts-port")
        self._owner = threading.get_ident()
        self._urllib_error = urllib.error
        self._urllib_request = urllib.request
        self._base_url = f"http://127.0.0.1:{qwentts_port}"
        self._ring_freq = ring_freq
        self._ring_mix = ring_mix
        self._registrations = {}
        self._clock = 0
        self._closed = False
        self._failure = None
        self._state_lock = threading.Lock()
        self._monitor_stop = threading.Event()

        cmd = [
            str(qwentts_bin),
            "--model", str(qwentts_model),
            "--codec", str(qwentts_codec),
            "--host", "127.0.0.1",
            "--port", str(qwentts_port),
            "--lang", language,
        ]
        print(f"starting tts-server on 127.0.0.1:{qwentts_port}")
        self._process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL)
        _qwentts_process = self._process
        atexit.register(_cleanup_qwentts)
        if not self._wait_ready(startup_timeout):
            exited = self._process.poll() is not None
            self.close()
            raise RuntimeError(
                "tts-server exited during startup (see its stderr above)"
                if exited else
                f"tts-server did not become ready on port {qwentts_port} "
                f"within {startup_timeout}s")
        print(f"tts-server ready on port {qwentts_port}")
        threading.Thread(
            target=self._monitor_child, name="qwentts-monitor",
            daemon=True).start()

    def _wait_ready(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                return False
            try:
                response = self._urllib_request.urlopen(
                    f"{self._base_url}/health", timeout=1)
                response.read()
                response.close()
                return True
            except OSError:
                time.sleep(0.2)
        return False

    def _monitor_child(self):
        while not self._monitor_stop.wait(0.1):
            returncode = self._process.poll()
            if returncode is not None:
                self._mark_child_exit(returncode)
                return

    def _mark_child_exit(self, returncode=None):
        if returncode is None:
            returncode = self._process.poll()
        if returncode is None:
            return False
        with self._state_lock:
            if self._failure is None and not self._closed:
                self._failure = {
                    "code": "engine_child_exited",
                    "message": "qwentts tts-server exited unexpectedly",
                    "exit_code": returncode,
                }
        return True

    def _check_owner(self):
        if threading.get_ident() != self._owner:
            raise RuntimeError(
                "qwentts engine accessed outside its SynthWorker")
        if self._closed:
            raise RuntimeError("qwentts engine is closed")

    def _ensure_healthy(self):
        self._check_owner()
        self._mark_child_exit()
        with self._state_lock:
            failure = self._failure
        if failure is not None:
            raise RuntimeError(failure["message"])

    def _touch(self, registration):
        self._clock += 1
        registration.last_used = self._clock

    def _voice_key(self, profile, audio):
        return f"wren-{_profile_digest(profile, audio)}"

    def _request(self, path, body=None, method="GET", timeout=30):
        self._ensure_healthy()
        request = self._urllib_request.Request(
            f"{self._base_url}{path}", data=body,
            headers={"Content-Type": "application/json"},
            method=method)
        try:
            response = self._urllib_request.urlopen(request, timeout=timeout)
            payload = response.read()
            response.close()
            self._mark_child_exit()
            return payload
        except OSError as exc:
            if self._mark_child_exit():
                raise RuntimeError(
                    "qwentts tts-server exited unexpectedly") from exc
            raise RuntimeError(f"qwentts request failed: {exc}") from exc

    def prepare(self, profile):
        self._ensure_healthy()
        import base64

        audio = _read_profile_audio(profile)
        key = self._voice_key(profile, audio)
        registration = self._registrations.get(key)
        if registration is None:
            body = json.dumps({
                "name": key,
                "ref_text": profile.transcript,
                "wav_b64": base64.b64encode(audio).decode("ascii"),
            }).encode("utf-8")
            try:
                self._request(
                    "/v1/audio/voices", body=body, method="POST", timeout=30)
            except Exception as exc:
                raise RuntimeError(
                    f"failed to register qwentts voice {profile.id}: {exc}"
                ) from exc
            registration = _QwenttsRegistration(pins=1, last_used=0)
            self._registrations[key] = registration
        else:
            registration.pins += 1
        self._touch(registration)
        self._trim()
        return VoiceContext(
            profile=profile, data=key, identity=("qwentts", key))

    def retain(self, context):
        self._check_owner()
        registration = self._registrations.get(context.data)
        if registration is None:
            raise RuntimeError("cannot retain an evicted qwentts context")
        registration.pins += 1
        self._touch(registration)

    def release(self, context):
        self._check_owner()
        registration = self._registrations.get(context.data)
        if registration is None or registration.pins <= 0:
            raise RuntimeError("qwentts context pin underflow")
        registration.pins -= 1
        self._touch(registration)
        self._trim()

    def _trim(self):
        while len(self._registrations) > self.CACHE_LIMIT:
            candidates = [
                (registration.last_used, key)
                for key, registration in self._registrations.items()
                if registration.pins == 0
            ]
            if not candidates:
                return
            _, key = min(candidates)
            from urllib.parse import quote
            escaped_key = quote(key, safe="")
            try:
                self._request(
                    f"/v1/audio/voices/{escaped_key}",
                    method="DELETE", timeout=10)
            except RuntimeError as exc:
                with self._state_lock:
                    if self._failure is None:
                        self._failure = {
                            "code": "voice_eviction_failed",
                            "message": str(exc),
                            "voice_key": key,
                        }
                return
            del self._registrations[key]

    def _write_segment(self, make_path, pcm):
        import wave

        path = make_path()
        with wave.open(path, "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(self.SAMPLE_RATE)
            output.writeframes(pcm)
        return path

    def synthesize(self, context, text, make_path, effects=False):
        self._ensure_healthy()
        registration = self._registrations.get(context.data)
        if registration is None or registration.pins <= 0:
            raise RuntimeError("qwentts context is not pinned for synthesis")
        self._touch(registration)
        body = json.dumps({
            "input": text,
            "voice": context.data,
            "response_format": "pcm",
        }).encode("utf-8")
        request = self._urllib_request.Request(
            f"{self._base_url}/v1/audio/speech", data=body,
            headers={"Content-Type": "application/json"},
            method="POST")

        def generate():
            try:
                response = self._urllib_request.urlopen(request, timeout=120)
                buffer = b""
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    buffer += chunk
                    while len(buffer) >= self.SEGMENT_BYTES:
                        yield self._write_segment(
                            make_path, buffer[:self.SEGMENT_BYTES])
                        buffer = buffer[self.SEGMENT_BYTES:]
                response.close()
                buffer = buffer[:len(buffer) & ~1]
                if buffer:
                    yield self._write_segment(make_path, buffer)
                if self._mark_child_exit():
                    raise RuntimeError(
                        "qwentts tts-server exited unexpectedly")
            except OSError as exc:
                if self._mark_child_exit():
                    raise RuntimeError(
                        "qwentts tts-server exited unexpectedly") from exc
                raise RuntimeError(
                    f"qwentts synthesis request failed: {exc}") from exc

        yield from _effect_paths(
            generate(), effects, self._ring_freq, self._ring_mix)

    def health(self):
        self._check_owner()
        self._mark_child_exit()
        with self._state_lock:
            failure = self._failure
        return EngineHealth(usable=failure is None, error=failure)

    def close(self):
        global _qwentts_process
        if self._closed:
            return
        if threading.get_ident() != self._owner:
            raise RuntimeError(
                "qwentts engine accessed outside its SynthWorker")
        self._closed = True
        self._monitor_stop.set()
        process = self._process
        if _qwentts_process is process:
            _qwentts_process = None
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        self._registrations.clear()


def load_qwen_tts_engine(model_id, language, device="auto",
                         ring_freq=40.0, ring_mix=0.12):
    return QwenTTSEngine(
        model_id, language, device, ring_freq, ring_mix)


def load_mlx_engine(model_id, language,
                    ring_freq=40.0, ring_mix=0.12):
    return MLXEngine(model_id, language, ring_freq, ring_mix)


def load_qwentts_engine(model_id, language, device="auto",
                         qwentts_bin=None, qwentts_model=None,
                         qwentts_codec=None, qwentts_port=None,
                         ring_freq=40.0, ring_mix=0.12):
    del model_id, device
    return QwenttsEngine(
        qwentts_bin, qwentts_model, qwentts_codec, qwentts_port, language,
        ring_freq, ring_mix)


def activate_voice(profile, prepare, persist, swap, retain, release):
    """Transactionally prepare, durably commit, then swap an active context.

    The callbacks are injected so preparation/control stay on the engine
    executor and persistence can be replaced by Phase 2 without coupling the
    engine layer to a settings schema.
    """
    prepared = prepare(profile)
    try:
        persist(profile)
    except BaseException:
        release(prepared)
        raise
    retain(prepared)
    previous = swap(prepared)
    release(prepared)
    if previous is not None:
        release(previous)
    return prepared


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
            sf.write(path,
                     processed.T if processed.ndim == 2 else processed, sr)
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
        "  uv run --no-group mlx --group torch tts/serve.py ...  (PyTorch)\n"
        "  uv run tts/serve.py -b qwentts ...                (qwentts.cpp)"
    )


def load_engine(backend, model_id, language, device="auto",
                qwentts_bin=None, qwentts_model=None,
                qwentts_codec=None, qwentts_port=None,
                ring_freq=40.0, ring_mix=0.12):
    backend = pick_backend(backend)
    print(f"model: {model_id} (backend: {backend})")
    if backend == "mlx":
        return load_mlx_engine(
            model_id, language, ring_freq, ring_mix)
    if backend == "qwentts":
        return load_qwentts_engine(
            model_id, language, device,
            qwentts_bin=qwentts_bin, qwentts_model=qwentts_model,
            qwentts_codec=qwentts_codec, qwentts_port=qwentts_port,
            ring_freq=ring_freq, ring_mix=ring_mix)
    return load_qwen_tts_engine(
        model_id, language, device, ring_freq, ring_mix)
def load_synth(backend, model_id, ref_audio, ref_text, language, device="auto",
               qwentts_bin=None, qwentts_model=None,
               qwentts_codec=None, qwentts_port=None):
    """Standalone benchmark convenience; the daemon uses load_engine."""
    ref_audio = Path(ref_audio).expanduser().resolve()
    transcript_path = ref_audio.with_suffix(".txt")
    profile_id = ref_audio.stem
    if not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile_id):
        import hashlib
        profile_id = (
            f"voice-{hashlib.sha256(str(ref_audio).encode()).hexdigest()[:16]}")
    profile = VoiceProfile(
        id=profile_id,
        display_name=ref_audio.stem,
        root_path=str(ref_audio.parent),
        audio_path=str(ref_audio),
        transcript_path=str(transcript_path),
        transcript=ref_text)
    engine = load_engine(
        backend, model_id, language, device,
        qwentts_bin=qwentts_bin, qwentts_model=qwentts_model,
        qwentts_codec=qwentts_codec, qwentts_port=qwentts_port)
    context = engine.prepare(profile)
    engine.retain(context)
    engine.release(context)

    def synth(text, make_path):
        yield from engine.synthesize(context, text, make_path)

    return synth




def resolve_ref_text(ref_audio, ref_text_path):
    path = ref_text_path or ref_audio.with_suffix(".txt")
    if not path.exists():
        raise SystemExit(
            f"ref-text not found: {path}\n"
            f"transcribe it with:\n"
            f"  uv run transcribe/transcribe.py {ref_audio} --language en"
        )
    return path.read_text().strip()


def default_legacy_config_path():
    """Return the one-time migration source used when --config is omitted."""
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/voice-ml/config.json"
    base = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(base) / "voice-ml/config.json"


def _is_loopback_host(host):
    candidate = host.strip().strip("[]")
    try:
        return ipaddress.ip_address(
            candidate.split("%", 1)[0]).is_loopback
    except ValueError:
        try:
            addresses = {
                item[4][0].split("%", 1)[0]
                for item in socket.getaddrinfo(
                    candidate, None, type=socket.SOCK_STREAM)
            }
        except socket.gaierror:
            return False
        return bool(addresses) and all(
            ipaddress.ip_address(address).is_loopback
            for address in addresses)


def _require_management_token(host, token):
    if token or _is_loopback_host(host):
        return
    raise SystemExit(
        "refusing non-loopback --host without authentication: "
        "set --token or VOICE_ML_TOKEN")


def _resolve_startup_voice(
        library, settings_store, settings, initial_voice=None):
    """Resolve durable selection, using a stable-ID bootstrap hint if empty."""
    if settings.active_voice is not None:
        return settings, library.resolve_ready(settings.active_voice)
    if initial_voice is None:
        raise ManagementFailure(
            "settings_active_voice_required",
            "Choose a ready voice before synthesis can start.",
            recoverable=True, status=409)
    profile = library.resolve_ready(initial_voice)
    settings = settings_store.set_active_voice(initial_voice)
    return settings, profile

def _resolve_explicit_startup_voice(
        library, settings_store, explicit_id):
    """Reject a flat source that collided with another managed profile."""
    failure = next((
        item for item in library.migration_failures
        if item["id"] == explicit_id
    ), None)
    if failure is not None:
        issue = failure["issue"]
        raise ManagementFailure(
            issue["code"], issue["message"], detail=failure,
            recoverable=True, status=409)
    profile = library.resolve_ready(explicit_id)
    settings = settings_store.set_active_voice(explicit_id)
    return settings, profile




def parse_args():
    p = argparse.ArgumentParser(
        description=("Voice-clone TTS daemon "
                     "(loads the model once, speaks POSTed text)."),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("-r", "--ref-audio", type=Path,
                   help="explicit reference voice clip (~3s wav)")
    p.add_argument("--ref-text", type=Path,
                   help="transcript of --ref-audio (default: its sibling .txt)")
    p.add_argument(
        "--config", type=Path,
        help="legacy config path used only as a one-time migration source")
    p.add_argument(
        "--initial-voice",
        help="stable voice ID used only when settings have no active voice")
    p.add_argument("-m", "--model", default=DEFAULT_MODEL,
                   help="TTS model id (HF repo)")
    p.add_argument("-b", "--backend", choices=list(BACKEND_CHOICES),
                   default="auto",
                   help="synthesis backend; auto picks an installed backend")
    p.add_argument(
        "--voices-dir", type=Path,
        help="daemon-owned voice library directory (defaults beside settings)")
    p.add_argument("-l", "--language", default="English",
                   help="language of the text (qwen-tts backend only)")
    p.add_argument("-d", "--device", choices=["auto", "cuda", "mps", "cpu"],
                   default="auto",
                   help="torch device (qwen-tts backend only); auto picks "
                        "cuda > mps > cpu")
    p.add_argument("--fx-ring-freq", type=float, default=40.0,
                   help="droid ring modulator carrier Hz")
    p.add_argument("--fx-ring-mix", type=float, default=0.12,
                   help="droid ring modulator wet mix 0-1")
    p.add_argument(
        "-p", "--port", type=int, default=DEFAULT_PORT,
        help="port to listen on")
    p.add_argument("--host", default=HOST,
                   help="address to bind (0.0.0.0 to serve the LAN; "
                        "set --token when doing so)")
    p.add_argument("--local-player", choices=["daemon", "client"],
                   default=None,
                   help="who plays the local channel: daemon plays audio on "
                        "this machine (default); client buffers the local "
                        "stream for a player to fetch via GET /segment. "
                        "Named channels are always client-played streams.")
    p.add_argument("--token", default=os.environ.get("VOICE_ML_TOKEN"),
                   help="require 'Authorization: Bearer <token>' on every "
                        "request (default: $VOICE_ML_TOKEN)")
    # qwentts.cpp backend options
    p.add_argument("--qwentts-bin", type=Path,
                   help="path to qwentts.cpp tts-server binary")
    p.add_argument("--qwentts-model", type=Path,
                   help="talker GGUF path (qwen-talker-*.gguf)")
    p.add_argument("--qwentts-codec", type=Path,
                   help="codec GGUF path (qwen-tokenizer-*.gguf)")
    p.add_argument("--qwentts-port", type=int, default=0,
                   help="localhost port for tts-server (0 = pick a free port)")
    return p.parse_args()


def _reach_ready_and_cleanup_migrations(
        app, library, legacy_path, cleanup_backups=True):
    """Publish first Ready, then retire managed-install migration backups."""
    app.set_lifecycle("ready")
    if not cleanup_backups:
        return True
    try:
        library.cleanup_migration_backups(legacy_path)
    except ManagementFailure as exc:
        app.set_lifecycle("degraded", exc.message, exc.as_dict())
        print(f"migration backup cleanup failed: {exc.detail}",
              file=sys.stderr)
        return False
    except Exception as exc:
        traceback.print_exception(type(exc), exc, exc.__traceback__)
        failure = ManagementFailure(
            "migration_backup_cleanup_failed",
            "Migration backup cleanup could not finish.",
            detail=repr(exc), recoverable=True, status=500)
        app.set_lifecycle(
            "degraded", failure.message, failure.as_dict())
        return False
    return True


def _settings_storage_for_launch(ref_audio, legacy_path):
    """Keep explicit-reference dev settings out of product storage."""
    if ref_audio is None:
        path = Path(legacy_path).expanduser().resolve().with_name(
            "settings.json")
        return path, legacy_path, None
    scope = tempfile.TemporaryDirectory(prefix="wren-explicit-settings-")
    return Path(scope.name) / "settings.json", None, scope


def main():
    args = parse_args()
    _require_management_token(args.host, args.token)
    legacy_path = args.config or default_legacy_config_path()
    if args.voices_dir is not None:
        voices_dir = args.voices_dir
    elif args.ref_audio is not None:
        voices_dir = args.ref_audio.expanduser().resolve().parent
    else:
        voices_dir = Path(legacy_path).expanduser().resolve().parent / "voices"
    voices_dir = voices_dir.expanduser().resolve()

    local_player = args.local_player or "daemon"
    segment_store = SegmentStore() if local_player == "client" else None
    reported_backend = (
        args.backend if args.backend != "auto" else "unresolved")
    reported_model = (
        str(args.qwentts_model)
        if reported_backend == "qwentts" and args.qwentts_model is not None
        else args.model)
    app = App(
        model_id=reported_model, token=args.token, segments=segment_store,
        backend=reported_backend, host=args.host, port=args.port,
        voices_dir=voices_dir, settings=ProductSettings())
    server = make_server(app, args.port, args.host)
    app.port = server.server_address[1]
    threading.Thread(
        target=server.serve_forever, name="wren-http", daemon=True).start()
    print(
        f"listening on http://{args.host}:{app.port} "
        f"(management v2; local player: {local_player})")

    def fail_startup(exc, code="startup_failed",
                     message="The daemon could not finish starting."):
        if isinstance(exc, ManagementFailure):
            error = exc.as_dict()
        else:
            traceback.print_exception(type(exc), exc, exc.__traceback__)
            error = {
                "code": code,
                "message": message,
                "detail": repr(exc),
                "recoverable": True,
            }
        app.set_lifecycle("failed", error["message"], error)

    app.set_lifecycle("loading", "Voice storage is loading.")

    library = VoiceLibrary(voices_dir)
    settings_path, settings_legacy_path, settings_scope = (
        _settings_storage_for_launch(args.ref_audio, legacy_path))
    # Keep an explicit-reference TemporaryDirectory alive for this process.
    _ = settings_scope
    settings_store = SettingsStore(
        settings_path, settings_legacy_path, library)
    try:
        library.initialize()
        settings = settings_store.initialize()
        app.configure_storage(library, settings_store)

        if args.ref_audio is not None:
            reference = args.ref_audio.expanduser().resolve()
            transcript = (
                args.ref_text.expanduser().resolve()
                if args.ref_text is not None
                else reference.with_suffix(".txt"))
            explicit_id = reference.stem
            if (reference.parent != voices_dir
                    or transcript != reference.with_suffix(".txt")
                    or CHANNEL_NAME_RE.fullmatch(explicit_id) is None):
                raise ManagementFailure(
                    "startup_voice_unmanaged",
                    "The startup voice must be a stable ID in the configured "
                    "voice library.",
                    detail={
                        "reference": str(reference),
                        "voices_dir": str(voices_dir),
                    },
                    recoverable=True, status=409)
            settings, voice_profile = _resolve_explicit_startup_voice(
                library, settings_store, explicit_id)
        else:
            settings, voice_profile = _resolve_startup_voice(
                library, settings_store, settings, args.initial_voice)
    except BaseException as exc:
        if app.library is None:
            app.configure_storage(library, settings_store)
        fail_startup(exc)
        threading.Event().wait()
        return

    try:
        actual_backend = pick_backend(args.backend)
        if actual_backend == "qwentts":
            missing = [
                name for name in (
                    "qwentts_bin", "qwentts_model", "qwentts_codec")
                if not getattr(args, name)
            ]
            if missing:
                flag = missing[0].replace("_", "-")
                raise ManagementFailure(
                    "deployment_setting_missing",
                    "The qwentts deployment is incomplete.",
                    detail=f"--{flag} is required",
                    recoverable=True, status=409)
            if args.qwentts_port == 0:
                args.qwentts_port = _pick_free_port()
            args.model = str(args.qwentts_model)
            import signal
            signal.signal(
                signal.SIGTERM, lambda signum, frame: sys.exit(0))
        else:
            args.qwentts_bin = None
            args.qwentts_model = None
            args.qwentts_codec = None
            args.qwentts_port = None
        app.backend = actual_backend
        app.model_id = args.model
        app._bump_revision()

        def factory():
            return load_engine(
                actual_backend, args.model, args.language, args.device,
                qwentts_bin=args.qwentts_bin,
                qwentts_model=args.qwentts_model,
                qwentts_codec=args.qwentts_codec,
                qwentts_port=args.qwentts_port,
                ring_freq=args.fx_ring_freq,
                ring_mix=args.fx_ring_mix)

        app.set_lifecycle("loading", "The synthesis engine is loading.")
        app.speaker = Speaker(
            engine_factory=factory, voice_profile=voice_profile,
            play_fn=segment_store,
            speed=settings.default_synthesis_rate)
        app.ensure_channels()
        app.speaker._worker.initialized.wait()
        if app.speaker._worker.initialization_error is not None:
            raise app.speaker._worker.initialization_error
    except BaseException as exc:
        fail_startup(
            exc, code="engine_load_failed",
            message="The synthesis engine could not be loaded.")
        threading.Event().wait()
        return

    _reach_ready_and_cleanup_migrations(
        app, library, legacy_path,
        cleanup_backups=args.ref_audio is None)
    print("ready")
    threading.Event().wait()


if __name__ == "__main__":
    main()
