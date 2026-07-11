"""Zentrale Logging-Konfiguration.

Bewusst schlank: ein Konsolen-Handler mit strukturiertem Format. Der Sidecar (M2) kann
später zusätzlich in eine Datei unter Application Support schreiben.
"""

from __future__ import annotations

import logging
import os

_CONFIGURED = False


def configure_logging(level: str | None = None) -> None:
    """Richtet das Root-Logging genau einmal ein (idempotent)."""
    global _CONFIGURED
    if _CONFIGURED:
        return
    resolved = (level or os.environ.get("TYPELESS_LOG_LEVEL") or "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, resolved, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    _CONFIGURED = True


def get_logger(name: str) -> logging.Logger:
    """Liefert einen Logger und stellt sicher, dass Logging konfiguriert ist."""
    configure_logging()
    return logging.getLogger(name)
