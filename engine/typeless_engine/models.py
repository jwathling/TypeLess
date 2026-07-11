"""Kern-Datentypen der Engine.

Diese Typen bilden den Vertrag zwischen den Modulen. Sie enthalten keine Logik, die von
einer konkreten Engine (MLX, whisper.cpp, ...) abhängt.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum

import numpy as np

# Whisper erwartet 16 kHz Mono. Der gesamte Kern rechnet in diesem Format.
TARGET_SAMPLE_RATE = 16_000


class Mode(StrEnum):
    """Ausgabemodus der Sprachverbesserung."""

    DIKTAT = "diktat"
    PROMPT = "prompt"
    EMAIL = "email"
    SLACK = "slack"
    BRAINDUMP = "braindump"

    @classmethod
    def from_string(cls, value: str) -> Mode:
        try:
            return cls(value.strip().lower())
        except ValueError as exc:
            valid = ", ".join(m.value for m in cls)
            raise ValueError(f"Unbekannter Modus '{value}'. Gültig: {valid}") from exc


@dataclass
class AudioBuffer:
    """Ein Audiopuffer: Mono-Float32-Samples im Bereich [-1, 1] plus Sample-Rate."""

    samples: np.ndarray
    sample_rate: int = TARGET_SAMPLE_RATE

    def __post_init__(self) -> None:
        if self.samples.ndim != 1:
            raise ValueError(f"Erwarte Mono (1D), erhalten {self.samples.ndim}D.")
        if self.samples.dtype != np.float32:
            self.samples = self.samples.astype(np.float32)
        if self.sample_rate <= 0:
            raise ValueError(f"Ungültige Sample-Rate: {self.sample_rate}")

    @property
    def duration_seconds(self) -> float:
        return len(self.samples) / self.sample_rate


@dataclass(frozen=True)
class Transcription:
    """Ergebnis der Speech-to-Text-Stufe."""

    text: str
    language: str | None = None
    duration_seconds: float | None = None


@dataclass(frozen=True)
class ProcessResult:
    """Vollständiges Pipeline-Ergebnis inkl. Zwischenschritten für Transparenz/Debugging."""

    raw_text: str
    """Roher STT-Text vor jeder Nachbearbeitung."""

    dictionary_text: str
    """Text nach deterministischer Wörterbuch-Ersetzung (Eingang ins LLM)."""

    final_text: str
    """Endgültiger Text (LLM-Ergebnis oder Fallback auf ``dictionary_text``)."""

    mode: Mode
    language: str | None = None
    refined: bool = True
    """True, wenn das LLM-Ergebnis übernommen wurde; False bei Sanity-Fallback."""

    fallback_reason: str | None = None
    timings_ms: dict[str, float] = field(default_factory=dict)
