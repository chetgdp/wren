"""Schema-v2 voice-library and product-settings storage.

All library mutations are rooted in retained, no-follow directory descriptors.
Path objects are used only as public descriptions; storage never trusts them as
an authority after initialization.
"""

from __future__ import annotations

import ctypes
import io
import errno
import hashlib
import json
import os
import re
import stat
import sys
import threading
import uuid
import wave
from dataclasses import asdict, dataclass, replace
from pathlib import Path


SCHEMA_VERSION = 2
VOICE_ID_RE = re.compile(r"[a-z0-9_-]{1,32}\Z")
PROFILE_FIELDS = {"schema_version", "id", "display_name"}
SETTINGS_FIELDS = {
    "schema_version", "active_voice", "effects", "default_synthesis_rate"
}
MUTABLE_SETTINGS_FIELDS = {
    "active_voice", "effects", "default_synthesis_rate"
}
RATE_MIN = 0.5
RATE_MAX = 3.0
# Profile inputs are local but untrusted. Check fstat before every allocation.
MAX_PROFILE_METADATA_BYTES = 64 * 1024
MAX_TRANSCRIPT_BYTES = 256 * 1024
MAX_REFERENCE_WAV_BYTES = 64 * 1024 * 1024
_DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_PENDING_NAME = ".migration-pending-v2.json"
_MANIFEST_NAME = ".migration-backups-v2.json"

def _storage_test_hook(event, **details):
    """No-op fault/race hook used by deterministic storage tests."""
    del event, details


class ManagementFailure(Exception):
    """One structured, user-safe failure shared by storage and HTTP layers."""

    def __init__(self, code, message, detail=None, recoverable=True, status=400):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail
        self.recoverable = recoverable
        self.status = status

    def as_dict(self):
        return {
            "code": self.code,
            "message": self.message,
            "detail": self.detail,
            "recoverable": self.recoverable,
        }


@dataclass(frozen=True)
class VoiceIssue:
    code: str
    field: str
    message: str


@dataclass(frozen=True)
class VoiceLibraryEntry:
    id: str
    display_name: str
    status: str
    issues: tuple[VoiceIssue, ...] = ()

    def as_dict(self):
        return {
            "id": self.id,
            "display_name": self.display_name,
            "status": self.status,
            "issues": [asdict(issue) for issue in self.issues],
        }


@dataclass(frozen=True)
class VoiceLibrarySnapshot:
    revision: int
    voices: tuple[VoiceLibraryEntry, ...]

    def as_dict(self):
        return {
            "revision": self.revision,
            "voices": [voice.as_dict() for voice in self.voices],
        }


@dataclass(frozen=True)
class ProductSettings:
    schema_version: int = SCHEMA_VERSION
    active_voice: str | None = None
    effects: bool = False
    default_synthesis_rate: float = 1.0

    def __post_init__(self):
        if self.schema_version != SCHEMA_VERSION or isinstance(
                self.schema_version, bool):
            raise ValueError("schema_version must be 2")
        if self.active_voice is not None and not _valid_voice_id(
                self.active_voice):
            raise ValueError(
                "active_voice must match [a-z0-9_-]{1,32} or be null")
        if not isinstance(self.effects, bool):
            raise ValueError("effects must be a boolean")
        rate = self.default_synthesis_rate
        if (not isinstance(rate, (int, float)) or isinstance(rate, bool)
                or not RATE_MIN <= rate <= RATE_MAX):
            raise ValueError(
                f"default_synthesis_rate must be a number in "
                f"[{RATE_MIN}, {RATE_MAX}]")

    @classmethod
    def from_dict(cls, raw):
        if not isinstance(raw, dict):
            raise ValueError("settings must contain a JSON object")
        unknown = set(raw) - SETTINGS_FIELDS
        missing = SETTINGS_FIELDS - set(raw)
        if unknown:
            raise ValueError(f"unknown settings key: {sorted(unknown)[0]}")
        if missing:
            raise ValueError(f"missing settings key: {sorted(missing)[0]}")
        return cls(**raw)

    def as_dict(self):
        return asdict(self)


@dataclass(frozen=True)
class _ValidatedProfile:
    entry: VoiceLibraryEntry
    root: Path
    audio: Path
    transcript: Path
    transcript_text: str


@dataclass(frozen=True)
class _MigrationProblem:
    profile_id: str
    issue: VoiceIssue


@dataclass(frozen=True)
class _CommitResult:
    committed: bool
    durability_error: str | None = None


@dataclass(frozen=True)
class _AtPath:
    dir_fd: int
    name: str
    display: Path
    verify: object | None = None

    def __fspath__(self):
        return str(self.display)


class _RetainedDirectory:
    def __init__(self, path, fd, *, parent=None, name=None):
        self.path = Path(path)
        self.fd = fd
        current = os.fstat(fd)
        self.identity = (current.st_dev, current.st_ino)
        self.parent = parent
        self.name = name

    def verify(self):
        current = os.fstat(self.fd)
        if (current.st_dev, current.st_ino) != self.identity:
            raise _unsafe_library("A retained directory changed identity.")
        if self.parent is None:
            linked = os.stat(self.path, follow_symlinks=False)
        else:
            self.parent.verify()
            linked = os.stat(
                self.name, dir_fd=self.parent.fd, follow_symlinks=False)
        if (not stat.S_ISDIR(linked.st_mode)
                or (linked.st_dev, linked.st_ino) != self.identity):
            raise _unsafe_library(
                f"Directory '{self.path.name}' was replaced.")

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def _unsafe_library(detail):
    return ManagementFailure(
        "voice_library_unsafe",
        "The voice library contains an unsafe filesystem entry.",
        detail=detail,
        status=409,
    )


def _valid_voice_id(value):
    return isinstance(value, str) and VOICE_ID_RE.fullmatch(value) is not None


def _validate_voice_id(value, field="id"):
    if not _valid_voice_id(value):
        raise ManagementFailure(
            "voice_id_invalid",
            "Voice IDs must use 1-32 lowercase letters, digits, '-' or '_'.",
            detail=f"{field} did not match [a-z0-9_-]{{1,32}}",
            status=400,
        )


def _validate_display_name(value):
    if not isinstance(value, str) or not value.strip():
        raise ManagementFailure(
            "voice_display_name_invalid",
            "Voice display name must not be empty.",
            detail="display_name must be a nonempty string",
            status=400,
        )
    if len(value) > 128:
        raise ManagementFailure(
            "voice_display_name_invalid",
            "Voice display name must be at most 128 characters.",
            detail="display_name exceeded 128 characters",
            status=400,
        )
    return value.strip()


def _identity(value):
    return value.st_dev, value.st_ino


def _open_directory(path, *, dir_fd=None):
    return os.open(path, _DIRECTORY_FLAGS | _NOFOLLOW, dir_fd=dir_fd)


def _fsync_dir(path):
    """Compatibility helper; descriptor-backed code fsyncs retained fds."""
    fd = _open_directory(path)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class _FileTooLarge(Exception):
    def __init__(self, size, limit):
        super().__init__(f"file is {size} bytes; limit is {limit}")
        self.size = size
        self.limit = limit


def _read_fd(fd, max_bytes=None):
    initial = os.fstat(fd).st_size
    if max_bytes is not None and initial > max_bytes:
        raise _FileTooLarge(initial, max_bytes)
    payload = bytearray()
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            return bytes(payload)
        if max_bytes is not None and len(payload) + len(chunk) > max_bytes:
            raise _FileTooLarge(len(payload) + len(chunk), max_bytes)
        payload.extend(chunk)


def _open_regular_at(dir_fd, name):
    before = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode):
        raise OSError(errno.EINVAL, "required entry is not a regular file", name)
    fd = os.open(name, os.O_RDONLY | _NOFOLLOW, dir_fd=dir_fd)
    try:
        after = os.fstat(fd)
        if _identity(before) != _identity(after) or not stat.S_ISREG(after.st_mode):
            raise OSError(errno.ESTALE, "required file changed identity", name)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read_bytes_at(dir_fd, name, max_bytes=None):
    fd = _open_regular_at(dir_fd, name)
    try:
        return _read_fd(fd, max_bytes)
    finally:
        os.close(fd)


def _read_json_at(dir_fd, name, max_bytes=None):
    return json.loads(
        _read_bytes_at(dir_fd, name, max_bytes).decode("utf-8"))


def _entry_exists(dir_fd, name):
    try:
        os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _path_parent(path):
    raw = Path(path).expanduser()
    if not raw.is_absolute():
        raw = Path.cwd() / raw
    parent = raw.parent.resolve()
    if raw.name in ("", ".", ".."):
        raise OSError(errno.EINVAL, "invalid destination name", str(raw))
    return parent, raw.name, parent / raw.name


def _open_verified_parent(path):
    parent, name, display = _path_parent(path)
    fd = _open_directory(parent)
    linked = os.stat(parent, follow_symlinks=False)
    opened = os.fstat(fd)
    if _identity(linked) != _identity(opened):
        os.close(fd)
        raise OSError(errno.ESTALE, "destination parent changed", str(parent))
    return fd, name, display, _identity(opened)


def _verify_parent_path(fd, parent, identity):
    linked = os.stat(parent, follow_symlinks=False)
    opened = os.fstat(fd)
    if (_identity(linked) != identity or _identity(opened) != identity
            or not stat.S_ISDIR(linked.st_mode)):
        raise OSError(errno.ESTALE, "destination parent changed", str(parent))


def _replace_at(source_name, destination_name, fd, display_parent):
    if os.replace in os.supports_dir_fd:
        os.replace(
            source_name, destination_name, src_dir_fd=fd, dst_dir_fd=fd)
    else:
        os.replace(display_parent / source_name,
                   display_parent / destination_name)


def _atomic_write_json(path, value):
    """Atomically replace JSON and report post-rename durability uncertainty."""
    retained_fd = None
    if isinstance(path, _AtPath):
        retained_fd = os.dup(path.dir_fd)
        name = path.name
        display = path.display
        parent = display.parent
        expected = _identity(os.fstat(retained_fd))
        verify = path.verify
    else:
        retained_fd, name, display, expected = _open_verified_parent(path)
        parent = display.parent
        verify = lambda: _verify_parent_path(retained_fd, parent, expected)
    temporary = f".{name}-{uuid.uuid4().hex}.tmp"
    committed = False
    try:
        if _entry_exists(retained_fd, name):
            target = os.stat(name, dir_fd=retained_fd, follow_symlinks=False)
            if not stat.S_ISREG(target.st_mode):
                raise OSError(errno.ELOOP, "destination is not a regular file", name)
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW,
            0o600,
            dir_fd=retained_fd,
        )
        try:
            payload = (json.dumps(value, indent=2, ensure_ascii=False)
                       + "\n").encode("utf-8")
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        _storage_test_hook("atomic_before_replace", path=display)
        if verify is not None:
            verify()
        _replace_at(temporary, name, retained_fd, parent)
        committed = True
        try:
            os.fsync(retained_fd)
        except OSError as exc:
            return _CommitResult(True, str(exc))
        return _CommitResult(True)
    except BaseException:
        if not committed:
            try:
                os.unlink(temporary, dir_fd=retained_fd)
            except OSError:
                pass
        raise
    finally:
        os.close(retained_fd)


def _read_json_path(path):
    fd, name, display, expected = _open_verified_parent(path)
    try:
        _verify_parent_path(fd, display.parent, expected)
        return _read_json_at(fd, name)
    finally:
        os.close(fd)


def _copy_durable(source, destination):
    """Compatibility copy used only by callers without retained descriptors."""
    source_fd, source_name, _, _ = _open_verified_parent(source)
    destination_fd, destination_name, _, _ = _open_verified_parent(destination)
    try:
        _copy_durable_at(source_fd, source_name, destination_fd,
                         destination_name)
    finally:
        os.close(source_fd)
        os.close(destination_fd)


def _copy_durable_at(source_fd, source_name, destination_fd, destination_name):
    src = _open_regular_at(source_fd, source_name)
    dst = os.open(
        destination_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW,
        0o600,
        dir_fd=destination_fd,
    )
    try:
        while True:
            chunk = os.read(src, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(dst, view)
                view = view[written:]
        os.fsync(dst)
    finally:
        os.close(src)
        os.close(dst)


def _rename_noreplace(source, destination):
    """Same-filesystem atomic rename that never replaces a target."""
    if isinstance(source, _AtPath) and isinstance(destination, _AtPath):
        source_fd = source.dir_fd
        destination_fd = destination.dir_fd
        source_name = os.fsencode(source.name)
        destination_name = os.fsencode(destination.name)
        libc = ctypes.CDLL(None, use_errno=True)
        if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
            function = libc.renameatx_np
            function.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                ctypes.c_char_p, ctypes.c_uint,
            ]
            function.restype = ctypes.c_int
            if function(source_fd, source_name, destination_fd,
                        destination_name, 0x00000004) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error), destination.name)
            return
        if sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
            function = libc.renameat2
            function.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                ctypes.c_char_p, ctypes.c_uint,
            ]
            function.restype = ctypes.c_int
            if function(source_fd, source_name, destination_fd,
                        destination_name, 1) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error), destination.name)
            return
        if _entry_exists(destination_fd, destination.name):
            raise FileExistsError(
                errno.EEXIST, os.strerror(errno.EEXIST), destination.name)
        os.rename(
            source.name, destination.name,
            src_dir_fd=source_fd, dst_dir_fd=destination_fd)
        return
    source = os.fsencode(source)
    destination = os.fsencode(destination)
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin" and hasattr(libc, "renamex_np"):
        function = libc.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        if function(source, destination, 0x00000004) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), os.fsdecode(destination))
        return
    if os.path.lexists(destination):
        raise FileExistsError(
            errno.EEXIST, os.strerror(errno.EEXIST), os.fsdecode(destination))
    os.rename(source, destination)


def _validate_wav_fd(fd):
    duplicate = os.dup(fd)
    try:
        try:
            import soundfile as sf
        except ImportError:
            with os.fdopen(duplicate, "rb") as source:
                duplicate = None
                with wave.open(source, "rb") as audio:
                    if (audio.getnchannels() <= 0 or audio.getframerate() <= 0
                            or audio.getnframes() <= 0):
                        raise ValueError("audio contains no decodable frames")
                    audio.readframes(1)
        else:
            owned_fd = duplicate
            duplicate = None
            with sf.SoundFile(owned_fd, closefd=True) as audio:
                if (audio.channels <= 0 or audio.samplerate <= 0
                        or len(audio) <= 0):
                    raise ValueError("audio contains no decodable frames")
                audio.seek(len(audio) - 1)
                if len(audio.read(
                        1, dtype="float32", always_2d=True)) != 1:
                    raise ValueError("audio contains no decodable frames")
    except Exception as exc:
        raise ManagementFailure(
            "voice_audio_invalid",
            "Voice reference audio is not a readable WAV file.",
            detail=str(exc), status=422) from exc
    finally:
        if duplicate is not None:
            os.close(duplicate)


def _validate_wav_bytes(payload):
    source = io.BytesIO(payload)
    try:
        try:
            import soundfile as sf
        except ImportError:
            with wave.open(source, "rb") as audio:
                if (audio.getnchannels() <= 0 or audio.getframerate() <= 0
                        or audio.getnframes() <= 0):
                    raise ValueError("audio contains no decodable frames")
                audio.readframes(1)
        else:
            with sf.SoundFile(source) as audio:
                if (audio.channels <= 0 or audio.samplerate <= 0
                        or len(audio) <= 0):
                    raise ValueError("audio contains no decodable frames")
                audio.seek(len(audio) - 1)
                if len(audio.read(
                        1, dtype="float32", always_2d=True)) != 1:
                    raise ValueError("audio contains no decodable frames")
    except Exception as exc:
        raise ManagementFailure(
            "voice_audio_invalid",
            "Voice reference audio is not a readable WAV file.",
            detail=str(exc), status=422) from exc


def _validate_wav(path):
    fd, name, _, _ = _open_verified_parent(path)
    try:
        audio = _open_regular_at(fd, name)
        try:
            _validate_wav_fd(audio)
        finally:
            os.close(audio)
    finally:
        os.close(fd)


def _safe_direct_child(parent, component, field):
    if (not isinstance(component, str) or not component or component in (".", "..")
            or component.startswith(".") or len(os.fsencode(component)) > 255
            or Path(component).name != component or "/" in component
            or "\\" in component or "\x00" in component):
        raise ManagementFailure(
            f"{field}_invalid",
            f"{field.replace('_', ' ').title()} is not a safe directory ID.",
            detail=f"{field} must name one non-hidden direct child",
            status=400,
        )
    return parent / component


def _operation_component(operation_id):
    if (isinstance(operation_id, str) and operation_id
            and not operation_id.startswith(".")
            and Path(operation_id).name == operation_id
            and "/" not in operation_id and "\\" not in operation_id
            and len(os.fsencode(operation_id)) <= 200):
        return operation_id
    if not isinstance(operation_id, str) or not operation_id:
        raise ManagementFailure(
            "request_id_required", "A nonempty request ID is required.",
            status=400)
    return "op-" + hashlib.sha256(operation_id.encode()).hexdigest()


class VoiceLibrary:
    """Daemon-owned profile discovery and descriptor-rooted transactions."""

    def __init__(self, root):
        configured = Path(root).expanduser()
        if not configured.is_absolute():
            configured = Path.cwd() / configured
        self._configured_root = configured
        self.root = configured.resolve()
        self.staging_root = self.root / ".staging"
        self.trash_root = self.root / ".trash"
        self.manifest_path = self.root / _MANIFEST_NAME
        self.pending_path = self.root / _PENDING_NAME
        self._lock = threading.RLock()
        self._revision = 0
        self._snapshot = VoiceLibrarySnapshot(0, ())
        self._profiles = {}
        self._migration_problems = ()
        self._initialized = False
        self._root_dir = None
        self._staging_dir = None
        self._trash_dir = None
        self._durability_diagnostic = None

    def __del__(self):
        for directory in (
                self._trash_dir, self._staging_dir, self._root_dir):
            try:
                if directory is not None:
                    directory.close()
            except OSError:
                pass

    @property
    def revision(self):
        with self._lock:
            return self._revision

    @property
    def migration_issues(self):
        with self._lock:
            return tuple(problem.issue for problem in self._migration_problems)

    @property
    def migration_failures(self):
        with self._lock:
            return tuple({
                "id": problem.profile_id,
                "issue": asdict(problem.issue),
            } for problem in self._migration_problems)

    @property
    def durability_diagnostic(self):
        with self._lock:
            return self._durability_diagnostic

    def initialize(self):
        with self._lock:
            if self._initialized:
                return self._scan_locked()
            self._ensure_directories()
            self._recover_pending_voice_locked()
            self._cleanup_stale_migration_staging()
            self._migration_problems = tuple(self._migrate_legacy_locked())
            self._initialized = True
            snapshot = self._scan_locked(force=True)
        self.resume_trash_cleanup()
        return snapshot

    def snapshot(self):
        with self._lock:
            if not self._initialized:
                return self.initialize()
            return self._scan_locked()

    def scan(self):
        return self.snapshot()

    def discover(self):
        return self.snapshot()

    def resolve_ready(self, profile_id):
        _validate_voice_id(profile_id)
        with self._lock:
            self._ensure_initialized()
            self._scan_locked()
            profile = self._profiles.get(profile_id)
            if profile is None:
                matching = next(
                    (voice for voice in self._snapshot.voices
                     if voice.id == profile_id), None)
                if matching is None:
                    raise ManagementFailure(
                        "voice_not_found", "Voice profile was not found.",
                        detail=profile_id, status=404)
                issue = matching.issues[0] if matching.issues else None
                raise ManagementFailure(
                    issue.code if issue else "voice_not_ready",
                    issue.message if issue else "Voice profile is not ready.",
                    detail=profile_id, status=409)
            self._verify_directories()
            return self._make_voice_profile(profile)

    def migrate_legacy(self):
        with self._lock:
            self._ensure_directories()
            self._recover_pending_voice_locked()
            self._migration_problems = tuple(self._migrate_legacy_locked())
            self._initialized = True
            return self._scan_locked(force=True)

    def import_staged(self, staging_id, profile_id, display_name, operation_id):
        del operation_id
        stage_fd = None
        stage_identity = None
        committed = False
        _safe_direct_child(self.staging_root, staging_id, "staging_id")
        try:
            with self._lock:
                self._ensure_initialized()
                self._verify_directories()
                try:
                    stage_fd = _open_directory(
                        staging_id, dir_fd=self._staging_dir.fd)
                except (FileNotFoundError, NotADirectoryError, OSError) as exc:
                    raise ManagementFailure(
                        "staged_import_not_found",
                        "The staged voice import was not found.",
                        detail=staging_id, status=404) from exc
                stage_stat = os.fstat(stage_fd)
                stage_identity = _identity(stage_stat)
                if stage_stat.st_dev != self._root_dir.identity[0]:
                    raise _unsafe_library("Staging child is on another device.")
                _validate_voice_id(profile_id)
                display_name = _validate_display_name(display_name)
                if _entry_exists(self._root_dir.fd, profile_id):
                    raise ManagementFailure(
                        "voice_id_collision",
                        "A voice with that ID already exists.",
                        detail=profile_id, status=409)
                verify_stage = lambda: self._verify_child(
                    self._staging_dir, staging_id, stage_identity)
                self._write_profile_metadata(
                    stage_fd, self.staging_root / staging_id,
                    profile_id, display_name, verify_stage)
                validated = self._validate_profile_fd(
                    stage_fd, self.staging_root / staging_id,
                    profile_id, expected_id=profile_id)
                if validated.entry.status != "ready":
                    issue = validated.entry.issues[0]
                    raise ManagementFailure(
                        issue.code, issue.message, detail=profile_id,
                        status=422)
                os.fsync(stage_fd)
                _storage_test_hook(
                    "import_before_rename", root=self.root,
                    staging_id=staging_id, profile_id=profile_id)
                verify_stage()
                self._verify_directories()
                try:
                    _rename_noreplace(
                        _AtPath(self._staging_dir.fd, staging_id,
                                self.staging_root / staging_id, verify_stage),
                        _AtPath(self._root_dir.fd, profile_id,
                                self.root / profile_id,
                                self._verify_directories),
                    )
                    committed = True
                except FileExistsError as exc:
                    raise ManagementFailure(
                        "voice_id_collision",
                        "A voice with that ID already exists.",
                        detail=profile_id, status=409) from exc
                except OSError as exc:
                    raise ManagementFailure(
                        "voice_import_commit_failed",
                        "Voice import could not be committed.",
                        detail=str(exc), status=500) from exc
                self._record_fsync(self._root_dir.fd)
                self._record_fsync(self._staging_dir.fd)
                self._scan_locked(force=True)
                return self.resolve_ready(profile_id)
        except BaseException as original:
            if not committed and stage_identity is not None:
                with self._lock:
                    try:
                        self._remove_child_tree(
                            self._staging_dir, staging_id, stage_identity,
                            strict=True)
                    except ManagementFailure:
                        if not isinstance(original, ManagementFailure):
                            raise
            raise original
        finally:
            if stage_fd is not None:
                os.close(stage_fd)

    def update_metadata(self, profile_id, display_name):
        _validate_voice_id(profile_id)
        display_name = _validate_display_name(display_name)
        with self._lock:
            self._ensure_initialized()
            self.resolve_ready(profile_id)
            profile_fd, identity = self._open_profile(profile_id)
            try:
                verify = lambda: self._verify_child(
                    self._root_dir, profile_id, identity)
                try:
                    result = self._write_profile_metadata(
                        profile_fd, self.root / profile_id,
                        profile_id, display_name, verify)
                except OSError as exc:
                    raise ManagementFailure(
                        "voice_metadata_write_failed",
                        "Voice metadata could not be saved.",
                        detail=str(exc), status=500) from exc
                self._remember_commit(result)
                validated = self._validate_profile_fd(
                    profile_fd, self.root / profile_id, profile_id)
                if validated.entry.status != "ready":
                    issue = validated.entry.issues[0]
                    raise ManagementFailure(
                        issue.code, issue.message, detail=profile_id,
                        status=422)
                verify()
            finally:
                os.close(profile_fd)
            self._scan_locked(force=True)
            return self.resolve_ready(profile_id)

    def delete(self, profile_id, operation_id, *, active_voice=None,
               is_captured=None, defer_cleanup=True):
        _validate_voice_id(profile_id)
        trash_name = _operation_component(operation_id)
        trash_identity = None
        with self._lock:
            self._ensure_initialized()
            self._verify_directories()
            try:
                source_fd, source_identity = self._open_profile(profile_id)
            except (FileNotFoundError, NotADirectoryError, OSError) as exc:
                raise ManagementFailure(
                    "voice_not_found", "Voice profile was not found.",
                    detail=profile_id, status=404) from exc
            try:
                if active_voice == profile_id:
                    raise ManagementFailure(
                        "voice_delete_active",
                        "The active voice cannot be deleted.",
                        detail=profile_id, status=409)
                captured = (is_captured(profile_id) if callable(is_captured)
                            else bool(is_captured))
                if captured:
                    raise ManagementFailure(
                        "voice_delete_in_use",
                        "This voice is still used by queued or in-flight speech.",
                        detail=profile_id, status=409)
                if _entry_exists(self._trash_dir.fd, trash_name):
                    raise ManagementFailure(
                        "voice_trash_collision",
                        "This delete request already has retained trash.",
                        detail=operation_id, status=409)
                verify_source = lambda: self._verify_child(
                    self._root_dir, profile_id, source_identity)
                _storage_test_hook(
                    "delete_before_rename", root=self.root,
                    profile_id=profile_id, trash_name=trash_name)
                verify_source()
                try:
                    _rename_noreplace(
                        _AtPath(self._root_dir.fd, profile_id,
                                self.root / profile_id, verify_source),
                        _AtPath(self._trash_dir.fd, trash_name,
                                self.trash_root / trash_name,
                                self._verify_directories),
                    )
                except OSError as exc:
                    raise ManagementFailure(
                        "voice_delete_commit_failed",
                        "Voice deletion could not be committed.",
                        detail=str(exc), status=500) from exc
            finally:
                os.close(source_fd)
            moved = os.stat(
                trash_name, dir_fd=self._trash_dir.fd,
                follow_symlinks=False)
            trash_identity = _identity(moved)
            self._record_fsync(self._root_dir.fd)
            self._record_fsync(self._trash_dir.fd)
            self._scan_locked(force=True)
            snapshot = self._snapshot
        if defer_cleanup:
            threading.Thread(
                target=self._remove_trash_identity,
                args=(trash_name, trash_identity), daemon=True,
                name="voice-trash-cleanup").start()
        return snapshot

    def cleanup_trash(self):
        self._cleanup_trash_snapshot(self._trash_snapshot())

    def resume_trash_cleanup(self):
        children = self._trash_snapshot()
        if not children:
            return
        threading.Thread(
            target=self._cleanup_trash_snapshot, args=(children,),
            daemon=True, name="voice-trash-resume").start()

    def _trash_snapshot(self):
        with self._lock:
            self._ensure_directories()
            self._verify_directories()
            children = []
            for name in os.listdir(self._trash_dir.fd):
                if name.startswith("."):
                    continue
                linked = os.stat(
                    name, dir_fd=self._trash_dir.fd,
                    follow_symlinks=False)
                children.append((name, _identity(linked)))
            return tuple(children)

    def _cleanup_trash_snapshot(self, children):
        for name, identity in children:
            self._remove_trash_identity(name, identity)

    def record_legacy_config(self, path):
        with self._lock:
            manifest = self._load_manifest()
            manifest["legacy_config"] = str(Path(path).expanduser().resolve())
            self._remember_commit(self._write_manifest(manifest))

    def cleanup_migration_backups(self, legacy_config_path=None):
        """Remove only manifest-confirmed backups after the first Ready.

        The manifest is updated after each cleanup unit so interruption is
        resumable. Legacy voice files are removed only while they still match
        the committed ready profile. The config path must match the launcher's
        exact migration source.
        """
        with self._lock:
            self._ensure_initialized()
            manifest = self._load_manifest()
            for item in tuple(manifest["legacy_voice_sources"]):
                self._cleanup_voice_backup(item)
                manifest["legacy_voice_sources"].remove(item)
                self._persist_cleanup_manifest(manifest)

            recorded_config = manifest["legacy_config"]
            if recorded_config is not None:
                if legacy_config_path is None:
                    raise ManagementFailure(
                        "migration_backup_unconfirmed",
                        "The legacy configuration backup was not removed.",
                        detail="No migration source path was provided.",
                        status=409)
                expected = str(Path(
                    legacy_config_path).expanduser().resolve())
                if recorded_config != expected:
                    raise ManagementFailure(
                        "migration_backup_unconfirmed",
                        "The legacy configuration backup was not removed.",
                        detail=recorded_config, status=409)
                self._cleanup_config_backup(Path(recorded_config))
                manifest["legacy_config"] = None
                self._persist_cleanup_manifest(manifest)

            if (not manifest["legacy_voice_sources"]
                    and manifest["legacy_config"] is None):
                try:
                    _storage_test_hook(
                        "backup_cleanup_before_manifest",
                        manifest_path=self.manifest_path)
                    self._verify_directories()
                    os.unlink(_MANIFEST_NAME, dir_fd=self._root_dir.fd)
                    self._record_fsync(self._root_dir.fd)
                except FileNotFoundError:
                    pass
                except OSError as exc:
                    raise ManagementFailure(
                        "migration_backup_cleanup_failed",
                        "Migration backup cleanup could not finish.",
                        detail=str(exc), status=500) from exc

    def _persist_cleanup_manifest(self, manifest):
        try:
            self._remember_commit(self._write_manifest(manifest))
        except OSError as exc:
            raise ManagementFailure(
                "migration_backup_cleanup_failed",
                "Migration backup cleanup could not be recorded.",
                detail=str(exc), status=500) from exc

    def _cleanup_voice_backup(self, item):
        profile_id = item["id"]
        expected_names = {
            "wav": f"{profile_id}.wav",
            "transcript": f"{profile_id}.txt",
        }
        try:
            profile_fd, profile_identity = self._open_profile(profile_id)
        except (FileNotFoundError, NotADirectoryError, OSError) as exc:
            raise ManagementFailure(
                "migration_backup_unconfirmed",
                "Legacy voice backups were not removed.",
                detail=profile_id, status=409) from exc
        try:
            validated = self._validate_profile_fd(
                profile_fd, self.root / profile_id, profile_id)
            if validated.entry.status != "ready":
                raise ManagementFailure(
                    "migration_backup_unconfirmed",
                    "Legacy voice backups were not removed.",
                    detail=profile_id, status=409)
            expected_content = {
                "wav": _read_bytes_at(profile_fd, "reference.wav"),
                "transcript": _read_bytes_at(profile_fd, "transcript.txt"),
            }
            self._verify_child(
                self._root_dir, profile_id, profile_identity)
        finally:
            os.close(profile_fd)

        backups = []
        for field, name in expected_names.items():
            recorded = item[field]
            if recorded != str((self.root / name).resolve()):
                raise ManagementFailure(
                    "migration_backup_unconfirmed",
                    "Legacy voice backups were not removed.",
                    detail=recorded, status=409)
            try:
                linked = os.stat(
                    name, dir_fd=self._root_dir.fd,
                    follow_symlinks=False)
            except FileNotFoundError:
                continue
            if (not stat.S_ISREG(linked.st_mode)
                    or _read_bytes_at(self._root_dir.fd, name)
                    != expected_content[field]):
                raise ManagementFailure(
                    "migration_backup_unconfirmed",
                    "A legacy voice backup changed after migration.",
                    detail=recorded, status=409)
            backups.append((name, _identity(linked)))

        for name, identity in backups:
            try:
                _storage_test_hook(
                    "backup_cleanup_before_voice_unlink",
                    root=self.root, name=name)
                self._verify_directories()
                current = os.stat(
                    name, dir_fd=self._root_dir.fd,
                    follow_symlinks=False)
                if (_identity(current) != identity
                        or not stat.S_ISREG(current.st_mode)):
                    raise OSError(
                        errno.ESTALE, "legacy voice backup changed", name)
                os.unlink(name, dir_fd=self._root_dir.fd)
                self._record_fsync(self._root_dir.fd)
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise ManagementFailure(
                    "migration_backup_cleanup_failed",
                    "Legacy voice backup cleanup failed.",
                    detail=str(exc), status=500) from exc

    def _cleanup_config_backup(self, path):
        parent_fd = None
        try:
            parent_fd, name, _, expected = _open_verified_parent(path)
            try:
                linked = os.stat(
                    name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                return
            if not stat.S_ISREG(linked.st_mode):
                raise ManagementFailure(
                    "migration_backup_unconfirmed",
                    "The legacy configuration backup was not removed.",
                    detail=str(path), status=409)
            identity = _identity(linked)
            _storage_test_hook(
                "backup_cleanup_before_config_unlink", path=path)
            _verify_parent_path(parent_fd, path.parent, expected)
            current = os.stat(
                name, dir_fd=parent_fd, follow_symlinks=False)
            if (_identity(current) != identity
                    or not stat.S_ISREG(current.st_mode)):
                raise OSError(
                    errno.ESTALE, "legacy configuration changed", str(path))
            os.unlink(name, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except ManagementFailure:
            raise
        except FileNotFoundError:
            return
        except OSError as exc:
            raise ManagementFailure(
                "migration_backup_cleanup_failed",
                "Legacy configuration backup cleanup failed.",
                detail=str(exc), status=500) from exc
        finally:
            if parent_fd is not None:
                os.close(parent_fd)

    def begin_legacy_config(self, legacy_path, settings_path, settings):
        with self._lock:
            pending = {
                "schema_version": SCHEMA_VERSION,
                "kind": "settings",
                "legacy_config": str(legacy_path),
                "settings_path": str(settings_path),
                "settings": settings,
            }
            existing = self._load_pending()
            if existing is not None and existing != pending:
                raise ManagementFailure(
                    "migration_pending_conflict",
                    "A different migration is awaiting recovery.",
                    status=409)
            if existing is None:
                self._remember_commit(self._write_pending(pending))

    def recover_legacy_config(self, legacy_path, settings_path):
        with self._lock:
            pending = self._load_pending()
            if pending is None:
                return False
            if pending.get("kind") != "settings":
                self._recover_pending_voice_locked()
                return False
            if (pending.get("legacy_config") != str(legacy_path)
                    or pending.get("settings_path") != str(settings_path)):
                raise ManagementFailure(
                    "migration_pending_conflict",
                    "Pending settings migration does not match this store.",
                    status=409)
            try:
                actual = _read_json_path(settings_path)
            except FileNotFoundError:
                self._clear_pending()
                return False
            except (OSError, UnicodeError, ValueError) as exc:
                raise ManagementFailure(
                    "migration_pending_invalid",
                    "Pending settings migration could not be verified.",
                    detail=str(exc), status=409) from exc
            if actual != pending.get("settings"):
                raise ManagementFailure(
                    "migration_pending_collision",
                    "Existing settings do not match the pending migration.",
                    status=409)
            manifest = self._load_manifest()
            manifest["legacy_config"] = str(legacy_path)
            self._remember_commit(self._write_manifest(manifest))
            self._clear_pending()
            return True

    def _ensure_directories(self):
        if self._configured_root.is_symlink():
            raise _unsafe_library("The configured library root is a symlink.")
        self.root.mkdir(parents=True, exist_ok=True)
        if self._root_dir is None:
            try:
                root_fd = _open_directory(self.root)
                self._root_dir = _RetainedDirectory(self.root, root_fd)
                self._root_dir.verify()
            except OSError as exc:
                raise _unsafe_library(str(exc)) from exc
        for name, attribute, path in (
                (".staging", "_staging_dir", self.staging_root),
                (".trash", "_trash_dir", self.trash_root)):
            if getattr(self, attribute) is not None:
                continue
            try:
                if not _entry_exists(self._root_dir.fd, name):
                    os.mkdir(name, mode=0o700, dir_fd=self._root_dir.fd)
                    os.fsync(self._root_dir.fd)
                fd = _open_directory(name, dir_fd=self._root_dir.fd)
                directory = _RetainedDirectory(
                    path, fd, parent=self._root_dir, name=name)
                if directory.identity[0] != self._root_dir.identity[0]:
                    directory.close()
                    raise OSError(errno.EXDEV, "control directory is a mount")
                directory.verify()
                setattr(self, attribute, directory)
            except OSError as exc:
                raise _unsafe_library(f"{name}: {exc}") from exc

    def cleanup(self):
        self.cleanup_trash()

    def _ensure_initialized(self):
        if not self._initialized:
            self.initialize()

    def _verify_directories(self):
        self._root_dir.verify()
        self._staging_dir.verify()
        self._trash_dir.verify()

    def _verify_child(self, parent, name, expected):
        parent.verify()
        linked = os.stat(name, dir_fd=parent.fd, follow_symlinks=False)
        if (not stat.S_ISDIR(linked.st_mode)
                or _identity(linked) != expected
                or linked.st_dev != self._root_dir.identity[0]):
            raise _unsafe_library(f"Directory '{name}' was replaced.")

    def _open_profile(self, profile_id):
        self._verify_directories()
        fd = _open_directory(profile_id, dir_fd=self._root_dir.fd)
        linked = os.stat(
            profile_id, dir_fd=self._root_dir.fd, follow_symlinks=False)
        opened = os.fstat(fd)
        if (_identity(linked) != _identity(opened)
                or opened.st_dev != self._root_dir.identity[0]):
            os.close(fd)
            raise _unsafe_library(f"Profile '{profile_id}' was replaced.")
        return fd, _identity(opened)

    def _scan_locked(self, force=False):
        self._ensure_directories()
        self._verify_directories()
        entries = {}
        profiles = {}
        for name in sorted(os.listdir(self._root_dir.fd)):
            if name.startswith("."):
                continue
            try:
                linked = os.stat(
                    name, dir_fd=self._root_dir.fd,
                    follow_symlinks=False)
            except OSError:
                continue
            if (not stat.S_ISDIR(linked.st_mode)
                    or linked.st_dev != self._root_dir.identity[0]):
                continue
            try:
                fd, identity = self._open_profile(name)
            except OSError:
                continue
            try:
                validated = self._validate_profile_fd(
                    fd, self.root / name, name)
                self._verify_child(self._root_dir, name, identity)
            finally:
                os.close(fd)
            entries[name] = validated.entry
            if validated.entry.status == "ready":
                profiles[name] = validated

        manifest = self._load_manifest()
        migrated_sources = {
            (item.get("id"), item.get("wav"), item.get("transcript"))
            for item in manifest["legacy_voice_sources"]
            if isinstance(item, dict)
        }
        legacy = self._legacy_candidates()
        problems = {problem.profile_id: problem.issue
                    for problem in self._migration_problems}
        for profile_id, pair in legacy.items():
            wav = pair.get("wav")
            transcript = pair.get("transcript")
            source_key = self._source_key(profile_id, wav, transcript)
            if source_key in migrated_sources and profile_id in entries:
                continue
            if profile_id in entries:
                issue = VoiceIssue(
                    "legacy_voice_collision", "id",
                    f"Legacy voice '{profile_id}' collides with an existing "
                    "profile and was not migrated.")
                old = entries[profile_id]
                entries[profile_id] = replace(
                    old, issues=old.issues + (issue,))
                continue
            if not _valid_voice_id(profile_id):
                issue = VoiceIssue(
                    "voice_id_invalid", "id",
                    "Legacy voice ID must use 1-32 lowercase letters, digits, "
                    "'-' or '_'.")
                entries[profile_id] = VoiceLibraryEntry(
                    profile_id, profile_id, "invalid", (issue,))
            elif wav is None:
                issue = VoiceIssue(
                    "voice_audio_missing", "audio",
                    f"{profile_id} needs a reference WAV file.")
                entries[profile_id] = VoiceLibraryEntry(
                    profile_id, profile_id, "incomplete", (issue,))
            elif transcript is None:
                issue = VoiceIssue(
                    "voice_transcript_missing", "transcript",
                    f"{profile_id} needs a transcript file.")
                entries[profile_id] = VoiceLibraryEntry(
                    profile_id, profile_id, "incomplete", (issue,))
            else:
                issue = problems.get(profile_id) or VoiceIssue(
                    "legacy_voice_unmigrated", "profile",
                    f"Legacy voice '{profile_id}' has not been migrated.")
                entries[profile_id] = VoiceLibraryEntry(
                    profile_id, profile_id, "invalid", (issue,))

        new_voices = tuple(entries[key] for key in sorted(entries))
        if force or new_voices != self._snapshot.voices:
            self._revision += 1
            self._snapshot = VoiceLibrarySnapshot(self._revision, new_voices)
        self._profiles = profiles
        return self._snapshot

    def _validate_profile_fd(self, fd, root, profile_id, expected_id=None):
        expected_id = expected_id or profile_id
        display_name = profile_id
        issues = []
        if not _valid_voice_id(profile_id):
            issues.append(VoiceIssue(
                "voice_id_invalid", "id",
                "Voice ID must use 1-32 lowercase letters, digits, '-' or '_'."))
        metadata = None
        try:
            metadata = _read_json_at(
                fd, "profile.json", MAX_PROFILE_METADATA_BYTES)
        except FileNotFoundError:
            issues.append(VoiceIssue(
                "voice_metadata_missing", "profile",
                f"{profile_id} needs profile metadata."))
        except _FileTooLarge:
            issues.append(VoiceIssue(
                "voice_metadata_too_large", "profile",
                f"{profile_id} profile metadata is too large."))
        except (OSError, UnicodeError, ValueError):
            issues.append(VoiceIssue(
                "voice_metadata_invalid", "profile",
                f"{profile_id} has invalid profile metadata."))
        if metadata is not None:
            if not isinstance(metadata, dict) or set(metadata) != PROFILE_FIELDS:
                issues.append(VoiceIssue(
                    "voice_metadata_invalid", "profile",
                    f"{profile_id} has invalid profile metadata."))
            else:
                display_name = metadata.get("display_name", profile_id)
                if (metadata.get("schema_version") != SCHEMA_VERSION
                        or isinstance(metadata.get("schema_version"), bool)):
                    issues.append(VoiceIssue(
                        "voice_schema_unsupported", "schema_version",
                        f"{profile_id} uses unsupported profile metadata."))
                if metadata.get("id") != expected_id:
                    issues.append(VoiceIssue(
                        "voice_metadata_id_mismatch", "id",
                        f"{profile_id} metadata does not match its directory."))
                if (not isinstance(display_name, str)
                        or not display_name.strip()
                        or len(display_name) > 128):
                    display_name = profile_id
                    issues.append(VoiceIssue(
                        "voice_display_name_invalid", "display_name",
                        f"{profile_id} has an invalid display name."))
                else:
                    display_name = display_name.strip()

        missing = False
        audio_fd = transcript_fd = None
        try:
            try:
                audio_fd = _open_regular_at(fd, "reference.wav")
            except (FileNotFoundError, OSError):
                missing = True
                issues.append(VoiceIssue(
                    "voice_audio_missing", "audio",
                    f"{display_name} needs a reference WAV file."))
            try:
                transcript_fd = _open_regular_at(fd, "transcript.txt")
            except (FileNotFoundError, OSError):
                missing = True
                issues.append(VoiceIssue(
                    "voice_transcript_missing", "transcript",
                    f"{display_name} needs a transcript file."))
            transcript_text = ""
            if transcript_fd is not None:
                try:
                    transcript_text = _read_fd(
                        transcript_fd, MAX_TRANSCRIPT_BYTES).decode(
                            "utf-8").strip()
                except _FileTooLarge:
                    issues.append(VoiceIssue(
                        "voice_transcript_too_large", "transcript",
                        f"{display_name} transcript is too large."))
                except (OSError, UnicodeError):
                    issues.append(VoiceIssue(
                        "voice_transcript_invalid", "transcript",
                        f"{display_name} has an unreadable transcript."))
                else:
                    if not transcript_text:
                        issues.append(VoiceIssue(
                            "voice_transcript_empty", "transcript",
                            f"{display_name} needs a nonempty transcript."))
            if audio_fd is not None:
                if os.fstat(audio_fd).st_size > MAX_REFERENCE_WAV_BYTES:
                    issues.append(VoiceIssue(
                        "voice_audio_too_large", "audio",
                        f"{display_name} reference audio is too large."))
                else:
                    try:
                        _validate_wav_fd(audio_fd)
                    except ManagementFailure:
                        issues.append(VoiceIssue(
                            "voice_audio_invalid", "audio",
                            f"{display_name} has unreadable reference audio."))
        finally:
            if audio_fd is not None:
                os.close(audio_fd)
            if transcript_fd is not None:
                os.close(transcript_fd)

        status = "ready"
        if issues:
            status = "incomplete" if missing else "invalid"
        entry = VoiceLibraryEntry(profile_id, display_name, status, tuple(issues))
        return _ValidatedProfile(
            entry, root, root / "reference.wav", root / "transcript.txt",
            transcript_text)

    def _make_voice_profile(self, validated):
        profile_id = validated.entry.id
        _storage_test_hook(
            "resolve_before_capture", root=self.root,
            profile_id=profile_id)
        profile_fd, profile_identity = self._open_profile(profile_id)
        audio_fd = transcript_fd = None
        try:
            audio_fd = _open_regular_at(profile_fd, "reference.wav")
            transcript_fd = _open_regular_at(profile_fd, "transcript.txt")
            try:
                audio = _read_fd(audio_fd, MAX_REFERENCE_WAV_BYTES)
            except _FileTooLarge as exc:
                raise ManagementFailure(
                    "voice_audio_too_large",
                    f"{validated.entry.display_name} reference audio is "
                    "too large.",
                    detail={"size": exc.size, "limit": exc.limit},
                    status=422) from exc
            try:
                transcript = _read_fd(
                    transcript_fd, MAX_TRANSCRIPT_BYTES).decode(
                        "utf-8").strip()
            except _FileTooLarge as exc:
                raise ManagementFailure(
                    "voice_transcript_too_large",
                    f"{validated.entry.display_name} transcript is too large.",
                    detail={"size": exc.size, "limit": exc.limit},
                    status=422) from exc
            except UnicodeError as exc:
                raise ManagementFailure(
                    "voice_transcript_invalid",
                    f"{validated.entry.display_name} has an unreadable "
                    "transcript.",
                    detail=str(exc), status=422) from exc
            if not transcript:
                raise ManagementFailure(
                    "voice_transcript_empty",
                    f"{validated.entry.display_name} needs a nonempty "
                    "transcript.",
                    status=422)
            _validate_wav_bytes(audio)
            self._verify_child(
                self._root_dir, profile_id, profile_identity)
        except ManagementFailure:
            raise
        except OSError as exc:
            raise ManagementFailure(
                "voice_profile_changed",
                "Voice profile changed while it was being prepared.",
                detail=profile_id, status=409) from exc
        finally:
            if audio_fd is not None:
                os.close(audio_fd)
            if transcript_fd is not None:
                os.close(transcript_fd)
            os.close(profile_fd)

        module = next(
            (candidate for name, candidate in tuple(sys.modules.items())
             if (name == "serve" or name.endswith(".serve"))
             and hasattr(candidate, "VoiceProfile")),
            None,
        )
        if module is None:
            candidate = sys.modules.get("__main__")
            source = getattr(candidate, "__file__", "") if candidate else ""
            if Path(source).stem != "serve" or not hasattr(
                    candidate, "VoiceProfile"):
                raise RuntimeError("serve.VoiceProfile is not loaded")
            module = candidate
        return module.VoiceProfile(
            id=profile_id,
            display_name=validated.entry.display_name,
            root_path=str(validated.root),
            audio_path=str(validated.audio),
            transcript_path=str(validated.transcript),
            transcript=transcript,
            audio=audio,
        )

    def _write_profile_metadata(self, fd, root, profile_id, display_name,
                                verify=None):
        result = _atomic_write_json(_AtPath(
            fd, "profile.json", root / "profile.json", verify), {
                "schema_version": SCHEMA_VERSION,
                "id": profile_id,
                "display_name": display_name,
            })
        self._remember_commit(result)
        return result

    def _legacy_candidates(self):
        candidates = {}
        for name in os.listdir(self._root_dir.fd):
            if name.startswith("."):
                continue
            try:
                linked = os.stat(
                    name, dir_fd=self._root_dir.fd,
                    follow_symlinks=False)
            except OSError:
                continue
            if not stat.S_ISREG(linked.st_mode):
                continue
            path = Path(name)
            if path.suffix == ".wav":
                candidates.setdefault(path.stem, {})["wav"] = name
            elif path.suffix == ".txt":
                candidates.setdefault(path.stem, {})["transcript"] = name
        return candidates

    def _source_key(self, profile_id, wav, transcript):
        return (
            profile_id,
            str((self.root / wav).resolve()) if wav else None,
            str((self.root / transcript).resolve()) if transcript else None,
        )

    def _migrate_legacy_locked(self):
        pending = self._load_pending()
        if pending is not None and pending.get("kind") == "settings":
            return []
        manifest = self._load_manifest()
        recorded = {
            (item.get("id"), item.get("wav"), item.get("transcript"))
            for item in manifest["legacy_voice_sources"]
            if isinstance(item, dict)
        }
        problems = []
        for profile_id, pair in sorted(self._legacy_candidates().items()):
            wav = pair.get("wav")
            transcript = pair.get("transcript")
            source_key = self._source_key(profile_id, wav, transcript)
            if source_key in recorded and _entry_exists(
                    self._root_dir.fd, profile_id):
                continue
            if wav is None:
                problems.append(_MigrationProblem(profile_id, VoiceIssue(
                    "voice_audio_missing", "audio",
                    f"{profile_id} needs a reference WAV file.")))
                continue
            if transcript is None:
                problems.append(_MigrationProblem(profile_id, VoiceIssue(
                    "voice_transcript_missing", "transcript",
                    f"{profile_id} needs a transcript file.")))
                continue
            if not _valid_voice_id(profile_id):
                problems.append(_MigrationProblem(profile_id, VoiceIssue(
                    "voice_id_invalid", "id",
                    "Legacy voice ID must use 1-32 lowercase letters, digits, "
                    "'-' or '_'.")))
                continue
            if _entry_exists(self._root_dir.fd, profile_id):
                problems.append(_MigrationProblem(profile_id, VoiceIssue(
                    "legacy_voice_collision", "id",
                    f"Legacy voice '{profile_id}' collides with an existing "
                    "profile and was not migrated.")))
                continue
            stage_name = f"migration-{uuid.uuid4().hex}"
            stage_fd = None
            stage_identity = None
            item = {
                "id": profile_id,
                "wav": str((self.root / wav).resolve()),
                "transcript": str((self.root / transcript).resolve()),
            }
            try:
                os.mkdir(stage_name, mode=0o700, dir_fd=self._staging_dir.fd)
                stage_fd = _open_directory(
                    stage_name, dir_fd=self._staging_dir.fd)
                stage_identity = _identity(os.fstat(stage_fd))
                _copy_durable_at(
                    self._root_dir.fd, wav, stage_fd, "reference.wav")
                _copy_durable_at(
                    self._root_dir.fd, transcript, stage_fd,
                    "transcript.txt")
                verify_stage = lambda: self._verify_child(
                    self._staging_dir, stage_name, stage_identity)
                self._write_profile_metadata(
                    stage_fd, self.staging_root / stage_name,
                    profile_id, profile_id, verify_stage)
                validated = self._validate_profile_fd(
                    stage_fd, self.staging_root / stage_name,
                    profile_id, expected_id=profile_id)
                if validated.entry.status != "ready":
                    issue = validated.entry.issues[0]
                    raise ManagementFailure(
                        issue.code, issue.message, detail=profile_id, status=422)
                os.fsync(stage_fd)
                pending_value = {
                    "schema_version": SCHEMA_VERSION,
                    "kind": "voice",
                    "voice": item,
                }
                self._remember_commit(self._write_pending(pending_value))
                _storage_test_hook(
                    "migration_before_rename", root=self.root,
                    staging_id=stage_name, profile_id=profile_id)
                verify_stage()
                self._verify_directories()
                _rename_noreplace(
                    _AtPath(self._staging_dir.fd, stage_name,
                            self.staging_root / stage_name, verify_stage),
                    _AtPath(self._root_dir.fd, profile_id,
                            self.root / profile_id, self._verify_directories),
                )
                self._record_fsync(self._root_dir.fd)
                self._record_fsync(self._staging_dir.fd)
                _storage_test_hook(
                    "migration_after_rename", root=self.root,
                    profile_id=profile_id)
                self._recover_pending_voice_locked()
                recorded.add(source_key)
            except BaseException as exc:
                if stage_identity is not None:
                    self._remove_child_tree(
                        self._staging_dir, stage_name, stage_identity,
                        strict=False)
                if isinstance(exc, ManagementFailure):
                    issue = VoiceIssue(
                        exc.code, _field_for_code(exc.code), exc.message)
                elif isinstance(exc, FileExistsError):
                    issue = VoiceIssue(
                        "legacy_voice_collision", "id",
                        f"Legacy voice '{profile_id}' collided during migration.")
                else:
                    issue = VoiceIssue(
                        "legacy_voice_migration_failed", "profile",
                        f"Legacy voice '{profile_id}' could not be migrated.")
                problems.append(_MigrationProblem(profile_id, issue))
            finally:
                if stage_fd is not None:
                    os.close(stage_fd)
        return problems

    def _load_manifest(self):
        if not _entry_exists(self._root_dir.fd, _MANIFEST_NAME):
            return {
                "schema_version": SCHEMA_VERSION,
                "legacy_voice_sources": [],
                "legacy_config": None,
            }
        try:
            raw = _read_json_at(self._root_dir.fd, _MANIFEST_NAME)
        except (OSError, UnicodeError, ValueError) as exc:
            raise ManagementFailure(
                "migration_manifest_invalid",
                "The migration backup manifest is invalid.",
                detail=str(exc), status=500) from exc
        voice_sources = (
            raw.get("legacy_voice_sources") if isinstance(raw, dict) else None)
        valid_sources = (
            isinstance(voice_sources, list)
            and all(
                isinstance(item, dict)
                and set(item) == {"id", "wav", "transcript"}
                and _valid_voice_id(item["id"])
                and isinstance(item["wav"], str)
                and isinstance(item["transcript"], str)
                for item in voice_sources
            )
        )
        if (not isinstance(raw, dict)
                or set(raw) != {"schema_version", "legacy_voice_sources",
                                "legacy_config"}
                or raw.get("schema_version") != SCHEMA_VERSION
                or not valid_sources
                or (raw.get("legacy_config") is not None
                    and not isinstance(raw.get("legacy_config"), str))):
            raise ManagementFailure(
                "migration_manifest_invalid",
                "The migration backup manifest is invalid.", status=500)
        return raw

    def _write_manifest(self, manifest):
        return _atomic_write_json(_AtPath(
            self._root_dir.fd, _MANIFEST_NAME, self.manifest_path,
            self._verify_directories), manifest)

    def _load_pending(self):
        if not _entry_exists(self._root_dir.fd, _PENDING_NAME):
            return None
        try:
            raw = _read_json_at(self._root_dir.fd, _PENDING_NAME)
        except (OSError, UnicodeError, ValueError) as exc:
            raise ManagementFailure(
                "migration_pending_invalid",
                "The pending migration journal is invalid.",
                detail=str(exc), status=500) from exc
        valid_voice = (
            isinstance(raw, dict)
            and set(raw) == {"schema_version", "kind", "voice"}
            and raw.get("schema_version") == SCHEMA_VERSION
            and raw.get("kind") == "voice"
            and isinstance(raw.get("voice"), dict)
            and set(raw["voice"]) == {"id", "wav", "transcript"}
            and _valid_voice_id(raw["voice"].get("id"))
            and isinstance(raw["voice"].get("wav"), str)
            and isinstance(raw["voice"].get("transcript"), str)
        )
        valid_settings = (
            isinstance(raw, dict)
            and set(raw) == {
                "schema_version", "kind", "legacy_config",
                "settings_path", "settings"}
            and raw.get("schema_version") == SCHEMA_VERSION
            and raw.get("kind") == "settings"
            and isinstance(raw.get("legacy_config"), str)
            and isinstance(raw.get("settings_path"), str)
            and isinstance(raw.get("settings"), dict)
        )
        if not valid_voice and not valid_settings:
            raise ManagementFailure(
                "migration_pending_invalid",
                "The pending migration journal is invalid.", status=500)
        return raw

    def _write_pending(self, pending):
        return _atomic_write_json(_AtPath(
            self._root_dir.fd, _PENDING_NAME, self.pending_path,
            self._verify_directories), pending)

    def _clear_pending(self):
        try:
            os.unlink(_PENDING_NAME, dir_fd=self._root_dir.fd)
        except FileNotFoundError:
            return
        self._record_fsync(self._root_dir.fd)

    def _recover_pending_voice_locked(self):
        pending = self._load_pending()
        if pending is None or pending.get("kind") != "voice":
            return
        item = pending["voice"]
        profile_id = item["id"]
        if not _entry_exists(self._root_dir.fd, profile_id):
            self._clear_pending()
            return
        fd, identity = self._open_profile(profile_id)
        try:
            validated = self._validate_profile_fd(
                fd, self.root / profile_id, profile_id,
                expected_id=profile_id)
            if validated.entry.status != "ready":
                raise ManagementFailure(
                    "migration_pending_collision",
                    "Committed migration profile does not match its journal.",
                    detail=profile_id, status=409)
            wav_name = Path(item["wav"]).name
            transcript_name = Path(item["transcript"]).name
            expected_wav = str((self.root / wav_name).resolve())
            expected_transcript = str((self.root / transcript_name).resolve())
            if (item["wav"] != expected_wav
                    or item["transcript"] != expected_transcript
                    or _read_bytes_at(fd, "reference.wav")
                    != _read_bytes_at(self._root_dir.fd, wav_name)
                    or _read_bytes_at(fd, "transcript.txt")
                    != _read_bytes_at(self._root_dir.fd, transcript_name)):
                raise ManagementFailure(
                    "migration_pending_collision",
                    "Committed migration profile does not match its sources.",
                    detail=profile_id, status=409)
            self._verify_child(self._root_dir, profile_id, identity)
        finally:
            os.close(fd)
        manifest = self._load_manifest()
        if item not in manifest["legacy_voice_sources"]:
            manifest["legacy_voice_sources"].append(item)
            self._remember_commit(self._write_manifest(manifest))
        self._clear_pending()

    def _cleanup_stale_migration_staging(self):
        for name in os.listdir(self._staging_dir.fd):
            if not name.startswith("migration-"):
                continue
            linked = os.stat(
                name, dir_fd=self._staging_dir.fd,
                follow_symlinks=False)
            self._remove_child_tree(
                self._staging_dir, name, _identity(linked), strict=False)

    def _remove_trash_identity(self, name, identity):
        with self._lock:
            try:
                self._remove_child_tree(
                    self._trash_dir, name, identity, strict=False)
            except (OSError, ManagementFailure):
                pass

    def _remove_child_tree(self, parent, name, identity, *, strict):
        try:
            parent.verify()
            linked = os.stat(
                name, dir_fd=parent.fd, follow_symlinks=False)
            if _identity(linked) != identity:
                raise OSError(
                    errno.ESTALE, "cleanup child changed", name)
            _storage_test_hook(
                "cleanup_before_child", directory_fd=parent.fd, name=name)
            parent.verify()
            linked = os.stat(
                name, dir_fd=parent.fd, follow_symlinks=False)
            if _identity(linked) != identity:
                raise OSError(
                    errno.ESTALE, "cleanup child changed", name)
            if not stat.S_ISDIR(linked.st_mode):
                os.unlink(name, dir_fd=parent.fd)
                os.fsync(parent.fd)
                return
            if linked.st_dev != self._root_dir.identity[0]:
                raise OSError(errno.EXDEV, "refusing to cross mount", name)
            fd = _open_directory(name, dir_fd=parent.fd)
            try:
                opened = os.fstat(fd)
                if _identity(opened) != identity:
                    raise OSError(errno.ESTALE, "cleanup child changed", name)
                verify = lambda: self._verify_child(parent, name, identity)
                self._remove_contents(fd, identity, verify)
            finally:
                os.close(fd)
            parent.verify()
            current = os.stat(
                name, dir_fd=parent.fd, follow_symlinks=False)
            if _identity(current) != identity:
                raise OSError(errno.ESTALE, "cleanup child changed", name)
            os.rmdir(name, dir_fd=parent.fd)
            os.fsync(parent.fd)
        except FileNotFoundError:
            return
        except (OSError, ManagementFailure) as exc:
            if strict:
                raise ManagementFailure(
                    "staged_import_cleanup_failed",
                    "Failed import staging could not be removed.",
                    detail=str(exc), status=500) from exc

    def _remove_contents(self, fd, directory_identity, verify):
        verify()
        current = os.fstat(fd)
        if (_identity(current) != directory_identity
                or current.st_dev != self._root_dir.identity[0]):
            raise OSError(errno.ESTALE, "cleanup directory changed")
        for name in os.listdir(fd):
            _storage_test_hook(
                "cleanup_before_child", directory_fd=fd, name=name)
            verify()
            linked = os.stat(name, dir_fd=fd, follow_symlinks=False)
            child_identity = _identity(linked)

            def verify_child(name=name, child_identity=child_identity):
                verify()
                current_child = os.stat(
                    name, dir_fd=fd, follow_symlinks=False)
                if _identity(current_child) != child_identity:
                    raise OSError(
                        errno.ESTALE, "cleanup child changed", name)

            if stat.S_ISDIR(linked.st_mode):
                if linked.st_dev != self._root_dir.identity[0]:
                    raise OSError(errno.EXDEV, "refusing to cross mount", name)
                child_fd = _open_directory(name, dir_fd=fd)
                try:
                    if _identity(os.fstat(child_fd)) != child_identity:
                        raise OSError(
                            errno.ESTALE, "cleanup child changed", name)
                    verify_child()
                    self._remove_contents(
                        child_fd, child_identity, verify_child)
                finally:
                    os.close(child_fd)
                verify_child()
                os.rmdir(name, dir_fd=fd)
            else:
                verify_child()
                os.unlink(name, dir_fd=fd)

    def _record_fsync(self, fd):
        try:
            os.fsync(fd)
        except OSError as exc:
            self._durability_diagnostic = str(exc)

    def _remember_commit(self, result):
        if isinstance(result, _CommitResult) and result.durability_error:
            self._durability_diagnostic = result.durability_error


def _field_for_code(code):
    if "audio" in code:
        return "audio"
    if "transcript" in code:
        return "transcript"
    if "id" in code or "collision" in code:
        return "id"
    return "profile"


class SettingsStore:
    """Validated schema-v2 settings with profile-first legacy migration."""

    def __init__(self, path, legacy_path, library):
        _, _, self.path = _path_parent(path)
        if legacy_path is None:
            self.legacy_path = None
        else:
            _, _, self.legacy_path = _path_parent(legacy_path)
        self.library = library
        self._lock = threading.RLock()
        self._current = None
        self._durability_diagnostic = None

    @property
    def current(self):
        with self._lock:
            return self._current

    @property
    def durability_diagnostic(self):
        with self._lock:
            return self._durability_diagnostic

    def snapshot(self):
        with self._lock:
            if self._current is None:
                return self.initialize()
            return self._current

    def initialize(self):
        with self._lock:
            self.library.initialize()
            if self.legacy_path is not None:
                self.library.recover_legacy_config(
                    self.legacy_path, self.path)
            if self._path_exists(self.path):
                settings = self._read_settings()
                self._validate_active(settings)
                self._current = settings
                return settings
            if self.legacy_path is None or not self._path_exists(
                    self.legacy_path):
                self._current = ProductSettings()
                return self._current
            if self.library.migration_issues:
                raise ManagementFailure(
                    "voice_migration_incomplete",
                    "Legacy voices require attention before settings migration.",
                    detail=list(self.library.migration_failures),
                    status=409)
            settings = self._read_legacy()
            self._validate_active(settings)
            self.library.begin_legacy_config(
                self.legacy_path, self.path, asdict(settings))
            try:
                result = _atomic_write_json(self.path, asdict(settings))
            except OSError as exc:
                raise ManagementFailure(
                    "settings_persist_failed",
                    "Product settings could not be saved.",
                    detail=str(exc), status=500) from exc
            self._remember_commit(result)
            _storage_test_hook(
                "settings_after_commit", settings_path=self.path)
            try:
                self.library.recover_legacy_config(
                    self.legacy_path, self.path)
            except (ManagementFailure, OSError) as exc:
                raise ManagementFailure(
                    "migration_manifest_write_failed",
                    "Migration backups could not be recorded.",
                    detail=str(exc), status=500) from exc
            self._current = self._read_settings()
            return self._current

    def update(self, **partial):
        with self._lock:
            current = self.snapshot()
            unknown = set(partial) - MUTABLE_SETTINGS_FIELDS
            if unknown:
                raise ManagementFailure(
                    "settings_key_unknown",
                    "Only active_voice, effects, and default_synthesis_rate "
                    "are mutable product settings.",
                    detail=sorted(unknown)[0], status=400)
            try:
                candidate = replace(current, **partial)
            except (TypeError, ValueError) as exc:
                raise ManagementFailure(
                    "settings_invalid", "Product settings are invalid.",
                    detail=str(exc), status=400) from exc
            self._validate_active(candidate)
            try:
                result = _atomic_write_json(self.path, asdict(candidate))
            except OSError as exc:
                raise ManagementFailure(
                    "settings_persist_failed",
                    "Product settings could not be saved.",
                    detail=str(exc), status=500) from exc
            self._remember_commit(result)
            self._current = self._read_settings()
            return self._current

    def set_active_voice(self, profile_id):
        return self.update(active_voice=profile_id)

    def _read_settings(self):
        try:
            raw = _read_json_path(self.path)
            return ProductSettings.from_dict(raw)
        except (OSError, UnicodeError, ValueError) as exc:
            raise ManagementFailure(
                "settings_invalid", "Product settings are invalid.",
                detail=str(exc), status=409) from exc

    def _read_legacy(self):
        try:
            raw = _read_json_path(self.legacy_path)
        except (OSError, UnicodeError, ValueError) as exc:
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration is not valid JSON.",
                detail=str(exc), status=409) from exc
        allowed = {"voice", "voices_dir", "speed", "fx", "port", "backend"}
        if not isinstance(raw, dict):
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration must contain a JSON object.", status=409)
        unknown = set(raw) - allowed
        if unknown:
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration contains an unknown setting.",
                detail=sorted(unknown)[0], status=409)
        voice = raw.get("voice")
        if voice is None:
            raise ManagementFailure(
                "legacy_active_voice_missing",
                "Legacy configuration does not select a voice profile.",
                status=409)
        voices_dir = raw.get("voices_dir")
        port = raw.get("port", 8765)
        backend = raw.get("backend", "auto")
        if not isinstance(voices_dir, str) or not voices_dir:
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration has an invalid voices directory.",
                detail="voice requires voices_dir", status=409)
        if (not isinstance(port, int) or isinstance(port, bool)
                or not 1 <= port <= 65535):
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration has an invalid port.",
                detail="port must be an integer in [1, 65535]", status=409)
        if backend not in ("auto", "mlx", "qwen-tts", "qwentts"):
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration has an invalid backend.",
                detail="unsupported backend", status=409)
        effects = raw.get("fx", False)
        rate = raw.get("speed", 1.0)
        try:
            return ProductSettings(
                active_voice=voice, effects=effects,
                default_synthesis_rate=rate)
        except ValueError as exc:
            raise ManagementFailure(
                "legacy_config_invalid",
                "Legacy configuration contains invalid product settings.",
                detail=str(exc), status=409) from exc

    def _validate_active(self, settings):
        if settings.active_voice is None:
            return
        try:
            self.library.resolve_ready(settings.active_voice)
        except ManagementFailure as exc:
            raise ManagementFailure(
                "settings_active_voice_not_ready",
                "The selected voice profile is not ready.",
                detail=settings.active_voice, status=409) from exc

    @staticmethod
    def _path_exists(path):
        fd, name, _, _ = _open_verified_parent(path)
        try:
            if not _entry_exists(fd, name):
                return False
            linked = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if not stat.S_ISREG(linked.st_mode):
                raise ManagementFailure(
                    "settings_path_unsafe",
                    "Settings path is not a regular file.",
                    detail=str(path), status=409)
            return True
        finally:
            os.close(fd)

    def _remember_commit(self, result):
        if isinstance(result, _CommitResult) and result.durability_error:
            self._durability_diagnostic = result.durability_error
