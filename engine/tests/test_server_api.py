"""Tests der HTTP-Schicht — ohne echte Modelle, ohne echten Socket."""

from __future__ import annotations

import asyncio

import numpy as np
import pytest
from httpx import ASGITransport, AsyncClient

from tests.test_runtime import SpyRefiner, SpyTranscriber
from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, Transcriber
from typeless_engine.models import TARGET_SAMPLE_RATE
from typeless_engine.server.app import create_app
from typeless_engine.server.runtime import EngineRuntime


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def build(transcriber: Transcriber | None = None, refiner: Refiner | None = None) -> EngineRuntime:
    return EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber or SpyTranscriber(),
        refiner=refiner or SpyRefiner(),
        dictionary=DictionaryEngine({"hot spot": "HubSpot"}),
    )


def pcm(seconds: float = 1.0) -> bytes:
    """Rohes Float32-PCM, 16 kHz mono — genau das, was Swift schicken wird."""
    samples = np.zeros(int(TARGET_SAMPLE_RATE * seconds), dtype=np.float32)
    return samples.tobytes()


async def client_for(runtime: EngineRuntime) -> AsyncClient:
    app = create_app(runtime)
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://sidecar")


@pytest.mark.anyio
async def test_health_reports_starting_then_ready() -> None:
    runtime = build()
    async with await client_for(runtime) as client:
        response = await client.get("/health")
        assert response.status_code == 200
        assert response.json()["status"] == "starting"

        await runtime.startup()

        body = (await client.get("/health")).json()
        assert body["status"] == "ready"
        assert body["stt_loaded"] is True
        assert body["llm_loaded"] is False
        assert body["busy"] is False
        assert body["stt_model"]  # Modell-IDs werden mitgeliefert
        assert body["llm_model"]


@pytest.mark.anyio
async def test_process_returns_final_text() -> None:
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post(
            "/process?mode=diktat",
            content=pcm(),
            headers={"Content-Type": "application/octet-stream"},
        )

    assert response.status_code == 200
    body = response.json()
    assert "HubSpot" in body["final_text"]
    assert body["mode"] == "diktat"
    assert body["refined"] is True
    assert body["fallback_reason"] is None
    assert "transcribe" in body["timings_ms"]


@pytest.mark.anyio
async def test_preload_returns_immediately_and_loads() -> None:
    llm = SpyRefiner()
    runtime = build(refiner=llm)
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/preload")
        assert response.status_code == 202

        for _ in range(100):  # dem Hintergrund-Task Zeit geben
            if runtime.health().llm_loaded:
                break
            await asyncio.sleep(0.01)

    assert llm.preloads == 1


@pytest.mark.anyio
async def test_unload_frees_llm() -> None:
    llm = SpyRefiner()
    runtime = build(refiner=llm)
    await runtime.startup()
    await runtime.preload()

    async with await client_for(runtime) as client:
        response = await client.post("/unload")

    assert response.status_code == 200
    assert response.json()["llm_loaded"] is False
    assert llm.unloads == 1


@pytest.mark.anyio
async def test_unknown_mode_is_rejected_without_touching_models() -> None:
    stt = SpyTranscriber()
    runtime = build(transcriber=stt)
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=gibtsnicht", content=pcm())

    assert response.status_code == 400
    assert stt.calls == 0


@pytest.mark.anyio
async def test_empty_body_is_rejected() -> None:
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=b"")

    assert response.status_code == 400


@pytest.mark.anyio
async def test_body_length_not_multiple_of_four_is_rejected() -> None:
    """Float32 sind 4 Byte — eine krumme Länge kann kein gültiger Puffer sein."""
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=b"\x00\x00\x00")

    assert response.status_code == 400


@pytest.mark.anyio
async def test_wrong_sample_rate_is_rejected() -> None:
    """Aus rohem PCM ist die Rate nicht ablesbar — deshalb muss sie mitgeschickt werden."""
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat&sample_rate=44100", content=pcm())

    assert response.status_code == 400
    assert "16000" in response.json()["detail"]


@pytest.mark.anyio
async def test_llm_failure_returns_200_with_raw_text() -> None:
    runtime = build(refiner=SpyRefiner(fail_refine=True))
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=pcm())

    assert response.status_code == 200
    body = response.json()
    assert body["refined"] is False
    assert body["final_text"] == body["dictionary_text"]
    assert "LLM" in body["fallback_reason"]


@pytest.mark.anyio
async def test_stt_failure_returns_500() -> None:
    runtime = build(transcriber=SpyTranscriber(fail=True))
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=pcm())

    assert response.status_code == 500
