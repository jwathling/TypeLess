"""Entscheidungs- und Lebenszyklus-Logik des Prompt-Caches — ohne echtes MLX.

Eine Test-Unterklasse ersetzt die drei MLX-berührenden Methoden durch Attrappen und zeichnet auf,
WELCHE Tokens an ``generate`` gehen und OB ein Cache mitgegeben wurde. Die rohe MLX-Korrektheit
(bitidentische Ausgabe) prüft ``test_llm_cache_ondevice.py`` on-device.
"""

from __future__ import annotations

from typing import Any

from typeless_engine.llm.mlx_refiner import MLXRefiner
from typeless_engine.models import Mode


class FakeTokenizer:
    SYS = [1001, 1002, 1003, 1004]

    def apply_chat_template(
        self, messages: list[dict[str, str]], *, add_generation_prompt: bool, tokenize: bool
    ) -> list[int]:
        assert tokenize is True
        user = next(m["content"] for m in messages if m["role"] == "user")
        return [*self.SYS, *(ord(c) for c in user), 2001]


class SpyRefiner(MLXRefiner):
    """Ersetzt Modell-Laden und die MLX-Aufrufe durch Attrappen; zeichnet die Aufrufe auf."""

    def __init__(self) -> None:
        super().__init__()
        self.generate_aufrufe: list[dict[str, Any]] = []
        self.reset_aufrufe = 0
        self.prime_darf_scheitern = False

    def preload(self) -> None:
        if self._model is not None:
            return
        self._model = object()  # Platzhalter — echtes Laden wird nicht gebraucht
        self._tokenizer = FakeTokenizer()
        self._prime_cache(Mode.DIKTAT)

    def _prime_cache(self, mode: Mode) -> None:
        # Ohne MLX: die reine Präfix-Logik aus Task 1 nutzen, aber statt eines echten KV-Caches
        # ein Platzhalter-Objekt. Der Rückfall-Zweig (Prime scheitert) ist ebenfalls prüfbar.
        from typeless_engine.llm.mlx_refiner import statischer_praefix
        from typeless_engine.modes import get_mode_spec

        if self.prime_darf_scheitern:
            self._cache, self._cache_prefix, self._cache_mode = None, [], None
            return
        prefix = statischer_praefix(self._tokenizer, get_mode_spec(mode))
        self._cache, self._cache_prefix, self._cache_mode = object(), prefix, mode

    def _generate(
        self, prompt_tokens: list[int], spec: Any, sampler: Any, cache: Any | None
    ) -> Any:
        self.generate_aufrufe.append(
            {"tokens": list(prompt_tokens), "mit_cache": cache is not None}
        )
        return "AUSGABE"

    def _reset_cache(self) -> None:
        self.reset_aufrufe += 1


def test_preload_primt_den_diktat_cache() -> None:
    r = SpyRefiner()
    r.preload()
    assert r._cache is not None
    assert r._cache_prefix == FakeTokenizer.SYS
    assert r._cache_mode == Mode.DIKTAT


def test_diktat_reicht_nur_den_suffix_und_den_cache_ein() -> None:
    r = SpyRefiner()
    out = r.refine("hi", Mode.DIKTAT)
    assert out == "AUSGABE"
    assert len(r.generate_aufrufe) == 1
    ruf = r.generate_aufrufe[0]
    # Nur der Diktattext ("hi" -> [104, 105]) + Generierungs-Anhang, NICHT der 4-Token-Systemblock.
    assert ruf["tokens"] == [ord("h"), ord("i"), 2001]
    assert ruf["mit_cache"] is True
    assert r.reset_aufrufe == 1  # Cache nach dem Lauf zurückgestutzt


def test_ohne_cache_wird_der_volle_prompt_prefillt() -> None:
    # Prime scheitert -> kein Cache -> Rückfall auf den vollen Prompt, kein Cache, kein Reset.
    r = SpyRefiner()
    r.prime_darf_scheitern = True
    r.refine("hi", Mode.DIKTAT)
    ruf = r.generate_aufrufe[0]
    assert ruf["tokens"] == [*FakeTokenizer.SYS, ord("h"), ord("i"), 2001]
    assert ruf["mit_cache"] is False
    assert r.reset_aufrufe == 0


def test_abweichender_praefix_faellt_auf_vollen_prompt_zurueck() -> None:
    # Cache ist vorhanden (preload lief durch), aber der gemerkte Präfix passt nicht zum
    # tatsächlichen Prompt (z. B. weil sich der Modus-Systemprompt seit dem Priming geändert
    # hätte). Der Wächter `beginnt_mit` muss das erkennen und auf den vollen Prefill zurückfallen
    # — sonst würde ein Cache verwendet, der zu einem anderen Präfix gehört.
    r = SpyRefiner()
    r.preload()
    assert r._cache is not None  # Cache ist da ...
    r._cache_prefix = [9, 9, 9, 9]  # ... aber weicht vom tatsächlichen Prompt ab
    r.refine("hi", Mode.DIKTAT)
    ruf = r.generate_aufrufe[0]
    assert ruf["tokens"] == [*FakeTokenizer.SYS, ord("h"), ord("i"), 2001]
    assert ruf["mit_cache"] is False
    assert r.reset_aufrufe == 0


def test_unload_verwirft_den_cache() -> None:
    r = SpyRefiner()
    r.preload()
    assert r._cache is not None
    r.unload()
    assert r._cache is None
    assert r._cache_prefix == []
    assert r._cache_mode is None


def test_leerer_text_bemueht_das_modell_nicht() -> None:
    r = SpyRefiner()
    assert r.refine("   ", Mode.DIKTAT) == "   "
    assert r.generate_aufrufe == []
