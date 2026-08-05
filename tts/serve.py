"""Voice-clone TTS daemon: POST text, hear it in the cloned voice.

Loads Qwen3-TTS once and serves speak requests on 127.0.0.1 only. Markdown
is stripped server-side so clients (e.g. the pi `voice` extension) can send
raw agent output. Text is chunked into sentence groups so playback starts
after the first chunk instead of after the whole message. A new /speak or
/stop preempts anything still queued or playing.

Endpoints (every playback POST takes an optional "channel"; see Channels):
    POST /speak  {"text": "...", "raw": false, "append": false,
                  "speed": 1.5, "channel": "name"} -> {"queued": n}
                 speed (0.5-3.0) time-stretches output pitch-preserved and
                 sticks until the next request that sets it (or the --speed
                 default)
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
    GET  /config -> live settings (voice, voices_dir, speed, fx, port,
                 backend) plus "restart_required": true when a persisted
                 change needs a daemon restart (model reload / rebind) to
                 take effect - the manager's cue to restart the child
    POST /config partial update, e.g. {"speed": 1.4}: validates, persists to
                 the config file atomically, hot-applies speed and fx, marks
                 voice/voices_dir/port/backend restart_required; responds
                 with the same shape as GET /config plus "persisted": a
                 failed file write leaves the change live in memory and
                 reports "persisted": false with "persist_error". Unknown
                 keys are 400 and nothing is written.

Settings live in a JSON config file (--config; default
~/Library/Application Support/voice-ml/config.json on macOS,
$XDG_CONFIG_HOME/voice-ml/config.json elsewhere). It is read once at launch
and rewritten on every accepted POST /config; command-line flags override it
for one run without being written back.

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
import traceback
from dataclasses import asdict, dataclass, fields, replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

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
# Keys POST /config persists but cannot hot-apply (model reload or rebind);
# a persisted drift from the launch snapshot is reported as restart_required.
RESTART_KEYS = ("voice", "voices_dir", "port", "backend")
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


@dataclass
class Config:
    """The config surface: exactly these fields, in this order. The file
    doubles as a hand-edited UI, so daemon rewrites keep it pretty-printed
    and stably ordered (field order) instead of mangling whatever the user
    laid out.

    Construction validates types and ranges (ValueError), so a Config in
    hand is always well-formed. File-existence checks (the voice's wav+txt)
    are separate via with_changes(check_files=True): POST /config must
    reject an unresolvable voice, but at load the ref-audio resolution
    already reports a missing file with the transcribe hint.
    """

    voice: str | None = None
    voices_dir: str | None = None
    speed: float = 1.0
    fx: bool = False
    port: int = DEFAULT_PORT
    backend: str = "auto"

    def __post_init__(self):
        speed = self.speed
        if (not isinstance(speed, (int, float)) or isinstance(speed, bool)
                or not SPEED_MIN <= speed <= SPEED_MAX):
            raise ValueError(
                f"speed must be a number in [{SPEED_MIN}, {SPEED_MAX}]")
        if not isinstance(self.fx, bool):
            raise ValueError("fx must be a boolean")
        port = self.port
        if (not isinstance(port, int) or isinstance(port, bool)
                or not 1 <= port <= 65535):
            raise ValueError("port must be an integer in [1, 65535]")
        if self.backend not in BACKEND_CHOICES:
            raise ValueError(
                f"backend must be one of: {', '.join(BACKEND_CHOICES)}")
        for key in ("voice", "voices_dir"):
            value = getattr(self, key)
            if value is not None and not isinstance(value, str):
                raise ValueError(f"{key} must be a string")
        if self.voice is not None:
            # A voice is a bare name resolved inside voices_dir, nothing
            # else: separators or ".." would let a request read files
            # outside it.
            if ("/" in self.voice or "\\" in self.voice
                    or self.voice in ("", ".", "..")):
                raise ValueError(
                    "voice must be a bare name (no path separators or ..)")
            if self.voices_dir is None:
                raise ValueError("voice requires voices_dir")

    def with_changes(self, changes, check_files=False):
        """Error-string API for callers that report instead of raise (POST
        /config bodies, the config file at load): a partial dict applied on
        top of self, so voice and voices_dir are checked as the merged
        pair. Returns (new Config, None) or (None, error message)."""
        for key in changes:
            if key not in _CONFIG_FIELDS:
                return None, f"unknown key: {key}"
        try:
            merged = replace(self, **changes)
        except ValueError as exc:
            return None, str(exc)
        if check_files:
            error = merged.check_voice_files()
            if error:
                return None, error
        return merged, None

    @classmethod
    def from_dict(cls, raw, check_files=False):
        """Raw dict merged over the defaults; same return as with_changes."""
        return cls().with_changes(raw, check_files=check_files)

    def check_voice_files(self):
        """Error message when the voice's wav or transcript is missing."""
        if self.voice is None:
            return None
        wav = resolve_voice(self.voice, self.voices_dir)
        if not wav.exists():
            return f"voice wav not found: {wav}"
        if not wav.with_suffix(".txt").exists():
            return f"voice transcript not found: {wav.with_suffix('.txt')}"
        return None


_CONFIG_FIELDS = tuple(f.name for f in fields(Config))


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


class _Batch:
    """One in-flight synthesis call: the streaming generator plus the
    bookkeeping the worker needs to resume it after parking (owner paused
    past its budget, or lookahead spent)."""

    __slots__ = ("epoch", "gen", "text", "layout", "block", "speed",
                 "t0", "audio_s")

    def __init__(self, epoch, gen, text, layout, block, speed):
        self.epoch = epoch
        self.gen = gen
        self.text = text
        self.layout = layout
        self.block = block
        self.speed = speed
        self.t0 = time.monotonic()
        self.audio_s = 0.0


class SynthWorker:
    """The one thread that owns the TTS model and renders every Speaker's
    queued text.

    MLX streams are thread-local, so the model must load and generate on
    the same thread; synth_factory runs here for that reason. Speakers
    register themselves and the worker round-robins over whichever of them
    is schedulable: has work and lookahead budget left. A paused or
    fully-rendered Speaker simply stops being scheduled - the worker never
    blocks on one Speaker's state, so several Speakers (per-utterance
    channels, later) can share it without a stalled one jamming the rest.
    """

    # Render at most this many segments past the playhead: enough to hide
    # per-segment synth latency (the next segment is ready before this one
    # ends) without free-running a whole page of audio into memory.
    LOOKAHEAD = 2

    def __init__(self, synth_fn=None, synth_factory=None):
        self._synth = synth_fn
        self._factory = synth_factory
        self.ready = threading.Event()
        if synth_fn is not None:
            self.ready.set()
        self._cond = threading.Condition()
        self._speakers = []
        self._rr = 0  # round-robin cursor so no Speaker starves
        threading.Thread(target=self._run, daemon=True).start()

    def register(self, speaker):
        with self._cond:
            self._speakers.append(speaker)
            self._cond.notify_all()

    def unregister(self, speaker):
        """Channel GC: a deleted channel's Speaker must stop being
        scheduled or the worker would keep probing dead state forever."""
        with self._cond:
            if speaker in self._speakers:
                self._speakers.remove(speaker)
                self._rr = 0
            self._cond.notify_all()

    def wake(self):
        """Scheduling inputs changed (new work, resume, freed budget):
        re-evaluate who runs."""
        with self._cond:
            self._cond.notify_all()

    def segment_taken(self, speaker, epoch):
        """Playback pulled a segment off the queue: the playhead advanced,
        so a unit of lookahead budget is free again. epoch is the popped
        segment's; a stale segment pulled after reset_budget re-based the
        accounting must not free budget the new epoch never charged, or the
        worker transiently renders past LOOKAHEAD."""
        with self._cond:
            if epoch == speaker._inflight_epoch and speaker._inflight > 0:
                speaker._inflight -= 1
            self._cond.notify_all()

    def reset_budget(self, speaker):
        """A preemption drained the play queue; nothing is in flight. The
        accounting re-bases onto the current epoch so charges and frees for
        older segments become no-ops from here on."""
        with self._cond:
            speaker._inflight = 0
            speaker._inflight_epoch = speaker._epoch
            self._cond.notify_all()

    def _run(self):
        if self._factory is not None:
            try:
                self._synth = self._factory()
            except Exception:
                traceback.print_exc()
                print("model load failed; exiting", file=sys.stderr)
                # os._exit skips atexit; no-op unless qwentts
                _cleanup_qwentts()
                os._exit(1)
            self.ready.set()
        while True:
            speaker = self._next()
            # The busy flag covers the instant where text has left the
            # synth queue but the batch is not visible yet; without it the
            # machine queue can read "no text, no audio" mid-handoff and
            # retire a channel that is in fact mid-utterance.
            speaker._synth_busy = True
            # One bad batch must never kill the only synthesis thread: log
            # it, drop that batch (its generator unwinds here, on the
            # model's thread), re-base the speaker's budget, and move on.
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
                self.reset_budget(speaker)
            finally:
                speaker._synth_busy = False

    def _next(self):
        """Block until some Speaker is runnable and pick it fairly."""
        with self._cond:
            while True:
                count = len(self._speakers)
                for i in range(count):
                    speaker = self._speakers[(self._rr + i) % count]
                    if speaker._synth_runnable():
                        self._rr = (self._rr + i + 1) % count
                        return speaker
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
            epoch, idx, text = speaker._carry
            speaker._carry = None
        else:
            try:
                epoch, idx, text = speaker._synth_q.get_nowait()
            except queue.Empty:
                return None
        if epoch != speaker._epoch:
            return None
        parts = [text]
        idxs = [] if idx is None else [idx]
        # Coalesce backlog that queued up behind a previous synthesis:
        # every generate call pays a prefill proportional to the
        # reference length, so batching backlog into one call pays it
        # once instead of per sentence. The first chunk of an epoch is
        # never coalesced; it is sized small for fast first audio.
        # Coalescing only ever reads this Speaker's own queue, so
        # utterances never merge across Speakers.
        if epoch == speaker._last_synth_epoch:
            total = len(text)
            while total < speaker._max_chars:
                try:
                    item = speaker._synth_q.get_nowait()
                except queue.Empty:
                    break
                next_epoch, next_idx, next_text = item
                if next_epoch < epoch:
                    continue  # stale, drop
                if next_epoch > epoch:
                    # A preemption queued this mid-coalesce; it belongs
                    # to the new epoch, not this dying batch.
                    speaker._carry = item
                    break
                parts.append(next_text)
                if next_idx is not None:
                    idxs.append(next_idx)
                total += len(next_text) + 1
            text = " ".join(parts)
        if epoch != speaker._epoch:  # preempted during coalesce
            return None
        speaker._last_synth_epoch = epoch
        # A coalesced batch spans several blocks. Each streamed segment
        # is tagged with the sentence range it is estimated to cover, so
        # the reported position tracks the audible sentence, not the
        # whole batch. Falls back to the full range when the parts/index
        # pairing is broken (mixed indexed and plain-text chunks).
        block = (idxs[0], idxs[-1]) if idxs else None
        layout = (list(zip(idxs, (len(p) for p in parts)))
                  if idxs and len(idxs) == len(parts) else None)
        print(f'synthesizing ({len(text)} chars, '
              f'{speaker.pending()} queued): "{text}"',
              flush=True)
        # Speed is read once per batch: mid-stream changes would jump rate.
        return _Batch(epoch, self._synth(text, speaker._make_path),
                      text, layout, block, speaker.speed)

    def _pump(self, speaker, batch):
        """Pull segments from the batch until it finishes, its Speaker
        stops being schedulable (parked, resumable later), or a preemption
        makes it stale."""
        while True:
            if batch.epoch != speaker._epoch:
                self._discard(speaker, batch)
                return
            if not speaker._synth_schedulable():
                return  # parked; playback progress or resume re-schedules
            try:
                path = next(batch.gen)
            except StopIteration:
                self._finish(speaker, batch)
                return
            if batch.epoch != speaker._epoch:  # preempted: abandon it
                self._discard(speaker, batch)
                return
            if batch.speed != 1.0:
                try:
                    # Before _wav_seconds so the block-position math
                    # and rate calibration see playback durations.
                    stretch_wav(path, batch.speed)
                except Exception as exc:
                    print(f"time-stretch failed ({exc}); playing at "
                          "1.0x", file=sys.stderr)
            seg_start = batch.audio_s
            batch.audio_s += _wav_seconds(path)
            # Unknown/zero segment duration: report the whole batch.
            seg_block = (block_span(batch.layout, seg_start, batch.audio_s,
                                    speaker._chars_per_sec)
                         if batch.layout and batch.audio_s > seg_start
                         else batch.block)
            with self._cond:
                # A preemption may have re-based the accounting since the
                # epoch check above; a segment of the old epoch stays
                # uncharged (it will be popped as stale, also uncharged).
                if batch.epoch == speaker._inflight_epoch:
                    speaker._inflight += 1
            speaker._play_q.put((batch.epoch, path, seg_block))

    def _discard(self, speaker, batch):
        speaker._batch = None
        # close() runs the generator's unwind here, on the model's thread.
        try:
            batch.gen.close()
        except Exception as exc:
            print(f"synth failed: {exc}", file=sys.stderr)

    def _finish(self, speaker, batch):
        speaker._batch = None
        wall = time.monotonic() - batch.t0
        print(f"  {batch.audio_s:.1f}s audio in {wall:.1f}s"
              f" (RTF {batch.audio_s / wall:.2f})",
              flush=True)
        # Recalibrate the highlight's speech-rate estimate from this
        # batch. Only un-preempted batches measure the full text; the
        # EMA smooths pause/punctuation noise between batches and the
        # clamp rejects degenerate wavs (silence, decode failures).
        if batch.epoch == speaker._epoch and batch.audio_s > 0:
            measured = len(batch.text) / batch.audio_s
            if 5.0 <= measured <= 30.0:
                speaker._chars_per_sec = (0.5 * speaker._chars_per_sec
                                          + 0.5 * measured)


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
                 worker=None):
        if worker is None:
            if (synth_fn is None) == (synth_factory is None):
                raise ValueError(
                    "pass exactly one of synth_fn or synth_factory")
            worker = SynthWorker(synth_fn=synth_fn,
                                 synth_factory=synth_factory)
        self._worker = worker
        self.ready = worker.ready
        self._play = play_fn or default_player()
        self._max_chars = max_chars
        self._first_chars = first_chars
        # Playback rate; read once per synth batch. Mutated by speak(speed=)
        # so a request's speed persists for everything after it.
        self.speed = speed
        self._lock = threading.Lock()
        self._epoch = 0
        self._pause = threading.Event()
        self._synth_q = queue.Queue()
        self._play_q = queue.Queue()
        self._current = None
        self._current_block = None
        self._blocks = None  # last blocks-speak, kept for /seek
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

    def speak(self, text=None, append=False, blocks=None, speed=None):
        """blocks: list of (index, text) pairs; the index of whatever is
        currently audible is exposed via current_block() so clients can
        highlight it. Plain text is a single index-less block."""
        if speed is not None:
            self.speed = speed
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
        self._worker.wake()
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
        """Cross-channel preemption: a later /seek must not resurrect text
        that a preempt-all already nuked."""
        with self._lock:
            self._blocks = None

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
        self._worker.wake()
        return target

    def stop(self):
        with self._lock:
            self._epoch += 1
            self._drain()
            self._worker.reset_budget(self)
            self._terminate_current()
            if hasattr(self._play, "invalidate"):
                self._play.invalidate()
            self._resume_locked()
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
        """Worker-side: anything to do for this Speaker right now? A stale
        parked batch counts as work - the worker must discard it (the
        generator's unwind has to run on the model's thread)."""
        if self._batch is not None and self._batch.epoch != self._epoch:
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

    def _make_path(self):
        self._counter += 1
        return os.path.join(self._tmpdir, f"{self._counter}.wav")

    def close(self):
        """Channel GC: stop, detach from the shared worker, and end the
        play loop. The Speaker must not be used afterwards."""
        self.stop()
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
        # /speak's speed is sticky daemon-wide: one knob, every channel.
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

    def speak(self, name, text=None, blocks=None, append=False, speed=None):
        if speed is not None:
            self.set_speed(speed)
        ch = self._acquire(name)
        try:
            if not append:
                self.preempt_all(keep=name)
            queued = ch.speaker.speak(text=text, blocks=blocks,
                                      append=append)
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


class App:
    """Shared server state. speaker is attached once the model finishes
    loading, so the server can come up (and report status) immediately."""

    def __init__(self, model_id="", token=None, segments=None,
                 config_path=None, config=None):
        self.model_id = model_id
        self.token = token
        self.segments = segments  # SegmentStore when --local-player client
        self.speaker = None
        self.config_path = config_path  # None: don't persist (tests)
        self.config = config if config is not None else Config()
        # Launch snapshot of the restart-only keys; /config reports
        # restart_required once the persisted value drifts from it. Flag
        # overrides stay out of this on purpose: they are one-off and the
        # file is the truth a restart would come back to.
        self.applied = {k: getattr(self.config, k) for k in RESTART_KEYS}
        self.fx_enabled = self.config.fx  # live; read by wrap_fx
        # POST /config does read-validate-update-save; serialize it so
        # concurrent posts can't interleave a stale config into a save.
        self.config_lock = threading.Lock()
        # Channel routing is built on first use (or eagerly by main), so a
        # server that never sees a channel field behaves exactly as it did
        # before channels existed.
        self.channels = None
        self.channel_opts = {}  # test hook: short clocks and windows
        self._channels_lock = threading.Lock()

    def ensure_channels(self):
        with self._channels_lock:
            if self.channels is None and self.speaker is not None:
                self.channels = ChannelManager(self.speaker, self.segments,
                                               **self.channel_opts)
        return self.channels


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

    def _origin_allowed(self):
        origin = self.headers.get("Origin", "")
        if not origin or origin.startswith(ALLOWED_ORIGIN_SCHEMES):
            return True
        self._json(403, {"error": "origin not allowed"})
        return False

    def _authorized(self):
        token = self.app.token
        if not token:
            return True
        supplied = self.headers.get("Authorization", "")
        if hmac.compare_digest(supplied, f"Bearer {token}"):
            return True
        self._json(401, {"error": "unauthorized"})
        return False

    def _config_payload(self):
        """GET and POST /config both return this: the live settings plus an
        unambiguous restart_required so a manager (the future Swift app)
        knows whether the daemon must be restarted to apply what the file
        now says."""
        app = self.app
        live = asdict(app.config)
        if app.speaker is not None:  # speed is live (also moved by /speak)
            live["speed"] = app.speaker.speed
        live["fx"] = app.fx_enabled
        live["restart_required"] = any(
            getattr(app.config, k) != app.applied[k] for k in RESTART_KEYS)
        return live

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

    def do_GET(self):
        if not self._origin_allowed() or not self._authorized():
            return
        url = urlsplit(self.path)
        if url.path == "/health":
            speaker = self.app.speaker
            ready = speaker is not None and speaker.ready.is_set()
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
            mgr = self.app.channels
            if ready and mgr is not None:
                channels = mgr.snapshot()
                local = channels[LOCAL_CHANNEL]
                # Top-level fields keep their pre-channel meaning for
                # existing clients: machine-wide activity plus the local
                # channel's pause/position.
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
        elif url.path == "/config":
            self._json(200, self._config_payload())
        elif url.path == "/segment":
            self._segment(parse_qs(url.query))
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._origin_allowed() or not self._authorized():
            return
        speaker = self.app.speaker
        if speaker is None or not speaker.ready.is_set():
            self._json(503, {"error": "model still loading"})
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
        if self.path == "/config":
            app = self.app
            with app.config_lock:
                updated, error = app.config.with_changes(body,
                                                         check_files=True)
                if error:
                    self._json(400, {"error": error})
                    return
                app.config = updated
                # Hot-apply what playback picks up mid-flight; the rest sits
                # in the file and is reported via restart_required.
                if "speed" in body:
                    if mgr is not None:  # one knob, every channel
                        mgr.set_speed(float(body["speed"]))
                    else:
                        speaker.speed = float(body["speed"])
                if "fx" in body:
                    app.fx_enabled = body["fx"]
                # Persist last: the change is already live in memory, so a
                # failed write (disk full, permissions) must not undo it or
                # crash the daemon - it is reported instead.
                persist_error = None
                if app.config_path is not None:
                    try:
                        save_config(app.config_path, app.config)
                    except OSError as exc:
                        persist_error = str(exc)
                payload = self._config_payload()
                payload["persisted"] = persist_error is None
                if persist_error is not None:
                    payload["persist_error"] = persist_error
                self._json(200, payload)
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
            if mgr is not None:
                queued = mgr.speak(channel or LOCAL_CHANNEL, blocks=indexed,
                                   append=append, speed=speed)
            else:
                queued = speaker.speak(blocks=indexed, append=append,
                                       speed=speed)
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
        if mgr is not None:
            queued = mgr.speak(channel or LOCAL_CHANNEL, text=text,
                               append=append, speed=speed)
        else:
            queued = speaker.speak(text, append=append, speed=speed)
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
    """MLX backend (mlx-community/Qwen3-TTS-* and other mlx-audio
    conversions)."""
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
            # codec is 12.5 frames/sec
            cap_samples = (max_tokens - 1) * sr / 12.5
            emitted += audio.size
            path = make_path()
            sf.write(path, audio, sr)
            yield path
        if cap_samples is not None and emitted >= cap_samples:
            print(f"warning: hit token cap ({max_tokens}); output may be "
                  f"truncated babble for: {text[:60]!r}", file=sys.stderr)

    return synth


# Global reference to the qwentts child process, set once by load_qwentts_synth.
_qwentts_process: subprocess.Popen | None = None


def _pick_free_port():
    """Bind an ephemeral localhost port and return its number."""
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _cleanup_qwentts():
    """Terminate the tts-server child if it's still running."""
    global _qwentts_process
    if _qwentts_process and _qwentts_process.poll() is None:
        _qwentts_process.terminate()
        try:
            _qwentts_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _qwentts_process.kill()
            _qwentts_process.wait()
        _qwentts_process = None


def load_qwentts_synth(model_id, ref_audio, ref_text, language, device="auto",
                       qwentts_bin=None, qwentts_model=None,
                       qwentts_codec=None, qwentts_port=None):
    """qwentts.cpp backend: spawns tts-server as a child process and proxies
    synthesis via its OpenAI-compatible HTTP API.
    """
    global _qwentts_process

    import atexit
    import base64
    import urllib.request

    # RuntimeError, not SystemExit: this runs in the Speaker synth thread,
    # whose error paths catch Exception only (SystemExit would silently kill
    # the thread and leave the daemon serving 503 forever).
    if not all([qwentts_bin, qwentts_model, qwentts_codec, qwentts_port]):
        raise RuntimeError(
            "qwentts backend requires --qwentts-bin, --qwentts-model, "
            "--qwentts-codec, and --qwentts-port"
        )

    # Read the reference WAV and encode it for voice registration.
    ref_wav_bytes = ref_audio.read_bytes()
    ref_wav_b64 = base64.b64encode(ref_wav_bytes).decode("ascii")

    # Build the tts-server command line.
    cmd = [
        qwentts_bin,
        "--model", qwentts_model,
        "--codec", qwentts_codec,
        "--host", "127.0.0.1",
        "--port", str(qwentts_port),
        "--lang", language,
    ]

    print(f"starting tts-server on 127.0.0.1:{qwentts_port}")
    # stderr is inherited so model-load failures are visible in the daemon log.
    _qwentts_process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL)
    atexit.register(_cleanup_qwentts)

    # Poll until the server answers /health, the child dies, or we time out.
    startup_timeout = 60
    def _is_ready(port, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if _qwentts_process.poll() is not None:
                return False
            try:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/health", timeout=1
                ).read()
                return True
            except OSError:
                time.sleep(0.2)
        return False

    if not _is_ready(qwentts_port, startup_timeout):
        exited = _qwentts_process.poll() is not None
        _cleanup_qwentts()
        raise RuntimeError(
            "tts-server exited during startup (see its stderr above)" if exited
            else f"tts-server did not become ready on port {qwentts_port} "
                 f"within {startup_timeout}s"
        )
    print(f"tts-server ready on port {qwentts_port}")

    # Register the clone voice once via POST /v1/audio/voices.
    voice_url = f"http://127.0.0.1:{qwentts_port}/v1/audio/voices"
    voice_body = json.dumps({
        "name": "serve_clone",
        "ref_text": ref_text,
        "wav_b64": ref_wav_b64,
    }).encode("utf-8")
    voice_req = urllib.request.Request(
        voice_url, data=voice_body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(voice_req, timeout=30)
        resp.read()
        print("voice 'serve_clone' registered with tts-server")
    except OSError as exc:
        _cleanup_qwentts()
        raise RuntimeError(f"failed to register voice: {exc}") from exc

    import wave

    QWENTTS_SR = 24000  # tts-server pcm is s16le 24 kHz mono
    SEG_BYTES = QWENTTS_SR * 2  # ~1s per yielded segment, like the mlx path

    def _write_seg(make_path, pcm):
        path = make_path()
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(QWENTTS_SR)
            w.writeframes(pcm)
        return path

    def synth(text, make_path):
        """Stream synthesis via tts-server's POST /v1/audio/speech.

        response_format "pcm" streams s16le as it is generated, so segments
        yield while generation continues (first audio ~engine TTFA instead
        of after the whole chunk, which "wav" one-shot forced)."""
        speech_url = f"http://127.0.0.1:{qwentts_port}/v1/audio/speech"
        body = json.dumps({
            "input": text,
            "voice": "serve_clone",
            "response_format": "pcm",
        }).encode("utf-8")
        req = urllib.request.Request(
            speech_url, data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            resp = urllib.request.urlopen(req, timeout=120)
            buf = b""
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                buf += chunk
                while len(buf) >= SEG_BYTES:
                    yield _write_seg(make_path, buf[:SEG_BYTES])
                    buf = buf[SEG_BYTES:]
            buf = buf[:len(buf) & ~1]  # drop a trailing half-sample
            if buf:
                yield _write_seg(make_path, buf)
        except OSError as exc:
            if _qwentts_process and _qwentts_process.poll() is not None:
                raise RuntimeError("tts-server exited unexpectedly") from exc
            raise RuntimeError(f"synthesis request failed: {exc}") from exc

    return synth


def wrap_fx(synth, ring_freq, ring_mix, enabled=None):
    """Post-process every synthesized segment through the droid chain.

    One stateful DroidFX per synth call: segments of a stream are played
    gaplessly, so the ring-mod carrier and chorus LFO must continue across
    segment boundaries or the joins click. reset() per call keeps unrelated
    utterances from sharing filter tails.

    enabled is a callable checked per synth call so POST /config can toggle
    fx live without a model reload; None means always on.
    """
    import soundfile as sf
    from fx import DroidFX

    fx = DroidFX(ring_freq=ring_freq, ring_mix=ring_mix)

    def wrapped(text, make_path):
        if enabled is not None and not enabled():
            yield from synth(text, make_path)
            return
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


def load_synth(backend, model_id, ref_audio, ref_text, language, device="auto",
               qwentts_bin=None, qwentts_model=None,
               qwentts_codec=None, qwentts_port=None):
    backend = pick_backend(backend)
    print(f"model: {model_id} (backend: {backend})")
    if backend == "mlx":
        return load_mlx_synth(model_id, ref_audio, ref_text, language)
    if backend == "qwentts":
        return load_qwentts_synth(
            model_id, ref_audio, ref_text, language, device,
            qwentts_bin=qwentts_bin, qwentts_model=qwentts_model,
            qwentts_codec=qwentts_codec, qwentts_port=qwentts_port,
        )
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


def default_config_path():
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/voice-ml/config.json"
    base = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(base) / "voice-ml/config.json"


def resolve_voice(voice, voices_dir):
    """A voice name resolves to voices_dir/<name>.wav with its transcript in
    the sibling .txt - the same layout -r + resolve_ref_text expect."""
    return Path(voices_dir).expanduser() / f"{voice}.wav"


def load_config(path):
    """File contents merged over the Config defaults. A missing file just
    means defaults; a hand-broken file (bad JSON, unknown key, bad value) is
    a startup error naming the file, because the file is hand-edited and a
    traceback would bury the actual problem."""
    path = Path(path)
    if not path.exists():
        return Config()
    try:
        data = json.loads(path.read_text())
    except ValueError as exc:
        raise SystemExit(f"config file {path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"config file {path} must contain a JSON object")
    config, error = Config.from_dict(data)
    if error:
        raise SystemExit(f"config file {path}: {error}")
    return config


def save_config(path, config):
    """Atomic write: full JSON to a temp file in the same directory, fsync,
    then rename over config.json, so a crash mid-save (daemons die by
    SIGKILL) never leaves a truncated file. Pretty-printed in Config field
    order with a trailing newline so rewrites don't mangle a hand-kept file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config-",
                               suffix=".json.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(asdict(config), f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def effective_settings(config, args):
    """Flag-over-file merge for the keys flags can override. The flags
    default to None so an absent flag is distinguishable from an explicit
    value; flags are one-off dev overrides and are never written back.
    A flag value that fails Config validation is a startup error."""
    overrides = {key: getattr(args, key)
                 for key in ("speed", "fx", "port", "backend")
                 if getattr(args, key) is not None}
    try:
        return replace(config, **overrides)
    except ValueError as exc:
        raise SystemExit(str(exc))


def parse_args():
    p = argparse.ArgumentParser(
        description=("Voice-clone TTS daemon "
                     "(loads the model once, speaks POSTed text)."),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("-r", "--ref-audio", type=Path,
                   help="reference voice clip (~3s wav); overrides the "
                        "config file's voice/voices_dir")
    p.add_argument("--ref-text", type=Path,
                   help="transcript of --ref-audio (default: its sibling .txt)")
    p.add_argument("--config", type=Path,
                   help="settings file (default: ~/Library/Application "
                        "Support/voice-ml/config.json on macOS, "
                        "$XDG_CONFIG_HOME/voice-ml/config.json elsewhere); "
                        "flags below override it for this run only")
    p.add_argument("-m", "--model", default=DEFAULT_MODEL,
                   help="TTS model id (HF repo)")
    p.add_argument("-b", "--backend", choices=list(BACKEND_CHOICES),
                   default=None,
                   help="auto picks whichever backend library is installed "
                        "(default: config file, or auto)")
    p.add_argument("-l", "--language", default="English",
                   help="language of the text (qwen-tts backend only)")
    p.add_argument("-d", "--device", choices=["auto", "cuda", "mps", "cpu"],
                   default="auto",
                   help="torch device (qwen-tts backend only); auto picks "
                        "cuda > mps > cpu")
    p.add_argument("--fx", action="store_true", default=None,
                   help="apply the droid effect chain (fx.py) to all output "
                        "(default: config file, or off)")
    p.add_argument("--fx-ring-freq", type=float, default=40.0,
                   help="droid ring modulator carrier Hz")
    p.add_argument("--fx-ring-mix", type=float, default=0.12,
                   help="droid ring modulator wet mix 0-1")
    p.add_argument("-p", "--port", type=int, default=None,
                   help=f"port to listen on (default: config file, or "
                        f"{DEFAULT_PORT})")
    p.add_argument("--host", default=HOST,
                   help="address to bind (0.0.0.0 to serve the LAN; "
                        "set --token when doing so)")
    p.add_argument("--speed", type=float, default=None,
                   help=f"default playback speed, pitch-preserving "
                        f"({SPEED_MIN}-{SPEED_MAX}); a /speak with a speed "
                        f"field overrides it from then on (default: config "
                        f"file, or 1.0)")
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


def main():
    args = parse_args()
    config_path = args.config or default_config_path()
    config = load_config(config_path)
    live = effective_settings(config, args)
    # Downstream code reads args.*; fold the merged values back in.
    args.speed = live.speed
    args.port = live.port
    args.backend = live.backend
    if args.ref_audio is None:
        if live.voice is None:
            raise SystemExit(
                f"no voice: pass -r, or set voice/voices_dir in {config_path}")
        args.ref_audio = resolve_voice(live.voice, live.voices_dir)
    if not args.ref_audio.exists():
        raise SystemExit(f"ref-audio not found: {args.ref_audio}")
    ref_text = resolve_ref_text(args.ref_audio, args.ref_text)

    if args.host not in ("127.0.0.1", "localhost", "::1") and not args.token:
        print("warning: binding beyond loopback with no --token; anyone on "
              "the network can drive synthesis", file=sys.stderr)
    local_player = args.local_player or "daemon"
    store = SegmentStore() if local_player == "client" else None

    # qwentts: validate required flags and pick a free port if needed.
    if args.backend == "qwentts":
        missing = [a for a in ("qwentts_bin", "qwentts_model", "qwentts_codec")
                   if not getattr(args, a)]
        if missing:
            raise SystemExit(
                f"--qwentts-{missing[0].split('_', 1)[1]}"
                " is required with -b qwentts"
            )
        if args.qwentts_port == 0:
            args.qwentts_port = _pick_free_port()
        # -m goes unused with this backend; /health should name the model
        # actually synthesizing, not the mlx default.
        args.model = str(args.qwentts_model)
        # atexit alone doesn't run on SIGTERM; route it through sys.exit so
        # the tts-server child is terminated when the daemon is killed.
        import signal
        signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    else:
        args.qwentts_bin = None
        args.qwentts_model = None
        args.qwentts_codec = None
        args.qwentts_port = None

    # Serve immediately so clients can see "loading" via /health; /speak
    # returns 503 until the model is loaded. The model loads inside the
    # Speaker's synth thread because MLX streams are thread-local.
    app = App(model_id=args.model, token=args.token, segments=store,
              config_path=config_path, config=config)
    app.fx_enabled = live.fx  # --fx overrides the file for this run
    server = make_server(app, args.port, args.host)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"listening on http://{args.host}:{args.port}  "
          f"(POST /speak, /stop; GET /health; local player: {local_player})")

    def factory():
        synth = load_synth(
            args.backend, args.model, args.ref_audio, ref_text,
            args.language, args.device,
            qwentts_bin=args.qwentts_bin,
            qwentts_model=args.qwentts_model,
            qwentts_codec=args.qwentts_codec,
            qwentts_port=args.qwentts_port,
        )
        # Always wrapped so POST /config can toggle fx live; the gate makes
        # it a passthrough while disabled.
        synth = wrap_fx(synth, args.fx_ring_freq, args.fx_ring_mix,
                        enabled=lambda: app.fx_enabled)
        # Warm up before reporting ready: the first generation pays JIT and
        # cache costs (observed 4-20s extra) better spent at startup than on
        # the first real request.
        warm_dir = tempfile.mkdtemp(prefix="voice-warmup-")
        t0 = time.monotonic()
        for path in synth("Voice daemon warm up.",
                          lambda: os.path.join(
                              warm_dir, f"{time.monotonic_ns()}.wav")):
            try:
                os.unlink(path)
            except OSError:
                pass
        print(f"warmup synth: {time.monotonic() - t0:.1f}s")
        return synth

    app.speaker = Speaker(synth_factory=factory, play_fn=store,
                          speed=args.speed)
    app.ensure_channels()
    app.speaker.ready.wait()
    print("ready")
    threading.Event().wait()


if __name__ == "__main__":
    main()
