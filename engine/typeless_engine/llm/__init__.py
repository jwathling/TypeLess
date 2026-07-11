"""LLM-Sprachverbesserungs-Backends (austauschbar hinter dem ``Refiner``-Interface)."""

from __future__ import annotations

from .mock import EchoRefiner, MockRefiner

__all__ = ["EchoRefiner", "MockRefiner"]

# MLXRefiner wird bewusst NICHT eager importiert (mlx_lm nur auf Apple Silicon).
