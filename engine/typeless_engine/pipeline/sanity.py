"""Sanity-Check gegen LLM-Halluzinationen / Ausreißer.

Vergleicht den LLM-Output mit dem (wörterbuch-bereinigten) Eingabetext. Schlägt der Check
fehl, fällt die Pipeline auf den Eingabetext zurück, statt einen kaputten Output einzufügen.

Die Strenge ist modusabhängig:
* Diktat ändert kaum Länge -> strikte Grenzen (Standard 0,5x–2,0x).
* Transformierende Modi (Prompt, E-Mail, Brain Dump) dürfen stark abweichen -> nur eine
  absolute Obergrenze gegen völlige Entgleisungen.
* Leerer Output ist immer ein Fehlschlag (bei nicht-leerer Eingabe).
"""

from __future__ import annotations

from dataclasses import dataclass

from ..models import Mode
from ..modes import get_mode_spec


@dataclass(frozen=True)
class SanityConfig:
    """Schwellenwerte für den Sanity-Check."""

    diktat_min_ratio: float = 0.5
    diktat_max_ratio: float = 2.0
    absolute_max_ratio: float = 10.0


def sanity_check(
    input_text: str,
    output_text: str,
    mode: Mode,
    config: SanityConfig | None = None,
) -> tuple[bool, str | None]:
    """Prüft ``output_text`` gegen ``input_text``.

    Returns:
        ``(ok, reason)`` — bei ``ok is False`` beschreibt ``reason`` den Grund.
    """
    cfg = config or SanityConfig()
    src = input_text.strip()
    out = output_text.strip()

    if not src:
        return True, None  # nichts zu prüfen
    if not out:
        return False, "leerer LLM-Output"

    ratio = len(out) / len(src)
    if ratio > cfg.absolute_max_ratio:
        return False, f"Output {ratio:.1f}x länger als Eingabe (> {cfg.absolute_max_ratio}x)"

    if get_mode_spec(mode).strict_length:
        if ratio < cfg.diktat_min_ratio:
            return False, f"Diktat-Output zu kurz ({ratio:.2f}x < {cfg.diktat_min_ratio}x)"
        if ratio > cfg.diktat_max_ratio:
            return False, f"Diktat-Output zu lang ({ratio:.2f}x > {cfg.diktat_max_ratio}x)"

    return True, None
