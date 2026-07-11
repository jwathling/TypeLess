"""Factory: baut konkrete Backends aus der Konfiguration (Dependency Injection).

Dies ist die einzige Stelle, die konkrete Engine-Klassen kennt. Der restliche Code
arbeitet nur mit den Interfaces ``Transcriber`` / ``Refiner``. Ein neues Backend (z. B.
whisper.cpp) wird hier registriert, ohne die Pipeline zu berühren.
"""

from __future__ import annotations

from .config import EngineConfig
from .dictionary import DictionaryEngine
from .interfaces import Refiner, Transcriber
from .llm.mock import MockRefiner
from .stt.mock import MockTranscriber


def build_transcriber(config: EngineConfig) -> Transcriber:
    if config.stt_backend == "mlx":
        from .stt.mlx_whisper import MLXWhisperTranscriber  # lazy: Apple-Silicon-only

        return MLXWhisperTranscriber(config.stt_model)
    if config.stt_backend == "mock":
        return MockTranscriber()
    raise ValueError(f"Unbekanntes STT-Backend: {config.stt_backend}")


def build_refiner(config: EngineConfig) -> Refiner:
    if config.llm_backend == "mlx":
        from .llm.mlx_refiner import MLXRefiner  # lazy: Apple-Silicon-only

        return MLXRefiner(config.llm_model)
    if config.llm_backend == "mock":
        return MockRefiner()
    raise ValueError(f"Unbekanntes LLM-Backend: {config.llm_backend}")


def build_dictionary(config: EngineConfig) -> DictionaryEngine:
    return DictionaryEngine.load_or_empty(config.dictionary_path)
