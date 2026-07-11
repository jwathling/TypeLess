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
DEFAULT_SOCKET_PATH = APP_SUPPORT_DIR / "typeless.sock"

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

    socket_path: Path = Field(default=DEFAULT_SOCKET_PATH)
    """Unix-Domain-Socket, über den die Swift-App den Sidecar anspricht (kein TCP-Port)."""

    idle_unload_seconds: float = 300.0
    """Nach so langer Untätigkeit wird das LLM entladen. Das STT bleibt warm."""

    idle_check_interval_seconds: float = 10.0
    """Wie oft der Idle-Wächter prüft."""

    log_level: str = "INFO"
