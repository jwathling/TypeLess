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
        # Prompt-Prefix-Cache (M8): vorgewärmter KV-Cache des festen Systemprompts, plus die
        # Präfix-Tokens, mit denen er gebaut wurde, und der Modus, für den er gilt. `None`, solange
        # kein Modell/Cache da ist.
        self._cache: Any | None = None
        self._cache_prefix: list[int] = []
        self._cache_mode: Mode | None = None

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
        # Den Diktat-Präfix gleich mit vorwärmen — der heiße Pfad. Diese ~3 s fallen EINMAL pro
        # Modell-Ladung an und verstecken sich im spekulativen Preload, während der Anwender
        # spricht.
        self._prime_cache(Mode.DIKTAT)

    def _prime_cache(self, mode: Mode) -> None:
        """Baut den KV-Cache für den festen Präfix eines Modus. Scheitert das, läuft der Refiner
        ohne Cache weiter (Voll-Prefill) — ein Diktat darf daran nie scheitern."""
        try:
            import mlx.core as mx  # noqa: PLC0415
            from mlx_lm.models import cache as kv  # noqa: PLC0415

            assert self._model is not None and self._tokenizer is not None
            prefix = statischer_praefix(self._tokenizer, get_mode_spec(mode))
            cache = kv.make_prompt_cache(self._model)
            self._model(mx.array(prefix)[None], cache=cache)
            mx.eval([c.state for c in cache])
            self._cache, self._cache_prefix, self._cache_mode = cache, prefix, mode
        except Exception:  # noqa: BLE001 - bewusst breit: Rückfall statt Absturz
            _log.warning("Prompt-Cache konnte nicht vorgewärmt werden — laufe ohne.")
            self._cache, self._cache_prefix, self._cache_mode = None, [], None

    def unload(self) -> None:
        if self._model is None:
            return
        import gc  # noqa: PLC0415

        self._model = None
        self._tokenizer = None
        # Der Cache gehört zum Modell — mit weg (Absicherung 2 der Spec).
        self._cache = None
        self._cache_prefix = []
        self._cache_mode = None
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
        full = self._tokenizer.apply_chat_template(
            spec.build_messages(text), add_generation_prompt=True, tokenize=True
        )
        sampler = mlx_lm.sample_utils.make_sampler(temp=spec.temperature)

        nutze_cache = (
            self._cache is not None
            and self._cache_mode == mode
            and beginnt_mit(full, self._cache_prefix)
        )
        if nutze_cache:
            try:
                # Nur den Diktattext gegen den vorgewärmten Präfix-Cache generieren, danach den
                # Cache wieder auf den Präfix zurückstutzen — bereit fürs nächste Diktat.
                suffix = list(full[len(self._cache_prefix) :])
                output = self._generate(suffix, spec, sampler, cache=self._cache)
                self._reset_cache()
                return str(output).strip()
            except Exception:  # noqa: BLE001 - Cache-Pfad gescheitert, Diktat trotzdem retten
                # Der Cache ist nach einem Fehler mitten in der Generierung in unbekanntem Zustand.
                # Verwerfen, damit ihn das nächste Diktat NICHT wiederverwendet, und unten voll
                # prefillen — nie ein Diktat verlieren.
                _log.warning(
                    "Cache-Pfad fehlgeschlagen — verwerfe Cache, falle auf Voll-Prefill zurück."
                )
                self._cache, self._cache_prefix, self._cache_mode = None, [], None
        # Kein passender Cache (oder Cache-Pfad gescheitert): voller Prefill wie bisher.
        output = self._generate(list(full), spec, sampler, cache=None)
        return str(output).strip()

    def _generate(
        self, prompt_tokens: list[int], spec: Any, sampler: Any, cache: Any | None
    ) -> Any:
        import mlx.core as mx  # noqa: PLC0415

        mlx_lm = self._import_backend()
        kwargs: dict[str, Any] = {"prompt_cache": cache} if cache is not None else {}
        return mlx_lm.generate(
            self._model,
            self._tokenizer,
            prompt=mx.array(prompt_tokens),
            max_tokens=spec.max_tokens,
            sampler=sampler,
            verbose=False,
            **kwargs,
        )

    def _reset_cache(self) -> None:
        """Stutzt den Cache nach einem Diktat wieder auf den festen Präfix zurück — bereit fürs
        nächste. Sicher, weil die Verarbeitung serialisiert ist (Lock in runtime.py).

        Kommt der Cache dabei NICHT exakt auf die Präfixlänge zurück, verwerfen wir ihn: Ein
        nicht-trimmbarer Cache-Typ (z. B. Rotating-Cache eines künftigen Backends) würde sonst
        Alt-Suffix behalten, und das nächste Diktat generierte gegen einen verunreinigten Cache —
        ein Bruch der unverhandelbaren Qualitätsneutralität. Lieber laut auf den Voll-Prefill
        zurückfallen (Cache = None) als still falsch."""
        from mlx_lm.models import cache as kv  # noqa: PLC0415

        assert self._cache is not None
        kv.trim_prompt_cache(self._cache, self._cache[0].offset - len(self._cache_prefix))
        if self._cache[0].offset != len(self._cache_prefix):
            _log.warning("Cache ließ sich nicht sauber zurückstutzen — verwerfe ihn.")
            self._cache, self._cache_prefix, self._cache_mode = None, [], None
