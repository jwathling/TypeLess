"""Konfiguration der Engine (Backends, Modelle, Pfade, Schwellenwerte).

Werte werden aus Umgebungsvariablen mit Präfix ``TYPELESS_`` gelesen; sonst gelten die
Defaults. Die Swift-App bzw. der Sidecar (M2) kann diese Werte pro Start setzen.
"""

from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

from .llm.mlx_refiner import DEFAULT_MODEL as DEFAULT_LLM_MODEL
from .models import Mode
from .stt.mlx_whisper import DEFAULT_MODEL as DEFAULT_STT_MODEL

# Standard-Speicherort für nutzerbezogene Daten (Wörterbuch etc.).
APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "TypeLess"
DEFAULT_DICTIONARY_PATH = APP_SUPPORT_DIR / "dictionary.json"

Backend = Literal["mlx", "mock"]


class EngineConfig(BaseSettings):
    """Laufzeitkonfiguration der Engine."""

    model_config = SettingsConfigDict(env_prefix="TYPELESS_", extra="ignore")

    stt_backend: Backend = "mlx"
    stt_model: str = DEFAULT_STT_MODEL

    llm_backend: Backend = "mlx"
    llm_model: str = DEFAULT_LLM_MODEL

    language: str | None = None  # None => Auto-Detect (empfohlen für DE+EN)
    default_mode: Mode = Mode.DIKTAT

    dictionary_path: Path = Field(default=DEFAULT_DICTIONARY_PATH)

    log_level: str = "INFO"
