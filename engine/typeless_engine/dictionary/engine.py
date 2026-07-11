"""Deterministische Phrasen-Ersetzung.

Ersetzt gesprochene Fehlerkennungen durch kanonische Schreibweisen (z. B. "Hot Spot" ->
"HubSpot", "Chat GPT" -> "ChatGPT"), bevor der Text an das LLM geht. Bewusst regelbasiert
und vorhersagbar — keine KI.

Eigenschaften:
* case-insensitiv beim Matchen, kanonische Schreibweise beim Ersetzen,
* wortgrenzen-bewusst ("Hot Spotty" wird NICHT getroffen),
* whitespace-tolerant ("Hot   Spot" == "Hot Spot"),
* längster Treffer zuerst (mehrwortige Einträge vor Teil-Überschneidungen),
* beliebig viele Einträge aus JSON.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from ..logging_ import get_logger

_log = get_logger(__name__)


class DictionaryEngine:
    """Wendet deterministische Ersetzungen auf einen Text an."""

    def __init__(self, entries: dict[str, str]) -> None:
        self._entries = dict(entries)
        self._lookup: dict[str, str] = {}
        self._pattern: re.Pattern[str] | None = None
        self._compile()

    # ---- Konstruktion -------------------------------------------------------

    @classmethod
    def from_json(cls, path: str | Path) -> DictionaryEngine:
        """Lädt Einträge aus einer JSON-Datei ``{ "gesprochen": "kanonisch", ... }``."""
        p = Path(path)
        data = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError(f"Wörterbuch-JSON muss ein Objekt sein, ist {type(data).__name__}.")
        entries = {str(k): str(v) for k, v in data.items()}
        _log.info("Wörterbuch geladen: %d Einträge aus %s", len(entries), p)
        return cls(entries)

    @classmethod
    def load_or_empty(cls, path: str | Path | None) -> DictionaryEngine:
        """Lädt aus ``path`` oder liefert ein leeres Wörterbuch (No-op), falls nicht vorhanden."""
        if path is None:
            return cls({})
        p = Path(path)
        if not p.exists():
            _log.info("Kein Wörterbuch unter %s — verwende leeres.", p)
            return cls({})
        return cls.from_json(p)

    # ---- Interne Regex-Kompilierung ----------------------------------------

    @staticmethod
    def _normalize(text: str) -> str:
        """Schlüssel-Normalisierung: Kleinbuchstaben + kollabierter Whitespace."""
        return re.sub(r"\s+", " ", text.strip().lower())

    def _compile(self) -> None:
        self._lookup = {}
        valid_keys: list[str] = []
        for key, value in self._entries.items():
            norm = self._normalize(key)
            if not norm:
                continue
            self._lookup[norm] = value
            valid_keys.append(key)

        if not valid_keys:
            self._pattern = None
            return

        # Längste Schlüssel zuerst, damit mehrwortige Treffer Vorrang haben.
        valid_keys.sort(key=lambda k: len(self._normalize(k)), reverse=True)
        alternatives = [self._key_to_regex(k) for k in valid_keys]
        self._pattern = re.compile(
            r"(?<!\w)(?:" + "|".join(alternatives) + r")(?!\w)",
            re.IGNORECASE | re.UNICODE,
        )

    @staticmethod
    def _key_to_regex(key: str) -> str:
        """Baut aus einem Schlüssel ein whitespace-tolerantes Regex-Fragment."""
        tokens = key.strip().split()
        return r"\s+".join(re.escape(tok) for tok in tokens)

    # ---- Anwendung ----------------------------------------------------------

    def apply(self, text: str) -> str:
        """Ersetzt alle Treffer durch ihre kanonische Schreibweise."""
        if self._pattern is None or not text:
            return text

        def _replace(match: re.Match[str]) -> str:
            norm = self._normalize(match.group(0))
            return self._lookup.get(norm, match.group(0))

        return self._pattern.sub(_replace, text)

    def __len__(self) -> int:
        return len(self._lookup)
