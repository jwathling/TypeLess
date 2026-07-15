"""On-device-Beleg (Apple Silicon, echtes 4B-Modell). Überspringt sich ohne MLX oder ohne Opt-in.

Ausführen mit:  TYPELESS_ONDEVICE=1 uv run --extra mlx pytest tests/test_llm_cache_ondevice.py -s

Der Identitätsbeweis (mit Cache == ohne Cache) läuft GREEDY (temperature 0), nicht mit der
Diktat-Produktionstemperatur (0.1): Bei temperature 0.1 zieht refine() stochastisch, sodass zwei
Läufe desselben Textes auch OHNE Cache divergieren — das wurde nachgemessen. Greedy hat kein
Sampling-Zufallselement; identische Logits (die Cache-Neutralität) ergeben dann zwingend
bit-identische Tokens. Die Produktion zieht aus genau diesen identischen Logits, der Beweis gilt
also unverändert für den echten Cache-Mechanismus.
"""

from __future__ import annotations

import os
import time

import pytest

from typeless_engine.llm.mlx_refiner import MLXRefiner
from typeless_engine.models import Mode
from typeless_engine.modes import get_mode_spec
from typeless_engine.modes.registry import ModeSpec


def _mlx_verfuegbar() -> bool:
    try:
        import mlx_lm  # noqa: F401, PLC0415

        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    os.environ.get("TYPELESS_ONDEVICE") != "1" or not _mlx_verfuegbar(),
    reason="On-device-Test: nur mit TYPELESS_ONDEVICE=1 und installiertem MLX (Apple Silicon).",
)

DIKTATE = [
    "also ich wollte äh sagen dass wir das meeting verschieben müssen weil der kunde noch nicht geantwortet hat",  # noqa: E501
    "kannst du bitte den bericht bis freitag fertig machen ich meine bis donnerstag",
]


def _ohne_cache(refiner: MLXRefiner, text: str) -> str:
    # Cache abschalten, damit refine den Voll-Prefill nimmt (Referenz-Ausgabe).
    refiner._cache = None
    return refiner.refine(text, Mode.DIKTAT)


def test_ausgabe_mit_cache_ist_identisch_zu_ohne_cache_ueber_zwei_diktate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Greedy dekodieren (temperature 0): so hängt jeder Ausgabe-Unterschied AUSSCHLIESSLICH am
    # KV-Cache und nicht am Zufall des temperature-Samplings. Bei temperature 0.1 (Produktions-
    # Default für Diktat) zieht refine() stochastisch — zwei Läufe desselben Textes divergieren
    # dann auch OHNE Cache. Der Cache ist mathematisch neutral (identische Logits), was sich bei
    # greedy als bit-identische Tokens zeigt; die Produktion zieht aus genau diesen Logits.
    import dataclasses

    from typeless_engine.llm import mlx_refiner as m

    diktat_greedy = dataclasses.replace(get_mode_spec(Mode.DIKTAT), temperature=0.0)

    def _greedy_spec(mode: Mode) -> ModeSpec:
        return diktat_greedy if mode == Mode.DIKTAT else get_mode_spec(mode)

    monkeypatch.setattr(m, "get_mode_spec", _greedy_spec)

    referenz = MLXRefiner()
    referenz.preload()
    erwartet = [_ohne_cache(referenz, t) for t in DIKTATE]

    gecacht = MLXRefiner()
    gecacht.preload()  # wärmt den Diktat-Präfix vor
    assert gecacht._cache is not None, "Preload hätte den Cache vorwärmen müssen"

    for text, soll in zip(DIKTATE, erwartet, strict=True):
        assert gecacht.refine(text, Mode.DIKTAT) == soll
    # Nach zwei Diktaten muss der Cache wieder genau auf dem Präfix stehen (sauber zurückgestutzt).
    assert gecacht._cache[0].offset == len(gecacht._cache_prefix)


def test_cache_ist_schneller_pro_diktat() -> None:
    r = MLXRefiner()
    r.preload()
    text = DIKTATE[0]

    r._cache = None
    t0 = time.perf_counter()
    _ohne_cache(r, text)
    t_voll = time.perf_counter() - t0

    r2 = MLXRefiner()
    r2.preload()
    r2.refine(text, Mode.DIKTAT)  # aufwärmen
    t0 = time.perf_counter()
    r2.refine(text, Mode.DIKTAT)
    t_cache = time.perf_counter() - t0

    print(
        f"\nVoll-Prefill: {t_voll:.2f}s   mit Cache: {t_cache:.2f}s   gespart: {t_voll - t_cache:.2f}s"  # noqa: E501
    )
    assert t_cache < t_voll  # der Cache muss messbar schneller sein
