"""MLX-Whisper-Transcriber (Apple Silicon / Metal).

Default-STT-Engine laut Plan: ``large-v3-turbo`` — ~6x schneller als large-v3 bei
minimalem Genauigkeitsverlust, starkes Deutsch/Englisch, gutes Code-Switching.

``mlx_whisper`` wird lazy importiert: Das Paket ist ausschließlich auf Apple Silicon
lauffähig; der übrige Code muss auch auf anderen Plattformen importierbar bleiben.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from ..interfaces import StreamingTranscriber
from ..logging_ import get_logger
from ..models import TARGET_SAMPLE_RATE, AudioBuffer, Transcription
from .local_agreement import LocalAgreement

_log = get_logger(__name__)

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

# Länge des Stille-Puffers für das Warm-up (0,1 s). Whisper padded ohnehin auf 30 s;
# kürzer bringt also nichts, länger kostet nur Zeit.
WARM_UP_SAMPLES = TARGET_SAMPLE_RATE // 10

# Takt der Streaming-Neu-Transkription: alle ~1 s Audio wird der Puffer erneut durch Whisper
# geschickt. Kürzer => mehr GPU-Last, kaum stabilere Wörter; länger => sichtbar trägeres Overlay.
STREAM_STEP_SAMPLES = TARGET_SAMPLE_RATE


class MLXWhisperTranscriber(StreamingTranscriber):
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
            # Whisper verarbeitet Audio in 30-s-Fenstern und reicht per Default den Text des
            # VORIGEN Fensters als Kontext ins nächste. Kippt ein Fenster einmal in eine
            # Wiederholungsschleife (bekannter Whisper-Defekt, tritt bei Stille, Atmern und
            # Hintergrundgeräuschen am Satzende auf), sät dieser Kontext die Schleife in alle
            # folgenden Fenster — sie läuft dann bis zum Ende des Diktats durch.
            #
            # In der Handprobe zu M4 real passiert: Ein sonst sauberes Diktat endete in
            # „beber beber beber …", hunderte Male, bis zum Schluss.
            #
            # `condition_on_previous_text=False` kappt die Weitergabe. Preis: Whisper verliert
            # den Kontext über Fenstergrenzen hinweg (z. B. Eigennamen, die vorher fielen). Für
            # Diktate ist das der richtige Tausch — ein Fenster ist 30 s, so lange reicht ein
            # Satzbogen selten, und eine Schleife zerstört das GANZE Diktat, während fehlender
            # Kontext höchstens ein Wort kostet. Das Wörterbuch (deterministisch, danach) fängt
            # Eigennamen ohnehin ab.
            condition_on_previous_text=False,
        )
        return Transcription(
            text=str(result.get("text", "")).strip(),
            language=result.get("language"),
            duration_seconds=audio.duration_seconds,
        )

    def stream_begin(self, *, language: str | None = None) -> None:
        self._stream_language = language
        self._stream_detected_language: str | None = None
        self._stream_buffer = np.zeros(0, dtype=np.float32)
        self._stream_new_samples = 0
        self._agreement = LocalAgreement()

    def stream_feed(self, samples: np.ndarray) -> str:
        self._stream_buffer = np.concatenate([self._stream_buffer, samples.astype(np.float32)])
        self._stream_new_samples += len(samples)
        # Nur im festen Takt erneut transkribieren — nicht bei jedem winzigen Häppchen.
        if self._stream_new_samples < STREAM_STEP_SAMPLES:
            return ""
        self._stream_new_samples = 0
        # War schon Text festgeschrieben, bevor dieser Durchlauf lief? Dann bekommt
        # die Rückgabe ein führendes Leerzeichen, damit sie direkt anhängbar ist.
        hatte_text = len(self._agreement.committed) > 0
        newly = self._agreement.insert(self._transcribe_buffer_words())
        if not newly:
            return ""
        return (" " if hatte_text else "") + " ".join(newly)

    def stream_finalize(self) -> Transcription:
        # Ein letzter Durchlauf über das vollständige Audio, dann den Rest ohne zweite
        # Bestätigung akzeptieren (Ende des Diktats).
        self._agreement.insert(self._transcribe_buffer_words())
        self._agreement.finalize()
        text = " ".join(self._agreement.committed).strip()
        seconds = len(self._stream_buffer) / TARGET_SAMPLE_RATE
        return Transcription(
            text=text, language=self._stream_detected_language, duration_seconds=seconds
        )

    def _transcribe_buffer_words(self) -> list[str]:
        """Transkribiert den aktuellen Puffer und liefert die Wortliste (leer bei leerem Puffer)."""
        if len(self._stream_buffer) == 0:
            return []
        mlx_whisper = self._import_backend()
        result = mlx_whisper.transcribe(
            self._stream_buffer,
            path_or_hf_repo=self._model,
            language=self._stream_language,
            condition_on_previous_text=False,  # gleiche Begründung wie im Batch-Pfad
        )
        self._stream_detected_language = result.get("language")
        return str(result.get("text", "")).strip().split()
