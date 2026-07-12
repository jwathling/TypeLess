"""Tests der EngineRuntime — Lebenszyklus, Serialisierung, Fehler-Resilienz.

Läuft vollständig ohne MLX: Die Bausteine werden als Test-Doubles injiziert.
"""

from __future__ import annotations

import asyncio
import threading

import numpy as np
import pytest

from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, Transcriber
from typeless_engine.models import TARGET_SAMPLE_RATE, AudioBuffer, Mode, Transcription
from typeless_engine.server.runtime import EngineRuntime


class SpyTranscriber(Transcriber):
    """Zählt Warm-ups und Transkriptionen; kann Fehler simulieren."""

    def __init__(self, text: str = "hot spot ist super", fail: bool = False) -> None:
        self.warm_ups = 0
        self.calls = 0
        self._text = text
        self._fail = fail

    def warm_up(self) -> None:
        self.warm_ups += 1

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        self.calls += 1
        if self._fail:
            raise RuntimeError("STT kaputt")
        return Transcription(text=self._text, language="de", duration_seconds=1.0)


class SpyRefiner(Refiner):
    """Zählt Preloads/Unloads/gleichzeitige Aufrufe; kann beim Laden oder Generieren scheitern.

    ``max_concurrent`` und ``preloads`` sind die beiden Signale, mit denen sich fehlende
    Serialisierung in ``EngineRuntime.process`` nachweisen lässt: Ohne Lock würden zwei
    gleichzeitige ``process``-Aufrufe beide ``_llm_loaded is False`` sehen (bevor die erste
    Coroutine beim Thread-Wechsel yieldet) und beide ``preload()`` aufrufen; und ihre
    ``refine()``-Aufrufe liefen im Worker-Thread parallel statt nacheinander.
    """

    def __init__(self, fail_preload: bool = False, fail_refine: bool = False) -> None:
        self.preloads = 0
        self.unloads = 0
        self.refines = 0
        self.in_flight = 0
        self.max_concurrent = 0
        self._fail_preload = fail_preload
        self._fail_refine = fail_refine
        self._in_flight_lock = threading.Lock()

    def preload(self) -> None:
        if self._fail_preload:
            raise RuntimeError("LLM lädt nicht")
        self.preloads += 1

    def unload(self) -> None:
        self.unloads += 1

    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        with self._in_flight_lock:
            self.in_flight += 1
            self.max_concurrent = max(self.max_concurrent, self.in_flight)
        try:
            self.refines += 1
            if self._fail_refine:
                raise RuntimeError("Generierung kaputt")
            # Nur den ersten Buchstaben großschreiben (nicht ``str.capitalize()``, das den
            # Rest der Zeichenkette kleinschreiben und damit die kanonische
            # Wörterbuch-Schreibweise wie "HubSpot" zerstören würde).
            return text[:1].upper() + text[1:] + "."
        finally:
            with self._in_flight_lock:
                self.in_flight -= 1


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def make_runtime(
    transcriber: Transcriber | None = None,
    refiner: Refiner | None = None,
    entries: dict[str, str] | None = None,
) -> EngineRuntime:
    return EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber or SpyTranscriber(),
        refiner=refiner or SpyRefiner(),
        dictionary=DictionaryEngine(entries or {"hot spot": "HubSpot"}),
    )


def audio(seconds: float = 1.0) -> AudioBuffer:
    return AudioBuffer(samples=np.zeros(int(TARGET_SAMPLE_RATE * seconds), dtype=np.float32))


@pytest.mark.anyio
async def test_startup_warms_stt() -> None:
    stt = SpyTranscriber()
    runtime = make_runtime(transcriber=stt)

    assert runtime.health().status == "starting"
    await runtime.startup()

    assert stt.warm_ups == 1
    assert runtime.health().status == "ready"
    assert runtime.health().stt_loaded is True


@pytest.mark.anyio
async def test_preload_is_idempotent() -> None:
    llm = SpyRefiner()
    runtime = make_runtime(refiner=llm)
    await runtime.startup()

    await runtime.preload()
    await runtime.preload()
    await runtime.preload()

    assert llm.preloads == 1
    assert runtime.health().llm_loaded is True


@pytest.mark.anyio
async def test_process_without_preload_loads_llm() -> None:
    llm = SpyRefiner()
    runtime = make_runtime(refiner=llm)
    await runtime.startup()

    result = await runtime.process(audio(), Mode.DIKTAT)

    assert llm.preloads == 1
    assert result.refined is True
    # Wörterbuch greift vor dem LLM:
    assert "HubSpot" in result.dictionary_text
    assert "HubSpot" in result.final_text


@pytest.mark.anyio
async def test_process_waits_for_startup() -> None:
    """Ein Diktat vor dem Ende des Warm-ups darf nicht scheitern, sondern wartet."""
    stt = SpyTranscriber()
    runtime = make_runtime(transcriber=stt)

    task = asyncio.create_task(runtime.process(audio(), Mode.DIKTAT))
    await asyncio.sleep(0)  # dem Task Gelegenheit geben, zu blockieren
    assert not task.done()

    await runtime.startup()
    result = await task

    assert result.final_text != ""
    assert stt.calls == 1


@pytest.mark.anyio
async def test_concurrent_process_calls_are_serialized() -> None:
    """Ohne den Lock in ``EngineRuntime.process`` wäre dieser Test auch grün — die beiden
    Ergebnisse kämen trotzdem korrekt zurück. Die eigentliche Serialisierung zeigt sich erst
    an ``llm.preloads`` (ohne Lock: 2, weil beide Coroutinen ``_llm_loaded is False`` sehen,
    bevor die erste beim Thread-Wechsel yieldet) und an ``llm.max_concurrent`` (ohne Lock: 2,
    weil beide ``refine()``-Aufrufe im Worker-Thread gleichzeitig liefen)."""
    llm = SpyRefiner()
    runtime = make_runtime(refiner=llm)
    await runtime.startup()

    results = await asyncio.gather(
        runtime.process(audio(), Mode.DIKTAT),
        runtime.process(audio(), Mode.DIKTAT),
    )

    assert len(results) == 2
    for result in results:
        assert "HubSpot" in result.final_text
    assert llm.preloads == 1
    assert llm.max_concurrent == 1


@pytest.mark.anyio
async def test_llm_load_failure_yields_raw_text() -> None:
    """LLM kaputt: Das Diktat geht nicht verloren, es kommt unpoliert zurück."""
    runtime = make_runtime(refiner=SpyRefiner(fail_preload=True))
    await runtime.startup()

    result = await runtime.process(audio(), Mode.DIKTAT)

    assert result.refined is False
    assert result.final_text == result.dictionary_text
    assert "HubSpot" in result.final_text
    assert result.fallback_reason is not None and "LLM" in result.fallback_reason


@pytest.mark.anyio
async def test_llm_generation_failure_yields_raw_text() -> None:
    runtime = make_runtime(refiner=SpyRefiner(fail_refine=True))
    await runtime.startup()

    result = await runtime.process(audio(), Mode.DIKTAT)

    assert result.refined is False
    assert result.final_text == result.dictionary_text
    assert result.fallback_reason is not None and "LLM" in result.fallback_reason


@pytest.mark.anyio
async def test_stt_failure_propagates() -> None:
    """Ohne Transkription gibt es keinen Text, den man retten könnte."""
    runtime = make_runtime(transcriber=SpyTranscriber(fail=True))
    await runtime.startup()

    with pytest.raises(RuntimeError, match="STT kaputt"):
        await runtime.process(audio(), Mode.DIKTAT)
