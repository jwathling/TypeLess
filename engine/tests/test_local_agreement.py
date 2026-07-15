"""Tests rund um Streaming-Transkription — reine Logik, ohne MLX."""

from __future__ import annotations

import numpy as np

from typeless_engine.interfaces import StreamingTranscriber, Transcriber
from typeless_engine.models import AudioBuffer, Transcription


class _MiniStreaming(StreamingTranscriber):
    """Kleinste zulässige Implementierung — belegt die Vertrags-Form (kein echtes STT)."""

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(text="batch")

    def stream_begin(self, *, language: str | None = None) -> None:
        self._words: list[str] = []

    def stream_feed(self, samples: np.ndarray) -> str:
        self._words.append("x")
        return "x"

    def stream_finalize(self) -> Transcription:
        return Transcription(text=" ".join(self._words))


def test_streaming_transcriber_is_a_transcriber() -> None:
    # Ein StreamingTranscriber MUSS auch den Batch-Vertrag erfüllen (Rückfallweg).
    s = _MiniStreaming()
    assert isinstance(s, Transcriber)
    assert isinstance(s, StreamingTranscriber)


def test_batch_only_is_not_streaming() -> None:
    # Ein reiner Batch-Transcriber darf NICHT als Streaming durchgehen — daran unterscheidet die
    # Runtime, ob sie streamen oder auf Batch zurückfallen muss.
    class BatchOnly(Transcriber):
        def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
            return Transcription(text="batch")

    assert not isinstance(BatchOnly(), StreamingTranscriber)


def test_stream_roundtrip_shape() -> None:
    s = _MiniStreaming()
    s.stream_begin()
    assert s.stream_feed(np.zeros(4, dtype=np.float32)) == "x"
    assert s.stream_finalize().text == "x"
