"""Tests der deterministischen Wörterbuch-Engine."""

from __future__ import annotations

import json

import pytest

from typeless_engine.dictionary import DictionaryEngine

ENTRIES = {
    "Hot Spot": "HubSpot",
    "Hub Spot": "HubSpot",
    "Sales Force": "Salesforce",
    "Chat GPT": "ChatGPT",
    "Study Plus": "StudyPlus",
    "Claude Code": "Claude Code",
}


@pytest.fixture
def engine() -> DictionaryEngine:
    return DictionaryEngine(ENTRIES)


def test_basic_multiword_replacement(engine: DictionaryEngine) -> None:
    assert engine.apply("wir nutzen Hot Spot täglich") == "wir nutzen HubSpot täglich"


def test_case_insensitive_match_canonical_output(engine: DictionaryEngine) -> None:
    assert engine.apply("hot spot und HOT SPOT und Hot Spot") == "HubSpot und HubSpot und HubSpot"


def test_whitespace_tolerant(engine: DictionaryEngine) -> None:
    assert engine.apply("Hot   Spot") == "HubSpot"


def test_word_boundary_no_partial_match(engine: DictionaryEngine) -> None:
    # "Hot Spotty" darf NICHT ersetzt werden.
    assert engine.apply("Hot Spotty ist kein Treffer") == "Hot Spotty ist kein Treffer"


def test_multiple_distinct_replacements(engine: DictionaryEngine) -> None:
    result = engine.apply("Chat GPT und Sales Force mit Study Plus")
    assert result == "ChatGPT und Salesforce mit StudyPlus"


def test_two_keys_same_target(engine: DictionaryEngine) -> None:
    assert engine.apply("Hot Spot oder Hub Spot") == "HubSpot oder HubSpot"


def test_identity_entry_is_stable(engine: DictionaryEngine) -> None:
    # "Claude Code" -> "Claude Code": stabil, keine Doppelersetzung.
    assert engine.apply("mit Claude Code arbeiten") == "mit Claude Code arbeiten"


def test_no_entries_is_noop() -> None:
    assert DictionaryEngine({}).apply("nichts passiert hier") == "nichts passiert hier"


def test_empty_text(engine: DictionaryEngine) -> None:
    assert engine.apply("") == ""


def test_punctuation_adjacent(engine: DictionaryEngine) -> None:
    assert engine.apply("Nutzt du Hot Spot?") == "Nutzt du HubSpot?"


def test_from_json(tmp_path) -> None:  # type: ignore[no-untyped-def]
    path = tmp_path / "dict.json"
    path.write_text(json.dumps({"Chat GPT": "ChatGPT"}), encoding="utf-8")
    engine = DictionaryEngine.from_json(path)
    assert len(engine) == 1
    assert engine.apply("Chat GPT rockt") == "ChatGPT rockt"


def test_load_or_empty_missing_file(tmp_path) -> None:  # type: ignore[no-untyped-def]
    engine = DictionaryEngine.load_or_empty(tmp_path / "fehlt.json")
    assert len(engine) == 0


def test_longest_match_wins() -> None:
    engine = DictionaryEngine({"Spot": "SPOT", "Hot Spot": "HubSpot"})
    # Der längere Eintrag "Hot Spot" muss Vorrang vor "Spot" haben.
    assert engine.apply("Hot Spot") == "HubSpot"
