"""Tests rund um Streaming-Transkription — reine Logik, ohne MLX."""

from __future__ import annotations

import numpy as np

from typeless_engine.interfaces import StreamingTranscriber, Transcriber
from typeless_engine.models import AudioBuffer, Transcription
from typeless_engine.stt.local_agreement import LocalAgreement


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


def test_nichts_wird_bei_erster_hypothese_festgeschrieben() -> None:
    la = LocalAgreement()
    # Eine einzelne Hypothese hat noch keinen Vorgänger zum Übereinstimmen -> nichts sicher.
    assert la.insert(["also", "ich"]) == []
    assert la.committed == []


def test_uebereinstimmender_praefix_wird_festgeschrieben() -> None:
    la = LocalAgreement()
    la.insert(["also", "ich", "wollte"])
    # Zweite Hypothese stimmt im Präfix "also ich" überein -> das wird sicher; "sage" noch nicht.
    newly = la.insert(["also", "ich", "sage"])
    assert newly == ["also", "ich"]
    assert la.committed == ["also", "ich"]


def test_kein_rueckgaengig_bei_widerspruch_im_festgeschriebenen() -> None:
    la = LocalAgreement()
    la.insert(["a", "b", "c"])
    la.insert(["a", "b", "c"])  # "a b c" wird sicher
    assert la.committed == ["a", "b", "c"]
    # Eine spätere Hypothese widerspricht dem bereits Festgeschriebenen -> NICHT zurückrollen
    # (Streaming kann Ausgegebenes nicht zurücknehmen; bewusst akzeptiert).
    assert la.insert(["a", "x", "y"]) == []
    assert la.committed == ["a", "b", "c"]


def test_finalize_schreibt_den_rest_fest() -> None:
    la = LocalAgreement()
    la.insert(["a", "b", "c"])
    la.insert(["a", "b", "c"])  # "a b c" sicher, letzte Hypothese = ["a","b","c"]
    la.insert(["a", "b", "c", "d"])  # "d" noch nicht bestätigt
    assert la.committed == ["a", "b", "c"]
    # finalize akzeptiert den Rest der letzten Hypothese ohne zweite Bestätigung.
    assert la.finalize() == ["d"]
    assert la.committed == ["a", "b", "c", "d"]


def test_typischer_diktat_verlauf() -> None:
    la = LocalAgreement()
    out: list[str] = []
    out += la.insert(["das"])
    out += la.insert(["das", "ist"])  # "das" sicher
    out += la.insert(["das", "ist", "ein"])  # "ist" sicher
    out += la.insert(["das", "ist", "ein", "test"])  # "ein" sicher
    out += la.finalize()  # "test" per finalize
    assert out == ["das", "ist", "ein", "test"]
    assert la.committed == ["das", "ist", "ein", "test"]
