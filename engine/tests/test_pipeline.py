"""Tests der Pipeline-Orchestrierung (mit Mock-Backends)."""

from __future__ import annotations

import numpy as np

from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.llm.mock import EchoRefiner, MockRefiner
from typeless_engine.models import AudioBuffer, Mode
from typeless_engine.pipeline import process, process_text
from typeless_engine.stt.mock import MockTranscriber


def _dict() -> DictionaryEngine:
    return DictionaryEngine({"Hot Spot": "HubSpot"})


def test_full_pipeline_applies_dictionary_before_llm() -> None:
    # Der Refiner bekommt bereits ersetzten Text -> wir prüfen, was ankam.
    seen: dict[str, str] = {}

    def capture(text: str, _mode: Mode) -> str:
        seen["input"] = text
        return text.upper()

    audio = AudioBuffer(np.zeros(16_000, dtype=np.float32))
    result = process(
        audio,
        Mode.DIKTAT,
        transcriber=MockTranscriber(text="wir nutzen Hot Spot"),
        refiner=MockRefiner(capture),
        dictionary=_dict(),
    )
    assert seen["input"] == "wir nutzen HubSpot"  # Wörterbuch lief vor dem LLM
    assert result.raw_text == "wir nutzen Hot Spot"
    assert result.dictionary_text == "wir nutzen HubSpot"
    assert result.final_text == "WIR NUTZEN HUBSPOT"
    assert result.refined is True


def test_process_text_without_stt() -> None:
    result = process_text(
        "wir nutzen Hot Spot",
        Mode.DIKTAT,
        refiner=EchoRefiner(),
        dictionary=_dict(),
    )
    assert result.final_text == "wir nutzen HubSpot"


def test_empty_transcription_skips_llm() -> None:
    called = {"llm": False}

    def should_not_run(text: str, _mode: Mode) -> str:
        called["llm"] = True
        return text

    audio = AudioBuffer(np.zeros(1600, dtype=np.float32))
    result = process(
        audio,
        Mode.DIKTAT,
        transcriber=MockTranscriber(text="   "),
        refiner=MockRefiner(should_not_run),
        dictionary=_dict(),
    )
    assert called["llm"] is False
    assert result.refined is False
    assert result.fallback_reason == "leerer Text"


def test_sanity_fallback_on_bad_llm_output() -> None:
    # LLM liefert im Diktat-Modus absurd langen Output -> Fallback auf bereinigten Text.
    def blow_up(text: str, _mode: Mode) -> str:
        return text * 50

    result = process_text(
        "kurzer diktierter satz",
        Mode.DIKTAT,
        refiner=MockRefiner(blow_up),
        dictionary=DictionaryEngine({}),
    )
    assert result.refined is False
    assert result.final_text == "kurzer diktierter satz"
    assert result.fallback_reason is not None


def test_timings_recorded() -> None:
    audio = AudioBuffer(np.zeros(16_000, dtype=np.float32))
    result = process(
        audio,
        Mode.SLACK,
        transcriber=MockTranscriber(text="hallo team"),
        refiner=EchoRefiner(),
        dictionary=DictionaryEngine({}),
    )
    assert "transcribe" in result.timings_ms
    assert "dictionary" in result.timings_ms
    assert "refine" in result.timings_ms
