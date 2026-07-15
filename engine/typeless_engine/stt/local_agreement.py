"""LocalAgreement-2 — die Streaming-Brücke für Whisper.

Whisper ist auf 30-s-Fenster ausgelegt und streamt nicht von Haus aus. LocalAgreement überbrückt
das: Die Engine transkribiert das bisher Gesprochene wiederholt; ein Wort gilt erst als
**festgeschrieben**, sobald ZWEI aufeinanderfolgende Durchläufe an derselben Stelle dasselbe Wort
liefern. Festgeschriebene Wörter ändern sich nie mehr.

Reine Textverarbeitung (Wortlisten) — bewusst ohne jeden MLX-Bezug, damit sie überall testbar ist.
"""

from __future__ import annotations


def _gemeinsamer_praefix(a: list[str], b: list[str]) -> list[str]:
    """Längster gemeinsamer Präfix zweier Wortlisten."""
    n = 0
    while n < len(a) and n < len(b) and a[n] == b[n]:
        n += 1
    return a[:n]


class LocalAgreement:
    """Leitet aus aufeinanderfolgenden Voll-Hypothesen die festgeschriebenen Wörter ab."""

    def __init__(self) -> None:
        self._committed: list[str] = []
        self._prev: list[str] = []

    def insert(self, hypothesis: list[str]) -> list[str]:
        """Nimmt die aktuelle Voll-Hypothese (Wortliste). Liefert die NEU festgeschriebenen Wörter.

        Festgeschrieben wird der gemeinsame Präfix der letzten und der aktuellen Hypothese, soweit
        er über das schon Festgeschriebene hinausgeht. Widerspricht die neue Hypothese dem bereits
        Festgeschriebenen, wird NICHT zurückgerollt (Ausgegebenes lässt sich nicht zurücknehmen).
        """
        agreed = _gemeinsamer_praefix(self._prev, hypothesis)
        self._prev = list(hypothesis)
        if len(agreed) <= len(self._committed):
            return []
        newly = agreed[len(self._committed) :]
        self._committed = list(agreed)
        return newly

    def finalize(self) -> list[str]:
        """Schreibt den Rest der letzten Hypothese fest, ohne zweite Bestätigung."""
        if len(self._prev) <= len(self._committed):
            return []
        newly = self._prev[len(self._committed) :]
        self._committed = list(self._prev)
        return newly

    @property
    def committed(self) -> list[str]:
        return list(self._committed)
