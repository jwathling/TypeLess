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


# ---- Divergenz-Check (Inhaltsverlust im Diktat) ----------------------------------------


def test_diktat_dropped_content_fails() -> None:
    """Echter Fall: Qwen2.5-3B verschluckt einen ganzen Satz (Länge bleibt unauffällig)."""
    src = (
        "Das ist ein Test für die Sprache. Hier soll es darum gehen, ein Prompt zu entwerfen. "
        "Dieser Prompt soll eine App entwickeln für eine Squash-Liga in Braunschweig. Das Ganze "
        "soll mit HubSpot verknüpft werden und soll den neuesten und modernsten Standards im "
        "Design entsprechen."
    )
    out = (
        "Das ist ein Test für die Sprache. Hier soll es darum gehen, eine App zu entwickeln für "
        "eine Squash-Liga in Braunschweig. Diese App soll mit HubSpot verknüpft sein und den "
        "neuesten und modernsten Standards im Design entsprechen."
    )

    ok, reason = sanity_check(src, out, Mode.DIKTAT)

    assert not ok, "Verlorener Inhalt muss auffallen (Längen-Check greift hier nicht)"
    assert reason is not None and "fehlt" in reason


def test_diktat_filler_removal_passes() -> None:
    """Echter Fall: Füllwörter entfernen ist erlaubt und darf nicht als Verlust zählen."""
    src = (
        "also ähm wir haben da diese ähm integration mit HubSpot gemacht und die läuft jetzt "
        "eigentlich ganz gut also der sync von den kontakten funktioniert"
    )
    out = (
        "Also, wir haben diese Integration mit HubSpot gemacht und sie läuft jetzt eigentlich "
        "ganz gut. Der Sync von den Kontakten funktioniert."
    )

    ok, reason = sanity_check(src, out, Mode.DIKTAT)

    assert ok, f"Guter Diktat-Refine fälschlich verworfen: {reason}"


def test_diktat_spelling_fix_is_not_content_loss() -> None:
    """Rechtschreibkorrektur ist der Zweck des Modus — das Wort gilt als erhalten."""
    src = "wir müssen die integration noch entwikeln und dokumentiren"
    out = "Wir müssen die Integration noch entwickeln und dokumentieren."

    ok, reason = sanity_check(src, out, Mode.DIKTAT)

    assert ok, f"Tippfehler-Korrektur fälschlich als Verlust gewertet: {reason}"


def test_divergence_not_applied_to_transformative_modes() -> None:
    """E-Mail/BrainDump dürfen umformulieren und weglassen."""
    src = "termin montag zehn uhr kurz über das budget sprechen bitte vorbereiten"
    out = "Hallo,\n\nwollen wir am Montag um 10 Uhr sprechen?\n\nViele Grüße"

    ok, _ = sanity_check(src, out, Mode.EMAIL)

    assert ok


def test_divergence_threshold_configurable() -> None:
    src = "wir besprechen das budget und den zeitplan im meeting"
    out = "Wir besprechen das Budget im Meeting."  # "zeitplan" fehlt

    strict = SanityConfig(diktat_max_missing_ratio=0.0)
    lax = SanityConfig(diktat_max_missing_ratio=0.9)

    assert not sanity_check(src, out, Mode.DIKTAT, strict)[0]
    assert sanity_check(src, out, Mode.DIKTAT, lax)[0]
