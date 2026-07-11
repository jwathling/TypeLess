"""MLX-Whisper-Transcriber (Apple Silicon / Metal).

Default-STT-Engine laut Plan: ``large-v3-turbo`` — ~6x schneller als large-v3 bei
minimalem Genauigkeitsverlust, starkes Deutsch/Englisch, gutes Code-Switching.

``mlx_whisper`` wird lazy importiert: Das Paket ist ausschließlich auf Apple Silicon
lauffähig; der übrige Code muss auch auf anderen Plattformen importierbar bleiben.
"""

from __future__ import annotations

from typing import Any

from ..interfaces import Transcriber
from ..logging_ import get_logger
from ..models import TARGET_SAMPLE_RATE, AudioBuffer, Transcription

_log = get_logger(__name__)

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"


class MLXWhisperTranscriber(Transcriber):
    """Transcriber auf Basis von ``mlx_whisper`` (Metal, Apple Silicon)."""

    def __init__(self, model: str = DEFAULT_MODEL) -> None:
        self._model = model

    def _import_backend(self) -> Any:
        try:
            import mlx_whisper  # noqa: PLC0415  (lazy: Apple-Silicon-only)
        except ImportError as exc:
            raise RuntimeError(
                "mlx_whisper ist nicht verfügbar. Es läuft nur auf Apple Silicon "
                "(Installation: `uv sync --extra mlx`)."
            ) from exc
        return mlx_whisper

    def warm_up(self) -> None:
        # mlx_whisper cached das Modell nach dem ersten Aufruf; ein kurzer Leerlauf-Transkript
        # zwingt das Laden vorab. Bewusst schlank gehalten.
        self._import_backend()
        _log.info(
            "MLXWhisperTranscriber bereit (Modell wird beim ersten Aufruf geladen): %s", self._model
        )

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        mlx_whisper = self._import_backend()
        if audio.sample_rate != TARGET_SAMPLE_RATE:
            raise ValueError(
                f"Erwarte {TARGET_SAMPLE_RATE} Hz, erhalten {audio.sample_rate} Hz. "
                "Vor der Transkription resamplen."
            )
        _log.debug("Transkribiere %.1fs Audio (lang=%s)", audio.duration_seconds, language)
        result = mlx_whisper.transcribe(
            audio.samples,
            path_or_hf_repo=self._model,
            language=language,  # None => Auto-Detect (empfohlen für DE+EN gemischt)
        )
        return Transcription(
            text=str(result.get("text", "")).strip(),
            language=result.get("language"),
            duration_seconds=audio.duration_seconds,
        )
