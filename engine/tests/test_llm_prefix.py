"""Reine Logik der Prompt-Cache-Absicherung — ohne MLX, mit gefälschtem Tokenizer."""

from __future__ import annotations

from typeless_engine.llm.mlx_refiner import beginnt_mit, statischer_praefix
from typeless_engine.models import Mode
from typeless_engine.modes import get_mode_spec


class FakeTokenizer:
    """Tokenisiert deterministisch: fester System-Block + Zeichencodes des Diktattextes.

    Bildet die reale Eigenschaft nach, dass der System-Teil einen festen Token-Präfix bildet und
    nur der Diktattext variiert.
    """

    SYS = [1001, 1002, 1003, 1004]  # fester Block, steht für den langen Systemprompt

    def apply_chat_template(
        self, messages: list[dict[str, str]], *, add_generation_prompt: bool, tokenize: bool
    ) -> list[int]:
        assert tokenize is True
        user = next(m["content"] for m in messages if m["role"] == "user")
        return [*self.SYS, *(ord(c) for c in user), 2001]  # 2001 = fester Generierungs-Anhang


def test_statischer_praefix_ist_der_gemeinsame_kopf() -> None:
    praefix = statischer_praefix(FakeTokenizer(), get_mode_spec(Mode.DIKTAT))
    # Nur der feste System-Block, KEIN Diktattext, KEIN Generierungs-Anhang (der kommt erst nach
    # dem variablen Text).
    assert praefix == FakeTokenizer.SYS


def test_beginnt_mit_erkennt_den_praefix() -> None:
    assert beginnt_mit([1, 2, 3, 4, 5], [1, 2, 3]) is True


def test_beginnt_mit_erkennt_abweichung() -> None:
    # Weicht der volle Prompt schon im Präfix ab (Tokenizer-Überraschung), MUSS der Wächter das
    # melden — sonst würde gegen einen falschen Cache generiert.
    assert beginnt_mit([1, 2, 9, 4, 5], [1, 2, 3]) is False


def test_beginnt_mit_bei_zu_kurzem_vollprompt() -> None:
    assert beginnt_mit([1, 2], [1, 2, 3]) is False
