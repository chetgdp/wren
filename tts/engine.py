"""qwentts.cpp backend: a resident tts-server child driven over localhost HTTP.

Every method except `failure` must run on the SynthWorker thread that built
the engine: registrations and pins are unsynchronized owner state.
"""

import atexit
import base64
import hashlib
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import wave
from dataclasses import dataclass
from urllib.parse import quote

# Reference clips are a few seconds of audio; this matches the upload cap so
# a voice that was accepted can always be prepared.
MAX_REFERENCE_WAV_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class VoiceContext:
    """A prepared voice: `key` is the tts-server registration name."""

    voice_id: str
    key: str


@dataclass
class _Registration:
    pins: int
    last_used: int


def pick_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def voice_key(audio, transcript):
    """Content-addressed registration name: the same clip and transcript map
    to one tts-server voice no matter which id or path they came from, so a
    renamed voice or an A->B->A switch reuses the registration."""
    text = transcript.encode("utf-8")
    digest = hashlib.sha256()
    digest.update(b"wren-voice-context-v1\0")
    digest.update(len(audio).to_bytes(8, "big"))
    digest.update(audio)
    digest.update(len(text).to_bytes(8, "big"))
    digest.update(text)
    return f"wren-{digest.hexdigest()}"


def read_reference(profile):
    """Reference wav bytes for a storage.VoiceProfile, bounded and sniffed."""
    if not profile.transcript.strip():
        raise ValueError("voice transcript must not be empty")
    size = os.path.getsize(profile.audio_path)
    if size > MAX_REFERENCE_WAV_BYTES:
        raise ValueError(f"reference audio is too large ({size} bytes)")
    audio = profile.audio_path.read_bytes()
    if len(audio) < 12 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
        raise ValueError(f"voice audio is not a WAV file: {profile.audio_path}")
    return audio


def effect_paths(paths, enabled, ring_freq, ring_mix):
    """Run each streamed segment through one DroidFX instance. One instance
    per synthesize call: segments of a stream play gaplessly, so the ring
    carrier and chorus LFO must continue across boundaries or joins click."""
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
        sf.write(path, processed.T if processed.ndim == 2 else processed, sr)
        yield path


# Module-level so atexit/SIGTERM can reap the child even if the engine
# object is unreachable (startup failure paths).
_child: subprocess.Popen | None = None


def _cleanup_child():
    global _child
    process, _child = _child, None
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


class QwenttsEngine:
    """Resident qwentts child with content-addressed, pinned voices."""

    # tts-server keeps every registered voice in memory; unpinned ones past
    # this count are deleted least-recently-used first.
    CACHE_LIMIT = 16
    SAMPLE_RATE = 24000
    # One second of 16-bit mono PCM per segment: small enough that playback
    # starts quickly, large enough that per-segment HTTP overhead is noise.
    SEGMENT_BYTES = SAMPLE_RATE * 2

    def __init__(self, qwentts_bin, qwentts_model, qwentts_codec,
                 language="English", port=0, ring_freq=40.0, ring_mix=0.12,
                 startup_timeout=60):
        global _child
        self._owner = threading.get_ident()
        port = port or pick_free_port()
        self._base_url = f"http://127.0.0.1:{port}"
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
            "--port", str(port),
            "--lang", language,
        ]
        print(f"starting tts-server on 127.0.0.1:{port}", flush=True)
        self._process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL)
        _child = self._process
        atexit.register(_cleanup_child)
        if not self._wait_ready(startup_timeout):
            exited = self._process.poll() is not None
            self.close()
            raise RuntimeError(
                "tts-server exited during startup (see its stderr above)"
                if exited else
                f"tts-server did not become ready on port {port} "
                f"within {startup_timeout}s")
        print(f"tts-server ready on port {port}", flush=True)
        threading.Thread(target=self._monitor_child, name="qwentts-monitor",
                         daemon=True).start()

    def _wait_ready(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                return False
            try:
                with urllib.request.urlopen(
                        f"{self._base_url}/health", timeout=1) as response:
                    response.read()
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
                    "message": "qwentts tts-server exited unexpectedly "
                               f"(exit {returncode})",
                }
        return True

    @property
    def failure(self):
        """Thread-safe: request handlers read this without a worker hop."""
        with self._state_lock:
            return self._failure

    def _check_owner(self):
        if threading.get_ident() != self._owner:
            raise RuntimeError("qwentts engine accessed outside its worker")
        if self._closed:
            raise RuntimeError("qwentts engine is closed")
        self._mark_child_exit()
        failure = self.failure
        if failure is not None:
            raise RuntimeError(failure["message"])

    def _touch(self, registration):
        self._clock += 1
        registration.last_used = self._clock

    def _request(self, path, body=None, method="GET", timeout=30):
        request = urllib.request.Request(
            f"{self._base_url}{path}", data=body,
            headers={"Content-Type": "application/json"}, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except OSError as exc:
            if self._mark_child_exit():
                raise RuntimeError(
                    "qwentts tts-server exited unexpectedly") from exc
            raise RuntimeError(f"qwentts request failed: {exc}") from exc

    def prepare(self, profile):
        """Register (or reuse) the profile's voice; returns a pinned context."""
        self._check_owner()
        audio = read_reference(profile)
        key = voice_key(audio, profile.transcript)
        registration = self._registrations.get(key)
        if registration is None:
            body = json.dumps({
                "name": key,
                "ref_text": profile.transcript,
                "wav_b64": base64.b64encode(audio).decode("ascii"),
            }).encode("utf-8")
            self._request("/v1/audio/voices", body=body, method="POST")
            registration = _Registration(pins=1, last_used=0)
            self._registrations[key] = registration
        else:
            registration.pins += 1
        self._touch(registration)
        self._trim()
        return VoiceContext(voice_id=profile.id, key=key)

    def retain(self, context):
        self._check_owner()
        registration = self._registrations.get(context.key)
        if registration is None:
            raise RuntimeError("cannot retain an evicted qwentts voice")
        registration.pins += 1
        self._touch(registration)

    def release(self, context):
        if self._closed:
            return
        registration = self._registrations.get(context.key)
        if registration is None or registration.pins <= 0:
            raise RuntimeError("qwentts voice pin underflow")
        registration.pins -= 1
        self._touch(registration)
        self._trim()

    def _trim(self):
        while len(self._registrations) > self.CACHE_LIMIT:
            candidates = [(reg.last_used, key)
                          for key, reg in self._registrations.items()
                          if reg.pins == 0]
            if not candidates:
                return
            _, key = min(candidates)
            try:
                self._request(f"/v1/audio/voices/{quote(key, safe='')}",
                              method="DELETE", timeout=10)
            except RuntimeError as exc:
                # Leave it registered; the next trim retries. Memory on the
                # child is the only cost, and synthesis keeps working.
                print(f"voice eviction failed: {exc}", file=sys.stderr)
                return
            del self._registrations[key]

    def _write_segment(self, make_path, pcm):
        path = make_path()
        with wave.open(path, "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(self.SAMPLE_RATE)
            output.writeframes(pcm)
        return path

    def synthesize(self, context, text, make_path, effects=False):
        """Generator of wav segment paths streamed from tts-server."""
        self._check_owner()
        registration = self._registrations.get(context.key)
        if registration is None or registration.pins <= 0:
            raise RuntimeError("qwentts voice is not pinned for synthesis")
        self._touch(registration)
        body = json.dumps({
            "input": text,
            "voice": context.key,
            "response_format": "pcm",
        }).encode("utf-8")
        request = urllib.request.Request(
            f"{self._base_url}/v1/audio/speech", data=body,
            headers={"Content-Type": "application/json"}, method="POST")

        def generate():
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    buffer = b""
                    while chunk := response.read(65536):
                        buffer += chunk
                        while len(buffer) >= self.SEGMENT_BYTES:
                            yield self._write_segment(
                                make_path, buffer[:self.SEGMENT_BYTES])
                            buffer = buffer[self.SEGMENT_BYTES:]
                buffer = buffer[:len(buffer) & ~1]
                if buffer:
                    yield self._write_segment(make_path, buffer)
            except OSError as exc:
                if self._mark_child_exit():
                    raise RuntimeError(
                        "qwentts tts-server exited unexpectedly") from exc
                raise RuntimeError(
                    f"qwentts synthesis request failed: {exc}") from exc

        yield from effect_paths(
            generate(), effects, self._ring_freq, self._ring_mix)

    def close(self):
        global _child
        if self._closed:
            return
        self._closed = True
        self._monitor_stop.set()
        if _child is self._process:
            _child = None
        if self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()
        self._registrations.clear()
