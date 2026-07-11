"""Tests des Sanity-Checks."""

from __future__ import annotations

from typeless_engine.models import Mode
from typeless_engine.pipeline import SanityConfig, sanity_check


def test_empty_output_fails() -> None:
    ok, reason = sanity_check("etwas text", "", Mode.DIKTAT)
    assert not ok
    assert reason is not None and "leer" in reason


def test_empty_input_passes() -> None:
    ok, _ = sanity_check("", "irgendwas", Mode.DIKTAT)
    assert ok


def test_diktat_reasonable_correction_passes() -> None:
    src = "das ist ein test ohne satzzeichen"
    out = "Das ist ein Test ohne Satzzeichen."
    ok, _ = sanity_check(src, out, Mode.DIKTAT)
    assert ok


def test_diktat_too_long_fails() -> None:
    # ~3x: über der Diktat-Grenze (2x), aber unter der absoluten Grenze (10x).
    src = "kurzer text"
    out = "kurzer text " * 3
    ok, reason = sanity_check(src, out, Mode.DIKTAT)
    assert not ok
    assert reason is not None and "zu lang" in reason


def test_diktat_too_short_fails() -> None:
    src = "das ist ein etwas laengerer diktierter satz"
    out = "kurz"
    ok, reason = sanity_check(src, out, Mode.DIKTAT)
    assert not ok
    assert reason is not None and "zu kurz" in reason


def test_braindump_expansion_allowed() -> None:
    # Transformierende Modi dürfen wachsen (bis zur absoluten Grenze).
    src = "meeting notizen und todos"
    out = "# Meeting\n\n" + "Punkt. " * 20
    ok, _ = sanity_check(src, out, Mode.BRAINDUMP)
    assert ok


def test_absolute_max_ratio_fails_any_mode() -> None:
    src = "kurz"
    out = "x" * 1000
    ok, reason = sanity_check(src, out, Mode.BRAINDUMP, SanityConfig(absolute_max_ratio=10.0))
    assert not ok
    assert reason is not None and "länger" in reason
