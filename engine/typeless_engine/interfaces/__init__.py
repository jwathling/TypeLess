"""Abstrakte Schnittstellen. Der Kern hängt ausschließlich von diesen ab."""

from __future__ import annotations

from .refiner import Refiner
from .transcriber import Transcriber

__all__ = ["Refiner", "Transcriber"]
