"""Synthesis scheduling: one engine-owning worker, one Speaker per channel.

The server never plays audio. Each channel's Speaker renders into its own
SegmentStore, which edge clients drain through GET /segment.
"""

import os
import queue
import shutil
import sys
import tempfile
import threading
import time
import traceback
from dataclasses import dataclass, field

from text import (
    CHARS_PER_SEC, FIRST_CHUNK_CHARS, MAX_CHUNK_CHARS, block_span, chunk_text)


def wav_seconds(path):
    try:
        import soundfile as sf
        info = sf.info(path)
        return info.frames / info.samplerate
    except Exception:
        return 0.0



@dataclass(frozen=True)
class SynthesisSnapshot:
    """Voice and effects captured once when a request is accepted, so
    a later PUT /voice or PATCH /settings never changes queued speech."""

    context: object
    effects: bool
    identity: tuple = field(init=False)

    def __post_init__(self):
        object.__setattr__(
            self, "identity", (self.context.key, self.effects))

class SegmentStore:
    """One channel's rendered segments, held for GET /segment long-polls.

    seq is monotonic for the store's life so a client can always resume with
    the last seq it saw; invalidate() (preempt/stop) drops buffered segments
    and bumps epoch so the client also drops what it scheduled locally.
    """

    # A stalled client can never grow the server past this per channel.
    MAX_BYTES = 64 * 1024 * 1024

    def __init__(self, max_bytes=MAX_BYTES):
        self._max_bytes = max_bytes
        self._cond = threading.Condition()
        self._segments = []  # [(seq, block, wav bytes)]
        self._bytes = 0
        self._seq = 0
        self.epoch = 0
        # Highest seq handed to a client: the playhead proxy the lookahead
        # budget measures against.
        self._fetched = 0
        self.on_fetch = None  # budget freed on fetch; wakes the worker
        # Played cursor (client reports via ?played=) and durations of
        # handed-out-but-unplayed segments: what "speaking" is derived from.
        self._played = 0
        self._epoch_base = 0
        self._durations = {}

    def submit(self, path, block):
        seconds = wav_seconds(path)
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
                self._durations.pop(seq, None)
                print(f"segment buffer full; dropped seq {seq} unfetched",
                      file=sys.stderr)
            self._cond.notify_all()

    def invalidate(self):
        with self._cond:
            self.epoch += 1
            self._segments.clear()
            self._bytes = 0
            # Reports about pre-bump seqs are stale by definition.
            self._epoch_base = self._seq
            self._played = self._seq
            self._durations.clear()
            self._cond.notify_all()

    def report_played(self, seq):
        with self._cond:
            seq = min(seq, self._seq)
            if seq <= self._epoch_base or seq <= self._played:
                return
            self._played = seq
            for s in [s for s in self._durations if s <= seq]:
                del self._durations[s]
            # Played clips are never re-fetched within an epoch; keeping
            # them would replay them to a restarted client and hold memory
            # until the byte cap.
            kept = []
            for entry in self._segments:
                if entry[0] <= seq:
                    self._bytes -= len(entry[2])
                else:
                    kept.append(entry)
            self._segments = kept

    def unplayed(self):
        """Segments released this epoch that the client has not reported
        played: nonzero means audio is (or is about to be) audible."""
        with self._cond:
            return len(self._durations)

    def unfetched(self):
        with self._cond:
            return sum(1 for s, _, _ in self._segments if s > self._fetched)

    def next_after(self, seq, timeout):
        """First buffered segment with seq > the given one, waiting up to
        timeout. Returns (seq, block, data, epoch); data is None on timeout
        or when the epoch changes while parked."""
        deadline = time.monotonic() + timeout
        found = None
        with self._cond:
            entry_epoch = self.epoch
            while found is None:
                if self.epoch != entry_epoch:
                    # Return now so the client drops scheduled audio
                    # immediately instead of at the end of its poll.
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
        # worker holds its lock while calling unfetched().
        if self.on_fetch is not None:
            self.on_fetch()
        return found


class _ControlCall:
    __slots__ = ("fn", "args", "done", "result", "error")

    def __init__(self, fn, args, wait):
        self.fn = fn
        self.args = args
        self.done = threading.Event() if wait else None
        self.result = None
        self.error = None

    def run(self):
        try:
            self.result = self.fn(*self.args)
        except BaseException as exc:
            self.error = exc
            if self.done is None:
                traceback.print_exc()
        finally:
            if self.done is not None:
                self.done.set()


class _SnapshotLease:
    """One context pin shared by every chunk of one accepted request."""

    __slots__ = ("snapshot", "_worker", "_remaining", "_lock")

    def __init__(self, snapshot, worker, count):
        self.snapshot = snapshot
        self._worker = worker
        self._remaining = count
        self._lock = threading.Lock()

    def release_one(self):
        with self._lock:
            if self._remaining <= 0:
                return
            self._remaining -= 1
            last = self._remaining == 0
        if last:
            self._worker.release(self.snapshot.context, wait=False)


class _QueueItem:
    __slots__ = ("epoch", "index", "text", "snapshot", "_lease", "_released")

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
    """One resumable synthesis call and the queue items it covers."""

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
        if not self._released:
            self._released = True
            for item in self.items:
                item.release()

    def close(self):
        try:
            self.gen.close()
        except Exception as exc:
            print(f"synth failed: {exc}", file=sys.stderr)
        finally:
            self.release()


class SynthWorker:
    """The single thread that owns the engine. Backend calls (prepare,
    retain, release) are queued as controls and alternate with synthesis
    steps, so neither starves; synthesis round-robins across Speakers one
    segment at a time."""

    # Segments a channel may have rendered ahead of its client's playhead.
    LOOKAHEAD = 2

    def __init__(self, engine_factory):
        self._factory = engine_factory
        self.engine = None
        self.error = None
        self.loaded = threading.Event()
        self._owner = None
        self._cond = threading.Condition()
        self._controls = []
        self._prefer_synth = False
        self._speakers = []
        self._rr = 0
        threading.Thread(target=self._run, name="synth-worker",
                         daemon=True).start()

    def control(self, fn, *args, wait=True):
        if threading.get_ident() == self._owner:
            return fn(*args)
        call = _ControlCall(fn, args, wait)
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
        return self.control(lambda: self.engine.prepare(profile))

    def retain(self, context):
        return self.control(lambda: self.engine.retain(context))

    def release(self, context, wait=True):
        return self.control(lambda: self.engine.release(context), wait=wait)

    def register(self, speaker):
        with self._cond:
            self._speakers.append(speaker)
            self._cond.notify_all()

    def unregister(self, speaker):
        self.control(self._unregister_owned, speaker)

    def _unregister_owned(self, speaker):
        batch, speaker._batch = speaker._batch, None
        if batch is not None:
            batch.close()
        carry, speaker._carry = speaker._carry, None
        if carry is not None:
            carry.release()
        with self._cond:
            if speaker in self._speakers:
                self._speakers.remove(speaker)
                self._rr = 0

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

    def _run(self):
        self._owner = threading.get_ident()
        try:
            self.engine = self._factory()
        except BaseException as exc:
            traceback.print_exc()
            print("engine load failed; server stays up and reports it",
                  file=sys.stderr)
            self.error = exc
            self.loaded.set()
            return
        self.loaded.set()
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
                    batch.close()
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
            speaker._batch = None
            batch.close()
            return
        if batch is None:
            batch = self._start_batch(speaker)
            if batch is None:
                return
            speaker._batch = batch
        self._pump(speaker, batch)

    def _start_batch(self, speaker):
        """Coalesce queued chunks that share one snapshot into a single
        synthesis call (up to max_chars), amortizing per-call prefill."""
        if speaker._carry is not None:
            item, speaker._carry = speaker._carry, None
        else:
            try:
                item = speaker._synth_q.get_nowait()
            except queue.Empty:
                return None
        if item.epoch != speaker._epoch:
            item.release()
            return None
        epoch, snapshot = item.epoch, item.snapshot
        items, parts = [item], [item.text]
        idxs = [] if item.index is None else [item.index]
        # The first batch of an epoch stays small so audio starts fast.
        if epoch == speaker._last_synth_epoch:
            total = len(item.text)
            while total < speaker._max_chars:
                try:
                    nxt = speaker._synth_q.get_nowait()
                except queue.Empty:
                    break
                if nxt.epoch < epoch:
                    nxt.release()
                    continue
                if (nxt.epoch > epoch
                        or nxt.snapshot.identity != snapshot.identity):
                    speaker._carry = nxt
                    break
                items.append(nxt)
                parts.append(nxt.text)
                if nxt.index is not None:
                    idxs.append(nxt.index)
                total += len(nxt.text) + 1
        text = " ".join(parts)
        speaker._last_synth_epoch = epoch
        block = (idxs[0], idxs[-1]) if idxs else None
        layout = (list(zip(idxs, (len(p) for p in parts)))
                  if idxs and len(idxs) == len(parts) else None)
        print(f'synthesizing [{speaker.name}] ({len(text)} chars): "{text}"',
              flush=True)
        try:
            gen = self.engine.synthesize(
                snapshot.context, text, speaker._make_path, snapshot.effects)
        except Exception:
            for queued in items:
                queued.release()
            raise
        return _Batch(epoch, gen, text, layout, block, snapshot, items)

    def _pump(self, speaker, batch):
        """Render one segment, then return to the fair scheduler."""
        if not speaker._synth_schedulable():
            return
        try:
            path = next(batch.gen)
        except StopIteration:
            self._finish(speaker, batch)
            return
        if batch.epoch != speaker._epoch:
            speaker._batch = None
            batch.close()
            return
        seg_start = batch.audio_s
        batch.audio_s += wav_seconds(path)
        seg_block = (block_span(batch.layout, seg_start, batch.audio_s,
                                speaker._chars_per_sec)
                     if batch.layout and batch.audio_s > seg_start
                     else batch.block)
        with self._cond:
            if batch.epoch == speaker._inflight_epoch:
                speaker._inflight += 1
        speaker._play_q.put((batch.epoch, path, seg_block))

    def _finish(self, speaker, batch):
        speaker._batch = None
        batch.release()
        wall = time.monotonic() - batch.t0
        if wall > 0:
            print(f"  {batch.audio_s:.1f}s audio in {wall:.1f}s"
                  f" (RTF {batch.audio_s / wall:.2f})", flush=True)
        # Recalibrate the highlight's speech-rate estimate from real audio;
        # the seed drifts by whole sentences over a long batch otherwise.
        if batch.epoch == speaker._epoch and batch.audio_s > 0:
            measured = len(batch.text) / batch.audio_s
            if 5.0 <= measured <= 30.0:
                speaker._chars_per_sec = (
                    0.5 * speaker._chars_per_sec + 0.5 * measured)


class Speaker:
    """One channel's utterance queue. speak() without append preempts what
    this channel has queued or buffered; every stage drops stale-epoch work,
    including mid-generation."""

    def __init__(self, name, worker, store, max_chars=MAX_CHUNK_CHARS,
                 first_chars=FIRST_CHUNK_CHARS):
        self.name = name
        self._worker = worker
        self.store = store
        self._max_chars = max_chars
        self._first_chars = first_chars
        self._lock = threading.Lock()
        self._epoch = 0
        self._pause = threading.Event()
        self._synth_q = queue.Queue()
        self._play_q = queue.Queue()
        self._blocks = None  # last blocks-speak, kept for /seek
        self._blocks_snapshot = None
        self._last_played = None
        self._counter = 0
        self._last_synth_epoch = -1
        # Worker-owned: parked batch, an item rescued mid-coalesce, and the
        # count of rendered segments not yet handed to the store.
        self._batch = None
        self._carry = None
        self._inflight = 0
        self._inflight_epoch = 0
        self._synth_busy = False
        self._chars_per_sec = CHARS_PER_SEC
        self._tmpdir = tempfile.mkdtemp(prefix="wren-serve-")
        store.on_fetch = worker.wake
        self._thread = threading.Thread(target=self._deliver_loop,
                                        daemon=True)
        self._thread.start()
        worker.register(self)

    def speak(self, snapshot, blocks, append=False):
        """Queue [(index|None, text)] under an already-retained snapshot;
        the pin transfers to the queue (released when the last chunk is
        done or dropped)."""
        chunks = self._chunks_for(blocks)
        if not chunks:
            self._worker.release(snapshot.context, wait=False)
            return 0
        lease = _SnapshotLease(snapshot, self._worker, len(chunks))
        with self._lock:
            if not append:
                self._preempt_locked()
                self._replace_blocks_locked(blocks, snapshot)
            epoch = self._epoch
            for idx, chunk in chunks:
                self._synth_q.put(_QueueItem(epoch, idx, chunk, lease))
        self._worker.wake()
        return len(chunks)

    def _replace_blocks_locked(self, blocks, snapshot):
        old = self._blocks_snapshot
        indexed = [(i, t) for i, t in blocks if i is not None]
        if indexed:
            self._worker.retain(snapshot.context)
            self._blocks, self._blocks_snapshot = indexed, snapshot
        else:
            self._blocks = self._blocks_snapshot = None
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
        self._worker.reset_budget(self)
        self.store.invalidate()
        # A paused channel would otherwise sit on the new audio.
        self._pause.clear()
        self._last_played = None

    def seek(self, delta=None, target=None):
        """Jump within the last blocks-speak by preempting and requeueing
        from the target: delta blocks relative to the last seek/landing, or
        an absolute block index. Returns the clamped landing index, or None
        when there is nothing seekable (plain-text speech)."""
        with self._lock:
            blocks = self._blocks
            if not blocks:
                return None
            lo, hi = blocks[0][0], blocks[-1][0]
            if target is None:
                cur = self._last_played if self._last_played is not None else lo
                target = cur + delta
            target = min(max(lo, target), hi)
            snapshot = self._blocks_snapshot
            chunks = self._chunks_for(
                [(i, t) for i, t in blocks if i >= target])
            self._worker.retain(snapshot.context)
            lease = _SnapshotLease(snapshot, self._worker, len(chunks))
            self._preempt_locked()
            for idx, chunk in chunks:
                self._synth_q.put(_QueueItem(self._epoch, idx, chunk, lease))
            # The base for a follow-up relative seek.
            self._last_played = target
        self._worker.wake()
        return target

    def stop(self):
        with self._lock:
            self._epoch += 1
            self._drain()
            old = self._blocks_snapshot
            self._blocks = self._blocks_snapshot = None
            self._worker.reset_budget(self)
            self.store.invalidate()
            self._pause.clear()
        if old is not None:
            self._worker.release(old.context, wait=False)
        self._worker.wake()

    def pause(self):
        # The client pauses its own audio; the flag stops its fetches from
        # mattering, and the lookahead budget parks synthesis by itself.
        self._pause.set()

    def resume(self):
        self._pause.clear()
        self._worker.wake()

    def paused(self):
        return self._pause.is_set()

    def pending(self):
        return self._synth_q.qsize() + self._play_q.qsize()

    def has_queued_text(self):
        return (self._synth_busy or not self._synth_q.empty()
                or self._carry is not None
                or (self._batch is not None
                    and self._batch.epoch == self._epoch))

    def _synth_runnable(self):
        # Stale parked state must run (to be discarded) even when the
        # budget is spent, or its pins are never released.
        if self._batch is not None and self._batch.epoch != self._epoch:
            return True
        if self._carry is not None and self._carry.epoch != self._epoch:
            return True
        has_work = (self._batch is not None or self._carry is not None
                    or not self._synth_q.empty())
        return has_work and self._synth_schedulable()

    def _synth_schedulable(self):
        """Synthesis tracks the client's playhead instead of free-running a
        whole message into memory; pause needs no rule of its own because
        a paused client stops fetching."""
        return (self._inflight + self.store.unfetched()
                < SynthWorker.LOOKAHEAD)

    def _drain(self):
        while True:
            try:
                self._synth_q.get_nowait().release()
            except queue.Empty:
                break
        while True:
            try:
                item = self._play_q.get_nowait()
            except queue.Empty:
                break
            if item is not None:
                _unlink(item[1])

    def _make_path(self):
        self._counter += 1
        return os.path.join(self._tmpdir, f"{self._counter}.wav")

    def close(self):
        """Stop, detach from the worker, and end the delivery thread."""
        self.stop()
        self._worker.unregister(self)
        self._play_q.put(None)
        self._thread.join(timeout=5)
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _deliver_loop(self):
        while True:
            item = self._play_q.get()
            if item is None:
                return
            epoch, path, block = item
            try:
                # Under the lock preempt/stop take: a segment checked here
                # cannot land in the store after the epoch bump that
                # invalidated it.
                with self._lock:
                    if epoch == self._epoch:
                        self.store.submit(path, block)
            except Exception as exc:
                print(f"segment submit failed: {exc}", file=sys.stderr)
            finally:
                # Only after submit: until then the segment is counted by
                # neither the play queue nor the store's unfetched tally,
                # and freeing budget early lets synthesis overrun.
                self._worker.segment_taken(self, epoch)
                _unlink(path)


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass
