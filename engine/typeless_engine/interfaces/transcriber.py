"""Abstrakte Speech-to-Text-Schnittstelle.

Zentrale Abstraktion des Plans: ``transcribe(audio) -> text`` (hier als reichhaltigeres
``Transcription``-Objekt, dessen ``.text`` den geforderten String liefert). Der restliche
Code hängt niemals von einer konkreten Engine ab, sondern nur von diesem Interface.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

import numpy as np

from ..models import AudioBuffer, Transcription


class Transcriber(ABC):
    """Wandelt einen Audiopuffer in Text um."""

    @abstractmethod
    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        """Transkribiert ``audio``.

        Args:
            audio: Mono-16-kHz-Puffer.
            language: Optionaler ISO-Code (z. B. ``"de"``). ``None`` = Auto-Detect,
                empfohlen für gemischtes Deutsch/Englisch.
        """
        raise NotImplementedError

    def warm_up(self) -> None:  # noqa: B027 - optionaler Hook, bewusst No-op
        """Lädt das Modell vorab (optional). Default: No-op."""

    def unload(self) -> None:  # noqa: B027 - optionaler Hook, bewusst No-op
        """Gibt Modellressourcen frei (optional). Default: No-op."""


class StreamingTranscriber(Transcriber):
    """Optionaler Zusatzvertrag: Transkribieren *während* des Sprechens.

    Wer das implementiert, nimmt Audio häppchenweise entgegen und liefert stabile Wörter schon vor
    dem Ende. Der Batch-Vertrag ``transcribe()`` bleibt Pflicht — die Runtime nutzt ihn als
    Rückfallweg, wenn Streaming nicht geht oder scheitert.

    Eine Sitzung: ``stream_begin`` → beliebig oft ``stream_feed`` → genau ein ``stream_finalize``.
    """

    @abstractmethod
    def stream_begin(self, *, language: str | None = None) -> None:
        """Eröffnet eine Streaming-Sitzung. ``language=None`` = Auto-Detect."""
        raise NotImplementedError

    @abstractmethod
    def stream_feed(self, samples: np.ndarray) -> str:
        """Nimmt weitere Mono-Float32-16-kHz-Samples entgegen.

        Liefert den seit dem letzten Aufruf **neu festgeschriebenen** Text (leerer String, wenn
        nichts Neues sicher ist).
        """
        raise NotImplementedError

    @abstractmethod
    def stream_finalize(self) -> Transcription:
        """Schließt die Sitzung ab und liefert das **vollständige** Transkript."""
        raise NotImplementedError
