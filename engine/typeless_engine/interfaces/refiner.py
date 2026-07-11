"""Abstrakte Sprachverbesserungs-Schnittstelle (LLM-Nachbearbeitung)."""

from __future__ import annotations

from abc import ABC, abstractmethod

from ..models import Mode


class Refiner(ABC):
    """Verbessert/transformiert transkribierten Text je nach Modus."""

    @abstractmethod
    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        """Gibt den verbesserten Text zurück.

        Args:
            text: Bereits wörterbuch-bereinigter Rohtext.
            mode: Zielmodus (Diktat, Prompt, E-Mail, Slack, Brain Dump).
            language: Optionaler Sprachhinweis aus der Transkription.
        """
        raise NotImplementedError

    def preload(self) -> None:  # noqa: B027 - optionaler Hook, bewusst No-op
        """Lädt das Modell vorab (spekulativer Preload beim Hotkey-Druck). Default: No-op."""

    def unload(self) -> None:  # noqa: B027 - optionaler Hook, bewusst No-op
        """Gibt Modellressourcen frei (Idle-Unload / Memory-Pressure). Default: No-op."""
