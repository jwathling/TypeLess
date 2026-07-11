"""Tests für den MLX-Whisper-Transcriber (mit gefälschtem Backend, ohne echtes Modell)."""

from __future__ import annotations

from typing import Any

import numpy as np
import pytest

from typeless_engine.models import TARGET_SAMPLE_RATE, AudioBuffer
from typeless_engine.stt.mlx_whisper import MLXWhisperTranscriber


class FakeMLXWhisper:
    """Minimales Stand-in für das ``mlx_whisper``-Modul; protokolliert die Aufrufe."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def transcribe(self, samples: np.ndarray, **kwargs: Any) -> dict[str, Any]:
        self.calls.append({"n_samples": len(samples), **kwargs})
        return {"text": " hallo welt ", "language": "de"}


@pytest.fixture
def fake_backend(monkeypatch: pytest.MonkeyPatch) -> FakeMLXWhisper:
    fake = FakeMLXWhisper()
    monkeypatch.setattr(MLXWhisperTranscriber, "_import_backend", lambda self: fake)
    return fake


def test_warm_up_loads_model(fake_backend: FakeMLXWhisper) -> None:
    """``warm_up`` muss das Modell wirklich laden, nicht nur importieren.

    Das Modell wird erst beim ersten ``transcribe``-Aufruf geladen; ein Warm-up, das keinen
    Aufruf absetzt, verschiebt die Ladezeit auf das erste echte Diktat (latenzkritisch).
    """
    MLXWhisperTranscriber().warm_up()

    assert len(fake_backend.calls) == 1, "warm_up hat das Modell nicht geladen"
    assert fake_backend.calls[0]["n_samples"] > 0


def test_transcribe_strips_and_returns_language(fake_backend: FakeMLXWhisper) -> None:
    audio = AudioBuffer(samples=np.zeros(TARGET_SAMPLE_RATE, dtype=np.float32))

    result = MLXWhisperTranscriber().transcribe(audio)

    assert result.text == "hallo welt"
    assert result.language == "de"
    assert result.duration_seconds == pytest.approx(1.0)


def test_transcribe_rejects_wrong_sample_rate(fake_backend: FakeMLXWhisper) -> None:
    audio = AudioBuffer(samples=np.zeros(8000, dtype=np.float32), sample_rate=8000)

    with pytest.raises(ValueError, match="16000 Hz"):
        MLXWhisperTranscriber().transcribe(audio)


def test_transcribe_passes_language_through(fake_backend: FakeMLXWhisper) -> None:
    audio = AudioBuffer(samples=np.zeros(TARGET_SAMPLE_RATE, dtype=np.float32))

    MLXWhisperTranscriber().transcribe(audio, language="en")

    assert fake_backend.calls[0]["language"] == "en"
