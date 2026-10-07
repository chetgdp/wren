"""Storage for Wren: voices directory and atomic settings.json."""

import json
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path


VOICE_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


class StorageError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


@dataclass
class VoiceProfile:
    id: str
    display_name: str
    root_path: Path
    audio_path: Path
    transcript_path: Path
    transcript: str

    def read_audio(self) -> bytes:
        return self.audio_path.read_bytes()


def default_data_dir() -> Path:
    if os.name == "posix" and os.uname().sysname == "Darwin":
        return Path.home() / "Library" / "Application Support" / "voice-ml"
    return Path.home() / ".local" / "share" / "wren"


def validate_wav_bytes(payload: bytes) -> None:
    """Validate that payload is a readable, decodable WAV file."""
    import io
    try:
        import soundfile as sf
        with sf.SoundFile(io.BytesIO(payload)) as audio:
            if audio.channels <= 0 or audio.samplerate <= 0 or len(audio) <= 0:
                raise ValueError("audio contains no decodable frames")
            audio.seek(len(audio) - 1)
            if len(audio.read(1, dtype="float32", always_2d=True)) != 1:
                raise ValueError("audio contains no decodable frames")
    except Exception as exc:
        raise StorageError(
            "voice_invalid",
            f"Voice reference audio is not a readable WAV file: {exc}",
            status=422,
        ) from exc


def atomic_write_json(path: Path, data: dict) -> None:
    """Atomically write JSON to path using tmp + rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_dir = path.parent
    fd, tmp_path_str = tempfile.mkstemp(
        dir=temp_dir, prefix=f".{path.name}.", suffix=".tmp"
    )
    tmp_path = Path(tmp_path_str)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except Exception:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise


class SettingsStore:
    """Manages reading and updating settings.json."""

    def __init__(self, data_dir: Path):
        self.data_dir = Path(data_dir)
        self.path = self.data_dir / "settings.json"

    def load(self, initial_voice: str | None = None) -> dict:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    return {
                        "active_voice": data.get("active_voice"),
                        "effects": bool(data.get("effects", False)),
                    }
            except Exception:
                pass

        # Default settings or bootstrap
        default_settings = {
            "active_voice": initial_voice,
            "effects": False,
        }
        self.save(default_settings)
        return default_settings

    def save(self, settings: dict) -> None:
        atomic_write_json(self.path, settings)

    def update(self, **kwargs) -> dict:
        current = self.load()
        for k, v in kwargs.items():
            if v is not None:
                current[k] = v
        self.save(current)
        return current


class VoiceLibrary:
    """Manages voice profiles stored in <data_dir>/voices."""

    def __init__(self, data_dir: Path):
        self.data_dir = Path(data_dir)
        self.voices_dir = self.data_dir / "voices"
        self.voices_dir.mkdir(parents=True, exist_ok=True)

    def list_voices(self) -> list[dict]:
        profiles = []
        for voice_dir in sorted(self.voices_dir.iterdir()):
            if not voice_dir.is_dir() or voice_dir.name.startswith("."):
                continue
            profile = self._read_profile(voice_dir)
            if profile is not None:
                profiles.append({
                    "id": profile.id,
                    "display_name": profile.display_name,
                })
        return profiles

    def get_voice(self, voice_id: str) -> VoiceProfile | None:
        if not VOICE_ID_RE.match(voice_id):
            return None
        voice_dir = self.voices_dir / voice_id
        if not voice_dir.is_dir():
            return None
        return self._read_profile(voice_dir)

    def _read_profile(self, voice_dir: Path) -> VoiceProfile | None:
        voice_id = voice_dir.name
        profile_json = voice_dir / "profile.json"
        display_name = voice_id

        if profile_json.exists():
            try:
                meta = json.loads(profile_json.read_text(encoding="utf-8"))
                if isinstance(meta, dict):
                    display_name = meta.get("display_name", display_name)
                    voice_id = meta.get("id", voice_id)
            except Exception:
                pass

        # Reference audio candidate names
        audio_path = None
        for candidate in ("reference.wav", f"{voice_id}.wav"):
            p = voice_dir / candidate
            if p.is_file():
                audio_path = p
                break

        # Transcript candidate names
        transcript_path = None
        for candidate in ("transcript.txt", f"{voice_id}.txt"):
            p = voice_dir / candidate
            if p.is_file():
                transcript_path = p
                break

        if audio_path is None or transcript_path is None:
            return None

        try:
            transcript = transcript_path.read_text(encoding="utf-8").strip()
        except Exception:
            return None

        if not transcript:
            return None

        return VoiceProfile(
            id=voice_id,
            display_name=display_name,
            root_path=voice_dir,
            audio_path=audio_path,
            transcript_path=transcript_path,
            transcript=transcript,
        )

    def add_voice(
        self, voice_id: str, display_name: str, audio_bytes: bytes, transcript: str
    ) -> VoiceProfile:
        if not VOICE_ID_RE.match(voice_id):
            raise StorageError(
                "voice_invalid", f"Invalid voice id: {voice_id!r}", status=400
            )

        voice_dir = self.voices_dir / voice_id
        if voice_dir.exists():
            raise StorageError(
                "voice_exists", f"Voice already exists: {voice_id}", status=409
            )

        transcript = transcript.strip()
        if not transcript:
            raise StorageError(
                "voice_invalid", "Transcript must not be empty", status=400
            )

        validate_wav_bytes(audio_bytes)

        # Stage in temporary directory before moving to final path
        stage_dir = Path(tempfile.mkdtemp(dir=self.voices_dir, prefix=".stage-"))
        try:
            (stage_dir / "reference.wav").write_bytes(audio_bytes)
            (stage_dir / "transcript.txt").write_text(transcript, encoding="utf-8")
            (stage_dir / "profile.json").write_text(
                json.dumps({"id": voice_id, "display_name": display_name}, indent=2),
                encoding="utf-8",
            )
            stage_dir.rename(voice_dir)
        except Exception:
            if stage_dir.exists():
                shutil.rmtree(stage_dir, ignore_errors=True)
            raise

        profile = self._read_profile(voice_dir)
        if profile is None:
            raise StorageError(
                "voice_invalid", "Failed to load newly added voice profile", status=422
            )
        return profile

    def update_voice(self, voice_id: str, display_name: str) -> VoiceProfile:
        profile = self.get_voice(voice_id)
        if profile is None:
            raise StorageError(
                "unknown_voice", f"Voice not found: {voice_id}", status=404
            )

        profile_json = profile.root_path / "profile.json"
        data = {"id": profile.id, "display_name": display_name}
        atomic_write_json(profile_json, data)
        updated = self.get_voice(voice_id)
        if updated is None:
            raise StorageError("unknown_voice", f"Voice not found: {voice_id}", status=404)
        return updated

    def delete_voice(self, voice_id: str, active_voice: str | None) -> None:
        if voice_id == active_voice:
            raise StorageError(
                "voice_active", "Cannot delete the active voice", status=409
            )
        profile = self.get_voice(voice_id)
        if profile is None:
            raise StorageError(
                "unknown_voice", f"Voice not found: {voice_id}", status=404
            )
        shutil.rmtree(profile.root_path)
