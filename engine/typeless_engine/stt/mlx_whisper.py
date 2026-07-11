"""MLX-Whisper-Transcriber (Apple Silicon / Metal).

Default-STT-Engine laut Plan: ``large-v3-turbo`` — ~6x schneller als large-v3 bei
minimalem Genauigkeitsverlust, starkes Deutsch/Englisch, gutes Code-Switching.

``mlx_whisper`` wird lazy importiert: Das Paket ist ausschließlich auf Apple Silicon
lauffähig; der übrige Code muss auch auf anderen Plattformen importierbar bleiben.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from ..interfaces import Transcriber
from ..logging_ import get_logger
from ..models import TARGET_SAMPLE_RATE, AudioBuffer, Transcription

_log = get_logger(__name__)

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

# Länge des Stille-Puffers für das Warm-up (0,1 s). Whisper padded ohnehin auf 30 s;
# kürzer bringt also nichts, länger kostet nur Zeit.
WARM_UP_SAMPLES = TARGET_SAMPLE_RATE // 10


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
        # mlx_whisper cached das Modell erst ab dem ersten transcribe-Aufruf. Ein Import allein
        # lädt nichts — die Ladezeit fiele sonst beim ersten echten Diktat an (latenzkritisch).
        # Ein kurzer Stille-Puffer erzwingt das Laden vorab.
        _log.info("Wärme STT-Modell auf: %s ...", self._model)
        silence = AudioBuffer(samples=np.zeros(WARM_UP_SAMPLES, dtype=np.float32))
        self.transcribe(silence)
        _log.info("STT-Modell warm.")

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
