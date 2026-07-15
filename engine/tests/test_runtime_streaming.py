"""Runtime-Streaming-Sitzung: Streaming-Pfad, Batch-Rückfall, Preload — mit Mock-Backends."""

from __future__ import annotations

from collections.abc import AsyncIterator

import numpy as np
import pytest

from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, StreamingTranscriber, Transcriber
from typeless_engine.models import AudioBuffer, Mode, Transcription
from typeless_engine.server.runtime import EngineRuntime


class StreamingMock(StreamingTranscriber):
    """Streaming-Transcriber-Attrappe; protokolliert die Aufrufe."""

    def __init__(self) -> None:
        self.began = False
        self.feeds = 0
        self.finalized = False
        self.total_samples = 0

    def warm_up(self) -> None: ...
    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(text="BATCH sollte hier nicht laufen")

    def stream_begin(self, *, language: str | None = None) -> None:
        self.began = True

    def stream_feed(self, samples: np.ndarray) -> str:
        self.feeds += 1
        self.total_samples += len(samples)
        return ""

    def stream_finalize(self) -> Transcription:
        self.finalized = True
        return Transcription(text="hallo welt", language="de")


class BatchOnlyMock(Transcriber):
    def __init__(self) -> None:
        self.seen_samples = 0

    def warm_up(self) -> None: ...
    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        self.seen_samples = len(audio.samples)
        return Transcription(text="batch text", language="de")


class RaisingStreamingMock(StreamingMock):
    def stream_feed(self, samples: np.ndarray) -> str:
        raise RuntimeError("Streaming kaputt")

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(text="rettung per batch", language="de")


class EchoRefiner(Refiner):
    def preload(self) -> None: ...
    def unload(self) -> None: ...
    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        return text.upper()


@pytest.fixture
def anyio_backend() -> str:
    # Gleiches Muster wie test_runtime.py: async-Tests laufen auf asyncio.
    return "asyncio"


def _runtime(transcriber: Transcriber) -> EngineRuntime:
    rt = EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber,
        refiner=EchoRefiner(),
        dictionary=DictionaryEngine({}),
    )
    return rt


async def _chunks(n: int, size: int) -> AsyncIterator[np.ndarray]:
    for _ in range(n):
        yield np.zeros(size, dtype=np.float32)


@pytest.mark.anyio
async def test_streaming_pfad_wird_genutzt() -> None:
    stt = StreamingMock()
    rt = _runtime(stt)
    await rt.startup()
    result = await rt.process_stream(_chunks(3, 16000), Mode.DIKTAT)
    assert stt.began and stt.finalized and stt.feeds == 3
    assert result.raw_text == "hallo welt"
    assert result.final_text == "HALLO WELT"  # EchoRefiner -> Großschrift


@pytest.mark.anyio
async def test_batch_rueckfall_wenn_backend_nicht_streamt() -> None:
    stt = BatchOnlyMock()
    rt = _runtime(stt)
    await rt.startup()
    result = await rt.process_stream(_chunks(3, 16000), Mode.DIKTAT)
    # Kein Streaming möglich -> alles Audio gesammelt und einmal batch-transkribiert.
    assert stt.seen_samples == 3 * 16000
    assert result.raw_text == "batch text"


@pytest.mark.anyio
async def test_streaming_fehler_faellt_auf_batch_zurueck() -> None:
    stt = RaisingStreamingMock()
    rt = _runtime(stt)
    await rt.startup()
    result = await rt.process_stream(_chunks(3, 16000), Mode.DIKTAT)
    # Streaming stolpert -> Rettung über den Batch-Weg, Diktat NICHT verloren.
    assert result.raw_text == "rettung per batch"
