"""Abstrakte Schnittstellen. Der Kern hängt ausschließlich von diesen ab."""

from __future__ import annotations

from .refiner import Refiner
from .transcriber import StreamingTranscriber, Transcriber

__all__ = ["Refiner", "StreamingTranscriber", "Transcriber"]
