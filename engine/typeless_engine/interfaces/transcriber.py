"""Abstrakte Speech-to-Text-Schnittstelle.

Zentrale Abstraktion des Plans: ``transcribe(audio) -> text`` (hier als reichhaltigeres
``Transcription``-Objekt, dessen ``.text`` den geforderten String liefert). Der restliche
Code hängt niemals von einer konkreten Engine ab, sondern nur von diesem Interface.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

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
