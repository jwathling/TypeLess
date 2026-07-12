"""Tests der HTTP-Schicht — ohne echte Modelle, ohne echten Socket."""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Callable

import numpy as np
import pytest
from httpx import ASGITransport, AsyncClient

from tests.test_runtime import FailingWarmUpTranscriber, SpyRefiner, SpyTranscriber
from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, Transcriber
from typeless_engine.models import TARGET_SAMPLE_RATE, AudioBuffer, Transcription
from typeless_engine.server.app import create_app
from typeless_engine.server.runtime import EngineRuntime

# Obergrenze für alle Wartevorgänge in den Nebenläufigkeits-Tests. Sie wird im Erfolgsfall
# nie ausgeschöpft (gewartet wird auf Events, nicht auf Zeit) und dient nur dazu, einen
# Regress als Fehlschlag statt als hängenden Testlauf sichtbar zu machen.
_TIMEOUT_SECONDS = 5.0


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


class BlockingTranscriber(SpyTranscriber):
    """Hält ``transcribe()`` (im Worker-Thread) an, bis der Test es freigibt."""

    def __init__(self) -> None:
        super().__init__()
        self.entered = threading.Event()  # Verarbeitung läuft wirklich
        self.release = threading.Event()  # Test gibt sie wieder frei

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        self.entered.set()
        assert self.release.wait(timeout=_TIMEOUT_SECONDS), "Freigabe blieb aus"
        return super().transcribe(audio, language=language)


class BlockingRefiner(SpyRefiner):
    """Hält ``preload()`` (im Worker-Thread) an, bis der Test es freigibt."""

    def __init__(self) -> None:
        super().__init__()
        self.entered = threading.Event()
        self.release = threading.Event()

    def preload(self) -> None:
        self.entered.set()
        assert self.release.wait(timeout=_TIMEOUT_SECONDS), "Freigabe blieb aus"
        super().preload()


class CaptureTranscriber(SpyTranscriber):
    """Hält fest, welcher ``AudioBuffer`` tatsächlich unten ankommt."""

    def __init__(self) -> None:
        super().__init__()
        self.captured: AudioBuffer | None = None

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        self.captured = audio
        return super().transcribe(audio, language=language)


async def wait_for(condition: Callable[[], bool]) -> None:
    """Pollt kurz getaktet, bis die Bedingung erfüllt ist — statt fester Wartezeiten.

    Feste ``sleep``-Dauern wären auf langsamen Maschinen flaky; hier wartet der Test genau
    so lange wie nötig und schlägt nur fehl, wenn die Bedingung gar nicht eintritt.
    """
    deadline = asyncio.get_running_loop().time() + _TIMEOUT_SECONDS
    while not condition():
        assert asyncio.get_running_loop().time() < deadline, "Bedingung trat nicht ein"
        await asyncio.sleep(0.005)


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
async def test_language_query_reaches_the_transcriber() -> None:
    """``?language=en`` darf nicht stillschweigend verpuffen — es muss bis zum STT durchschlagen."""
    stt = SpyTranscriber()
    runtime = build(transcriber=stt)
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat&language=en", content=pcm())

    assert response.status_code == 200
    assert stt.last_language == "en"


@pytest.mark.anyio
async def test_health_answers_while_process_is_running() -> None:
    """Kernzusicherung: ``/health`` antwortet auch mitten in einer Verarbeitung sofort.

    Die Verarbeitung läuft im Worker-Thread; der Event-Loop bleibt dadurch frei. Der Test
    hält ``transcribe()`` fest, während er ``/health`` abfragt — bliebe der Loop blockiert,
    käme die Antwort erst nach der Freigabe (und ``busy`` wäre dann längst wieder False).
    """
    stt = BlockingTranscriber()
    runtime = build(transcriber=stt)
    await runtime.startup()

    async with await client_for(runtime) as client:
        task = asyncio.create_task(client.post("/process?mode=diktat", content=pcm()))
        try:
            await wait_for(stt.entered.is_set)  # Verarbeitung läuft jetzt wirklich

            health = await asyncio.wait_for(client.get("/health"), timeout=_TIMEOUT_SECONDS)
            assert health.status_code == 200
            assert health.json()["busy"] is True
            assert health.json()["status"] == "ready"
        finally:
            stt.release.set()

        response = await asyncio.wait_for(task, timeout=_TIMEOUT_SECONDS)

    assert response.status_code == 200
    assert runtime.health().busy is False


@pytest.mark.anyio
async def test_preload_responds_before_loading_finished() -> None:
    """``/preload`` ist fire-and-forget: 202, *während* das Laden noch läuft.

    Mit einem instantan ladenden Refiner wäre auch ein synchrones ``await runtime.preload()``
    grün. Hier hängt das Laden im Worker-Thread fest, bis der Test es freigibt — ein
    synchroner Endpunkt käme deshalb gar nicht erst zur Antwort.
    """
    llm = BlockingRefiner()
    runtime = build(refiner=llm)
    await runtime.startup()

    async with await client_for(runtime) as client:
        try:
            response = await asyncio.wait_for(client.post("/preload"), timeout=_TIMEOUT_SECONDS)
            assert response.status_code == 202

            await wait_for(llm.entered.is_set)  # Laden hat begonnen ...
            assert runtime.health().llm_loaded is False  # ... ist aber noch nicht durch
        finally:
            llm.release.set()

        await wait_for(lambda: runtime.health().llm_loaded)

    assert llm.preloads == 1


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


@pytest.mark.anyio
async def test_failed_warm_up_reports_failed_and_process_returns_503() -> None:
    """Ein Startfehler ist ein Zustand, kein Verarbeitungsfehler — deshalb 503, nicht 500.

    Und ``/process`` muss *antworten*: Vor dem Fix wäre die Anfrage endlos offen geblieben,
    weil ``process()`` auf ein Ready-Event wartete, das nie gesetzt wird.
    """
    runtime = build(transcriber=FailingWarmUpTranscriber())
    with pytest.raises(RuntimeError, match="Modell kaputt"):
        await runtime.startup()

    async with await client_for(runtime) as client:
        health = (await client.get("/health")).json()
        assert health["status"] == "failed"
        assert health["stt_loaded"] is False
        assert health["error"] is not None and "Modell kaputt" in health["error"]

        response = await asyncio.wait_for(
            client.post("/process?mode=diktat", content=pcm()), timeout=_TIMEOUT_SECONDS
        )

    assert response.status_code == 503
    assert "Modell kaputt" in response.json()["detail"]


@pytest.mark.anyio
async def test_preload_is_not_reported_as_busy() -> None:
    """``busy`` darf nur ein laufendes Diktat meinen — nicht jeden gehaltenen Lock.

    Hinge die Swift-Shell (M3) ihr Overlay an ``busy``, blitzte es sonst schon beim bloßen
    Hotkey-Druck auf (der ``/preload`` auslöst, ohne dass irgendetwas verarbeitet wird).
    Die Gegenprobe — laufende Verarbeitung *meldet* ``busy`` — steckt in
    ``test_health_answers_while_process_is_running``.
    """
    llm = BlockingRefiner()
    runtime = build(refiner=llm)
    await runtime.startup()

    async with await client_for(runtime) as client:
        try:
            assert (await client.post("/preload")).status_code == 202
            await wait_for(llm.entered.is_set)  # Laden läuft und hält den Lock ...

            body = (await asyncio.wait_for(client.get("/health"), _TIMEOUT_SECONDS)).json()
            assert body["busy"] is False  # ... aber verarbeitet wird nichts
            assert body["llm_loaded"] is False  # (und geladen ist es auch noch nicht)
        finally:
            llm.release.set()

        await wait_for(lambda: runtime.health().llm_loaded)


@pytest.mark.anyio
async def test_pcm_body_reaches_the_transcriber_unverfaelscht() -> None:
    """Was Swift schickt, muss beim Transcriber Sample für Sample wieder ankommen.

    Ohne diesen Test bliebe eine Regression in ``_decode_pcm`` (falsche Byte-Reihenfolge,
    falscher dtype, abgeschnittener Puffer) bei allen anderen Tests grün: Sie schicken
    Nullen — und die sehen in jeder Byte-Reihenfolge gleich aus.
    """
    stt = CaptureTranscriber()
    runtime = build(transcriber=stt)
    await runtime.startup()

    # Markante Werte: asymmetrisch, mit Vorzeichen, exakt in float32 darstellbar.
    sent = np.array([0.5, -0.25, 1.0, -1.0, 0.125], dtype="<f4")

    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=sent.tobytes())

    assert response.status_code == 200
    assert stt.captured is not None
    buffer = stt.captured
    assert buffer.samples.dtype == np.float32
    assert buffer.sample_rate == TARGET_SAMPLE_RATE
    assert len(buffer.samples) == len(sent)  # nichts abgeschnitten, nichts angehängt
    np.testing.assert_array_equal(buffer.samples, sent.astype(np.float32))
