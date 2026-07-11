"""Sanity-Check gegen LLM-Halluzinationen / Ausreißer.

Vergleicht den LLM-Output mit dem (wörterbuch-bereinigten) Eingabetext. Schlägt der Check
fehl, fällt die Pipeline auf den Eingabetext zurück, statt einen kaputten Output einzufügen.

Zwei Prüfungen, beide modusabhängig:

1. **Länge.** Diktat ändert kaum Länge -> strikte Grenzen (Standard 0,5x–2,0x).
   Transformierende Modi (Prompt, E-Mail, Brain Dump) dürfen stark abweichen -> nur eine
   absolute Obergrenze gegen völlige Entgleisungen. Leerer Output scheitert immer.

2. **Divergenz.** Nur im Diktat-Modus: Der Längen-Check ist blind dafür, dass ein Modell
   einen Satz verschluckt und dafür einen anderen ausschmückt — die Länge bleibt dabei
   unauffällig. Deshalb wird zusätzlich geprüft, wieviel inhaltliche Substanz der Eingabe
   im Output fehlt. Erlaubt bleibt, was der Modus ausdrücklich darf: Füllwörter entfernen
   (Liste unten) und Tippfehler korrigieren (unscharfer Abgleich).

   **Selbstkorrekturen** ("am Dienstag, nein, am Mittwoch") sind der eine Fall, in dem
   Diktat inhaltlich löschen *soll*. Das kollidiert mit dem Divergenz-Check, deshalb wird
   dessen Schwelle gelockert — aber nur, wenn im Rohtext ein Korrektur-Marker steht. Ohne
   Marker bleibt der Schutz streng; sonst wäre er wertlos.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from difflib import SequenceMatcher

from ..models import Mode
from ..modes import get_mode_spec

# Kurze Wörter sind fast immer Funktionswörter; sie tragen keine Substanz und ihr Wegfall
# ist kein Inhaltsverlust.
_MIN_CONTENT_LENGTH = 4

# Füllwörter, die der Diktat-Modus entfernen darf, ohne dass es als Verlust zählt.
_FILLERS = frozenset(
    {
        "also",
        "ähm",
        "ähmm",
        "öhm",
        "halt",
        "quasi",
        "sozusagen",
        "irgendwie",
        "eigentlich",
        "naja",
        "tja",
        "genau",
        "praktisch",
    }
)

# Ab dieser Ähnlichkeit gilt ein Wort als "dasselbe Wort, nur korrigiert"
# (z. B. "entwikeln" -> "entwickeln").
_FUZZY_THRESHOLD = 0.8

# Wendungen, mit denen sich Sprechende selbst korrigieren. Stehen sie im Rohtext, darf der
# Diktat-Output mehr Inhalt weglassen (nämlich die zurückgenommene Fassung).
_CORRECTION_MARKERS = (
    r"nein",
    r"quatsch",
    r"sorry",
    r"ich meine",
    r"besser gesagt",
    r"genauer gesagt",
    r"also nicht",
    r"korrektur",
    r"streich das",
)
_CORRECTION_RE = re.compile(
    r"(?<!\w)(?:" + "|".join(_CORRECTION_MARKERS) + r")(?!\w)", re.IGNORECASE | re.UNICODE
)


@dataclass(frozen=True)
class SanityConfig:
    """Schwellenwerte für den Sanity-Check."""

    diktat_min_ratio: float = 0.5
    diktat_max_ratio: float = 2.0
    absolute_max_ratio: float = 10.0

    diktat_max_missing_ratio: float = 0.05
    """Anteil der Inhaltswörter, der im Diktat-Output fehlen darf."""

    diktat_max_missing_ratio_corrected: float = 0.35
    """Wie ``diktat_max_missing_ratio``, aber wenn der Rohtext eine Selbstkorrektur enthält:
    Dann soll die zurückgenommene Fassung ja gerade verschwinden."""


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
        return _divergence_check(src, out, cfg)

    return True, None


def _divergence_check(src: str, out: str, cfg: SanityConfig) -> tuple[bool, str | None]:
    """Prüft, ob dem Diktat-Output inhaltliche Substanz der Eingabe fehlt."""
    expected = _content_words(src)
    if not expected:
        return True, None

    present = _content_words(out)
    missing = [word for word in expected if not _is_present(word, present)]

    corrected = _CORRECTION_RE.search(src) is not None
    limit = cfg.diktat_max_missing_ratio_corrected if corrected else cfg.diktat_max_missing_ratio

    missing_ratio = len(missing) / len(expected)
    if missing_ratio > limit:
        preview = ", ".join(sorted(missing)[:5])
        return False, f"Diktat-Output fehlt Inhalt ({missing_ratio:.0%}): {preview}"
    return True, None


def _content_words(text: str) -> set[str]:
    """Extrahiert die bedeutungstragenden Wörter.

    Ausgenommen sind Funktionswörter (zu kurz), Füllwörter und Korrektur-Wendungen: Sie alle
    dürfen im Diktat-Output verschwinden, ohne dass Inhalt verloren geht.
    """
    words = re.findall(r"\w+", text.lower(), flags=re.UNICODE)
    return {
        w
        for w in words
        if len(w) >= _MIN_CONTENT_LENGTH and w not in _FILLERS and not _CORRECTION_RE.fullmatch(w)
    }


def _is_present(word: str, candidates: set[str]) -> bool:
    """Ob ``word`` im Output vorkommt — exakt oder als korrigierte Schreibweise."""
    if word in candidates:
        return True
    return any(
        SequenceMatcher(None, word, other).ratio() >= _FUZZY_THRESHOLD for other in candidates
    )
