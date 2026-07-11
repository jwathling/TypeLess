"""Tests der Modus-Registry und des Nachrichtenbaus."""

from __future__ import annotations

from typeless_engine.models import Mode
from typeless_engine.modes import MODES, get_mode_spec


def test_all_modes_registered() -> None:
    assert set(MODES.keys()) == set(Mode)


def test_build_messages_structure() -> None:
    spec = get_mode_spec(Mode.DIKTAT)
    messages = spec.build_messages("hallo welt")
    assert [m["role"] for m in messages] == ["system", "user"]
    assert messages[1]["content"] == "hallo welt"
    # Leitplanke ist im System-Prompt enthalten.
    assert "übersetze niemals" in messages[0]["content"]


def test_diktat_is_strict_length() -> None:
    assert get_mode_spec(Mode.DIKTAT).strict_length is True


def test_transformative_modes_not_strict() -> None:
    for mode in (Mode.PROMPT, Mode.EMAIL, Mode.SLACK, Mode.BRAINDUMP):
        assert get_mode_spec(mode).strict_length is False


def test_temperatures_are_low() -> None:
    for spec in MODES.values():
        assert 0.0 <= spec.temperature <= 0.5


def test_mode_from_string() -> None:
    assert Mode.from_string("Diktat") == Mode.DIKTAT
    assert Mode.from_string(" braindump ") == Mode.BRAINDUMP


def test_mode_from_string_invalid() -> None:
    import pytest

    with pytest.raises(ValueError, match="Unbekannter Modus"):
        Mode.from_string("quatsch")
