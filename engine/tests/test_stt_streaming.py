"""MLX-Streaming-Orchestrierung mit gefälschtem Whisper (ohne echtes Modell)."""

from __future__ import annotations

from typing import Any

import numpy as np
import pytest

from typeless_engine.models import TARGET_SAMPLE_RATE
from typeless_engine.stt.mlx_whisper import STREAM_STEP_SAMPLES, MLXWhisperTranscriber


class FakeGrowingWhisper:
    """Liefert mit wachsendem Audio mehr Wörter — je 1 s Audio ein weiteres Wort aus WORDS."""

    WORDS = ["das", "ist", "ein", "kurzer", "test"]

    def transcribe(self, samples: np.ndarray, **kwargs: Any) -> dict[str, Any]:
        sekunden = max(1, len(samples) // TARGET_SAMPLE_RATE)
        text = " ".join(self.WORDS[:sekunden])
        return {"text": " " + text + " ", "language": "de"}


@pytest.fixture
def fake_stream(monkeypatch: pytest.MonkeyPatch) -> FakeGrowingWhisper:
    fake = FakeGrowingWhisper()
    monkeypatch.setattr(MLXWhisperTranscriber, "_import_backend", lambda self: fake)
    return fake


def _sekunde() -> np.ndarray:
    return np.zeros(TARGET_SAMPLE_RATE, dtype=np.float32)


def test_stream_schreibt_stabile_woerter_fest(fake_stream: FakeGrowingWhisper) -> None:
    t = MLXWhisperTranscriber()
    t.stream_begin()
    committed = ""
    for _ in range(5):
        committed += t.stream_feed(_sekunde())
    final = t.stream_finalize()
    # Die laufend über stream_feed zusammengesetzte Zwischenausgabe muss SAUBER GETRENNTE Wörter
    # ergeben (kein "dasist") — das letzte Wort kommt erst per finalize dazu.
    assert committed.split() == FakeGrowingWhisper.WORDS[:4]
    assert " " in committed  # Wörter sind getrennt, nicht verklebt
    # Alle fünf Wörter erscheinen am Ende, in Reihenfolge.
    assert final.text.split() == FakeGrowingWhisper.WORDS
    assert final.language == "de"


def test_stream_feed_unter_dem_takt_transkribiert_nicht(fake_stream: FakeGrowingWhisper) -> None:
    t = MLXWhisperTranscriber()
    t.stream_begin()
    # Ein Häppchen kürzer als der Takt darf noch nichts festschreiben.
    assert t.stream_feed(np.zeros(STREAM_STEP_SAMPLES // 2, dtype=np.float32)) == ""


def test_finalize_liefert_alles_auch_ohne_zweite_bestaetigung(
    fake_stream: FakeGrowingWhisper,
) -> None:
    t = MLXWhisperTranscriber()
    t.stream_begin()
    t.stream_feed(_sekunde())  # nur "das" gesehen, noch nichts sicher
    final = t.stream_finalize()
    assert final.text.split() == ["das"]
