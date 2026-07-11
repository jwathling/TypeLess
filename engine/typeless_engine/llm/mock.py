"""Mock-Refiner für Tests und plattformunabhängige Entwicklung (ohne MLX)."""

from __future__ import annotations

from collections.abc import Callable

from ..interfaces import Refiner
from ..models import Mode


class EchoRefiner(Refiner):
    """Gibt den Eingabetext unverändert zurück (nützlich als neutrale Baseline)."""

    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        return text


class MockRefiner(Refiner):
    """Konfigurierbarer Refiner: wendet eine übergebene Funktion an.

    Ermöglicht deterministische Pipeline-Tests, inklusive Sanity-Fallback-Szenarien
    (z. B. eine Funktion, die absichtlich einen leeren oder überlangen Text liefert).
    """

    def __init__(self, transform: Callable[[str, Mode], str] | None = None) -> None:
        self._transform = transform or (lambda text, _mode: text)

    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        return self._transform(text, mode)
