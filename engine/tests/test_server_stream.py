"""Endpunkt /process/stream: Byte-Dekodierung über Chunk-Grenzen, Weiterreichen an die Runtime."""

from __future__ import annotations

from collections.abc import AsyncIterator

import numpy as np
from fastapi.testclient import TestClient

from typeless_engine.models import ProcessResult
from typeless_engine.server.app import create_app


class StubRuntime:
    """Minimale Runtime-Attrappe: sammelt die empfangenen Samples, liefert ein festes Ergebnis."""

    def __init__(self) -> None:
        self.received = np.zeros(0, dtype=np.float32)

    async def process_stream(self, audio_chunks: AsyncIterator[np.ndarray], mode, *, language=None):
        async for chunk in audio_chunks:
            self.received = np.concatenate([self.received, chunk])
        return ProcessResult(
            raw_text="roh",
            dictionary_text="roh",
            final_text="FERTIG",
            mode=mode,
            language="de",
            refined=True,
        )


def test_stream_endpunkt_dekodiert_ueber_chunk_grenzen() -> None:
    stub = StubRuntime()
    client = TestClient(create_app(stub))  # type: ignore[arg-type]

    # Drei Float32-Samples = 12 Byte, absichtlich in Häppchen zerschnitten, die MITTEN in einem
    # Sample brechen (5 + 4 + 3 Byte) — der Endpunkt muss die Reste über Grenzen hinweg puffern.
    payload = np.array([1.0, 2.0, 3.0], dtype="<f4").tobytes()
    parts = [payload[0:5], payload[5:9], payload[9:12]]

    def gen() -> bytes:
        yield from parts

    resp = client.post("/process/stream?mode=diktat", content=gen())
    assert resp.status_code == 200
    assert resp.json()["final_text"] == "FERTIG"
    assert np.allclose(stub.received, [1.0, 2.0, 3.0])


def test_stream_endpunkt_lehnt_falsche_sample_rate_ab() -> None:
    client = TestClient(create_app(StubRuntime()))  # type: ignore[arg-type]
    resp = client.post("/process/stream?mode=diktat&sample_rate=8000", content=b"")
    assert resp.status_code == 400


def test_stream_endpunkt_lehnt_unbekannten_modus_ab() -> None:
    client = TestClient(create_app(StubRuntime()))  # type: ignore[arg-type]
    resp = client.post("/process/stream?mode=quatsch", content=b"\x00\x00\x00\x00")
    assert resp.status_code == 400
