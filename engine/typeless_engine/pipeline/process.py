"""Die zentrale Verarbeitungs-Pipeline.

``process`` bekommt Audio + Modus + die (per Interface abstrahierten) Bausteine und liefert
ein ``ProcessResult`` mit allen Zwischenschritten und Timings. Der Ablauf:

    Audio --Transcriber--> Rohtext --Wörterbuch--> bereinigt --Refiner--> Sanity-Check
                                                                              |
                                                              ok? final = LLM : final = bereinigt
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from ..dictionary import DictionaryEngine
from ..interfaces import Refiner, Transcriber
from ..logging_ import get_logger
from ..models import AudioBuffer, Mode, ProcessResult
from .sanity import SanityConfig, sanity_check

_log = get_logger(__name__)


@dataclass(frozen=True)
class PipelineConfig:
    """Konfiguration der Pipeline-Ausführung."""

    language: str | None = None  # None => Auto-Detect
    sanity: SanityConfig = SanityConfig()


def process(
    audio: AudioBuffer,
    mode: Mode,
    *,
    transcriber: Transcriber,
    refiner: Refiner,
    dictionary: DictionaryEngine,
    config: PipelineConfig | None = None,
) -> ProcessResult:
    """Führt die vollständige Pipeline aus (Audio -> fertiger Text)."""
    cfg = config or PipelineConfig()
    timings: dict[str, float] = {}

    t0 = time.perf_counter()
    transcription = transcriber.transcribe(audio, language=cfg.language)
    timings["transcribe"] = _elapsed_ms(t0)
    raw_text = transcription.text
    _log.debug("Rohtext (%d Zeichen): %s", len(raw_text), raw_text)

    result = _refine_text(
        raw_text=raw_text,
        mode=mode,
        refiner=refiner,
        dictionary=dictionary,
        sanity=cfg.sanity,
        language=transcription.language,
        timings=timings,
    )
    return result


def process_text(
    raw_text: str,
    mode: Mode,
    *,
    refiner: Refiner,
    dictionary: DictionaryEngine,
    sanity: SanityConfig | None = None,
    language: str | None = None,
) -> ProcessResult:
    """Wie ``process``, aber ab bereits vorhandenem Rohtext (ohne STT).

    Nützlich für Tests, die CLI (``refine``) und die spätere Wiederverarbeitung.
    """
    return _refine_text(
        raw_text=raw_text,
        mode=mode,
        refiner=refiner,
        dictionary=dictionary,
        sanity=sanity or SanityConfig(),
        language=language,
        timings={},
    )


def _refine_text(
    *,
    raw_text: str,
    mode: Mode,
    refiner: Refiner,
    dictionary: DictionaryEngine,
    sanity: SanityConfig,
    language: str | None,
    timings: dict[str, float],
) -> ProcessResult:
    t0 = time.perf_counter()
    dictionary_text = dictionary.apply(raw_text)
    timings["dictionary"] = _elapsed_ms(t0)

    # Leerer Text: gar nicht erst ans LLM.
    if not dictionary_text.strip():
        return ProcessResult(
            raw_text=raw_text,
            dictionary_text=dictionary_text,
            final_text=dictionary_text,
            mode=mode,
            language=language,
            refined=False,
            fallback_reason="leerer Text",
            timings_ms=timings,
        )

    t0 = time.perf_counter()
    refined_text = refiner.refine(dictionary_text, mode, language=language)
    timings["refine"] = _elapsed_ms(t0)

    ok, reason = sanity_check(dictionary_text, refined_text, mode, sanity)
    if ok:
        final_text = refined_text.strip()
    else:
        final_text = dictionary_text
        _log.warning("Sanity-Fallback (%s): verwende wörterbuch-bereinigten Rohtext.", reason)

    return ProcessResult(
        raw_text=raw_text,
        dictionary_text=dictionary_text,
        final_text=final_text,
        mode=mode,
        language=language,
        refined=ok,
        fallback_reason=None if ok else reason,
        timings_ms=timings,
    )


def _elapsed_ms(start: float) -> float:
    return round((time.perf_counter() - start) * 1000, 1)
