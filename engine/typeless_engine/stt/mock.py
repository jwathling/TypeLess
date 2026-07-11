"""Mock-Transcriber für Tests und plattformunabhängige Entwicklung (ohne MLX)."""

from __future__ import annotations

from ..interfaces import Transcriber
from ..models import AudioBuffer, Transcription


class MockTranscriber(Transcriber):
    """Liefert einen vorgegebenen Text, unabhängig vom Audio.

    Ermöglicht das Testen von Wörterbuch + Pipeline ohne echtes STT-Modell.
    """

    def __init__(self, text: str = "das ist ein test", language: str = "de") -> None:
        self._text = text
        self._language = language

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(
            text=self._text,
            language=language or self._language,
            duration_seconds=audio.duration_seconds,
        )
