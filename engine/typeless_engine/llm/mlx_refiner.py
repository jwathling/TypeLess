"""MLX-LM-Refiner (Apple Silicon / Metal).

Default-LLM: ``Qwen3-4B-Instruct-2507-4bit``. Der ursprünglich geplante Default
``Qwen2.5-3B-Instruct-4bit`` ist zu schwach für den Diktat-Vertrag: Er löscht
reproduzierbar ganze Sätze und formuliert um, obwohl der System-Prompt beides verbietet —
auch mit deutlich verschärftem Prompt. 4B hält den Vertrag wortgetreu. 3B bleibt über die
Konfiguration wählbar (schneller, aber inhaltlich unzuverlässig).

Modell-Lifecycle für das RAM-Budget (16 GB): ``preload`` lädt das Modell (spekulativ beim
Hotkey-Druck), ``unload`` gibt es wieder frei (Idle-Unload / Memory-Pressure). ``mlx_lm``
wird lazy importiert.
"""

from __future__ import annotations

from typing import Any

from ..interfaces import Refiner
from ..logging_ import get_logger
from ..models import Mode
from ..modes import get_mode_spec

_log = get_logger(__name__)

DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"


def statischer_praefix(tokenizer: Any, spec: Any) -> list[int]:
    """Die feste Token-Folge eines Modus — Systemprompt samt Vorlage bis zum Diktattext.

    Ermittelt über den LÄNGSTEN GEMEINSAMEN PRÄFIX zweier verschieden diktierter Texte: Alles vor
    der ersten Abweichung ist der statische Teil. Das ist robust gegen Tokenizer-Eigenheiten
    (Zusammenlegen von Zeichen über Grenzen hinweg), weil es mit echten Tokenisierungen arbeitet
    und nicht mit dem Zerschneiden von Strings.
    """
    a = tokenizer.apply_chat_template(
        spec.build_messages("Apfel"), add_generation_prompt=True, tokenize=True
    )
    b = tokenizer.apply_chat_template(
        spec.build_messages("Zebra"), add_generation_prompt=True, tokenize=True
    )
    n = 0
    while n < len(a) and n < len(b) and a[n] == b[n]:
        n += 1
    return list(a[:n])


def beginnt_mit(voll: list[int], praefix: list[int]) -> bool:
    """Prüft, ob ``voll`` mit ``praefix`` beginnt — der Präfix-Wächter vor jeder Cache-Nutzung."""
    return len(voll) >= len(praefix) and list(voll[: len(praefix)]) == list(praefix)


class MLXRefiner(Refiner):
    """Refiner auf Basis von ``mlx_lm`` (Metal, Apple Silicon)."""

    def __init__(self, model: str = DEFAULT_MODEL) -> None:
        self._model_id = model
        self._model: Any | None = None
        self._tokenizer: Any | None = None

    def _import_backend(self) -> Any:
        try:
            import mlx_lm  # noqa: PLC0415  (lazy: Apple-Silicon-only)
        except ImportError as exc:
            raise RuntimeError(
                "mlx_lm ist nicht verfügbar. Es läuft nur auf Apple Silicon "
                "(Installation: `uv sync --extra mlx`)."
            ) from exc
        return mlx_lm

    def preload(self) -> None:
        if self._model is not None:
            return
        mlx_lm = self._import_backend()
        _log.info("Lade LLM %s ...", self._model_id)
        self._model, self._tokenizer = mlx_lm.load(self._model_id)
        _log.info("LLM geladen.")

    def unload(self) -> None:
        if self._model is None:
            return
        import gc  # noqa: PLC0415

        self._model = None
        self._tokenizer = None
        gc.collect()
        try:
            import mlx.core as mx  # noqa: PLC0415

            mx.clear_cache()
        except Exception:  # pragma: no cover - best effort
            pass
        _log.info("LLM entladen.")

    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        if not text.strip():
            return text
        self.preload()
        assert self._model is not None and self._tokenizer is not None
        mlx_lm = self._import_backend()

        spec = get_mode_spec(mode)
        messages = spec.build_messages(text)
        prompt = self._tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        sampler = mlx_lm.sample_utils.make_sampler(temp=spec.temperature)
        output = mlx_lm.generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=spec.max_tokens,
            sampler=sampler,
            verbose=False,
        )
        return str(output).strip()
