# M8 (vorgezogen) — Prompt-Prefix-Cache: Implementierungsplan

> **Für agentische Bearbeiter:** ERFORDERLICHE SUB-SKILL: `superpowers:subagent-driven-development`
> (empfohlen) oder `superpowers:executing-plans`. Schritte nutzen Checkbox-Syntax (`- [ ]`).

**Ziel:** Die LLM-Latenz um ~2,5 s pro Diktat senken, indem der feste Systemprompt einmal beim
Preload gecacht und pro Diktat nur der kurze Diktattext nachgeladen wird — mathematisch
qualitätsneutral.

**Architektur:** Ein Prompt-Prefix-KV-Cache **ausschließlich** in `MLXRefiner`
(`engine/typeless_engine/llm/mlx_refiner.py`). Die Schnittstelle `interfaces/refiner.py` und
`factory.py` bleiben unverändert. Die MLX-berührenden Aufrufe liegen hinter drei dünnen,
überschreibbaren Methoden (`_prime_cache`, `_generate`, `_reset_cache`), damit die Entscheidungs-
und Rückfall-Logik **ohne MLX** testbar bleibt; die rohe MLX-Korrektheit wird on-device belegt.

**Tech-Stack:** Python 3.11+, `mlx_lm` (lazy, Apple-Silicon-only), pytest, Swift nicht betroffen.

**Spec:** `docs/superpowers/specs/2026-07-15-m8-prompt-cache-design.md` — bei Zweifeln gilt die Spec.

## Global Constraints

- Python 3.11+, `from __future__ import annotations`, Typannotationen überall.
- **MLX-Imports immer lazy** (nur innerhalb von Methoden), damit der Kern plattformunabhängig
  importierbar bleibt. `mlx_refiner.py` importiert auf Modulebene **kein** `mlx_lm`/`mlx.core`.
- Kommentare/Docstrings auf **Deutsch**, bestehendem Stil folgend.
- **Die Schnittstelle `Refiner` (`preload`/`unload`/`refine(text, mode, *, language)`) ändert sich
  nicht.** Keine neue öffentliche Methode, kein geänderter Rückgabetyp.
- **Qualitätsneutral, nicht verhandelbar:** Die Ausgabe mit Cache muss **identisch** zur Ausgabe
  ohne Cache sein. Der Cache verschiebt nur, *wo* das Prefill passiert, nie *was* erzeugt wird.
- **Ein Diktat darf nie verloren gehen:** Scheitert der Cache-Aufbau oder schlägt der Präfix-
  Wächter an, fällt der Code auf den heutigen Voll-Prefill zurück (ganzer Prompt, kein Cache).
- **Cache am Modell-Lebenszyklus:** `unload()` verwirft den Cache, `preload()` baut ihn neu.
- Vor jedem Commit `bash scripts/check.sh` grün (black + ruff + mypy strict + pytest).

**Gemessene Grundlagen (Apple M4, bereits verifiziert — nicht erneut zu erraten):**
- Fester Diktat-Präfix = **424 Tokens**; Cachen spart **2,99 s → 0,42 s = 2,57 s** pro Diktat.
- Token-ID-Suffix gegen den vorgewärmten Cache erzeugt **bitidentische** Ausgabe zum Voll-Prefill
  (mit `temp=0.0` bewiesen).
- `mlx_lm.generate(model, tok, prompt=mx.array(ids), …, prompt_cache=cache)` — `prompt_cache` läuft
  über `**kwargs`. Priming: `model(mx.array(prefix)[None], cache=cache); mx.eval([c.state for c in
  cache])`. Rückstutzen: `trim_prompt_cache(cache, cache[0].offset - len(prefix))`. Cache-Bau:
  `from mlx_lm.models import cache as kv; kv.make_prompt_cache(model)`.

---

## Dateistruktur

| Datei | Verantwortung |
|---|---|
| `engine/typeless_engine/llm/mlx_refiner.py` (ändern) | Prefix-Ermittlung + Wächter (reine Funktionen), Cache-Lebenszyklus in `MLXRefiner`, Rückfall auf Voll-Prefill. |
| `engine/tests/test_llm_prefix.py` (neu) | Reine Logik: Präfix-Ermittlung + Wächter (gefälschter Tokenizer, kein MLX). |
| `engine/tests/test_llm_cache_policy.py` (neu) | Entscheidungs-/Lebenszyklus-Logik von `MLXRefiner` über eine Test-Unterklasse (kein MLX). |
| `engine/tests/test_llm_cache_ondevice.py` (neu) | On-device (`--extra mlx`, opt-in): Ausgabe mit Cache == ohne Cache über **zwei** Diktate; überspringt sich ohne MLX. |

---

## Task 1: Präfix-Ermittlung + Wächter (reine Logik, überall testbar)

Zwei modulweite Funktionen in `mlx_refiner.py`, die **kein** MLX brauchen. Die Präfix-Ermittlung
nutzt den „längsten gemeinsamen Präfix zweier verschiedener Diktattexte" — robust gegen Tokenizer-
Eigenheiten, weil sie mit echten Tokenisierungen arbeitet, nicht mit String-Zerschneiden.

**Files:**
- Modify: `engine/typeless_engine/llm/mlx_refiner.py`
- Test: `engine/tests/test_llm_prefix.py`

**Interfaces:**
- Consumes: `get_mode_spec(mode)` (bestehend, liefert `spec` mit `build_messages(text) -> list[dict]`).
- Produces:
  - `statischer_praefix(tokenizer: Any, spec: Any) -> list[int]`
  - `beginnt_mit(voll: list[int], praefix: list[int]) -> bool`

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

Neue Datei `engine/tests/test_llm_prefix.py`:

```python
"""Reine Logik der Prompt-Cache-Absicherung — ohne MLX, mit gefälschtem Tokenizer."""

from __future__ import annotations

from typing import Any

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
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_llm_prefix.py -q`
Erwartung: FAIL — `ImportError: cannot import name 'beginnt_mit'`.

- [ ] **Schritt 3: Umsetzung**

In `engine/typeless_engine/llm/mlx_refiner.py`, nach den Imports und vor der Klasse, einfügen:

```python
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
```

Sicherstellen, dass `from typing import Any` bereits importiert ist (ist es, Zeile 16).

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_llm_prefix.py -q`
Erwartung: PASS, 4 Tests.

- [ ] **Schritt 5: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/llm/mlx_refiner.py tests/test_llm_prefix.py
git commit -m "M8: Präfix-Ermittlung + Wächter für den Prompt-Cache (reine Logik)"
```

---

## Task 2: Cache-Lebenszyklus in MLXRefiner + Rückfall (ohne MLX testbar)

Der Kern. Die MLX-berührenden Aufrufe (`_prime_cache`, `_generate`, `_reset_cache`) sind dünne,
überschreibbare Methoden — so lässt sich die **Entscheidung** (Suffix-Wiederverwendung vs. Voll-
Prefill) und der **Lebenszyklus** (unload verwirft den Cache) mit einem gefälschten Backend prüfen,
ohne echtes MLX.

**Files:**
- Modify: `engine/typeless_engine/llm/mlx_refiner.py`
- Test: `engine/tests/test_llm_cache_policy.py`

**Interfaces:**
- Consumes: `statischer_praefix`, `beginnt_mit` (Task 1); `get_mode_spec` (bestehend);
  `Mode.DIKTAT` (bestehend).
- Produces (private, aber von der Test-Unterklasse überschrieben): `_prime_cache(mode) -> None`,
  `_generate(prompt_tokens: list[int], spec: Any, sampler: Any, cache: Any | None) -> Any`,
  `_reset_cache() -> None`. Neue Felder: `_cache`, `_cache_prefix: list[int]`, `_cache_mode`.

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

Neue Datei `engine/tests/test_llm_cache_policy.py`:

```python
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

    def _generate(self, prompt_tokens: list[int], spec: Any, sampler: Any, cache: Any | None) -> Any:
        self.generate_aufrufe.append({"tokens": list(prompt_tokens), "mit_cache": cache is not None})
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
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_llm_cache_policy.py -q`
Erwartung: FAIL — `AttributeError`/`TypeError` (Felder und Methoden gibt es noch nicht;
`refine` kennt den Cache-Pfad nicht).

- [ ] **Schritt 3: Umsetzung**

`MLXRefiner` in `engine/typeless_engine/llm/mlx_refiner.py` umbauen. `__init__`, `preload`,
`unload`, `refine` ersetzen und die drei Seam-Methoden ergänzen:

```python
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

    def preload(self) -> None:
        if self._model is not None:
            return
        mlx_lm = self._import_backend()
        _log.info("Lade LLM %s ...", self._model_id)
        self._model, self._tokenizer = mlx_lm.load(self._model_id)
        _log.info("LLM geladen.")
        # Den Diktat-Präfix gleich mit vorwärmen — der heiße Pfad. Diese ~3 s fallen EINMAL pro
        # Modell-Ladung an und verstecken sich im spekulativen Preload, während der Anwender spricht.
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

        if (
            self._cache is not None
            and self._cache_mode == mode
            and beginnt_mit(full, self._cache_prefix)
        ):
            # Nur den Diktattext gegen den vorgewärmten Präfix-Cache generieren (Absicherung 1: der
            # Wächter oben stellt sicher, dass der Cache wirklich passt), danach zurückstutzen.
            suffix = list(full[len(self._cache_prefix) :])
            output = self._generate(suffix, spec, sampler, cache=self._cache)
            self._reset_cache()
        else:
            # Kein passender Cache: voller Prefill wie bisher.
            output = self._generate(list(full), spec, sampler, cache=None)
        return str(output).strip()

    def _generate(self, prompt_tokens: list[int], spec: Any, sampler: Any, cache: Any | None) -> Any:
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
        nächste. Sicher, weil die Verarbeitung serialisiert ist (Lock in runtime.py)."""
        from mlx_lm.models import cache as kv  # noqa: PLC0415

        assert self._cache is not None
        kv.trim_prompt_cache(self._cache, self._cache[0].offset - len(self._cache_prefix))
```

Sicherstellen, dass `Mode` importiert ist (ist es, Zeile 20: `from ..models import Mode`).

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_llm_cache_policy.py -q`
Erwartung: PASS, 5 Tests.

- [ ] **Schritt 5: Mutationsprobe (der Rückfall-Wächter)**

Der Präfix-Wächter ist die Sicherheitsregel. Beweisen, dass der Test ihn bewacht:
In `refine` `beginnt_mit(full, self._cache_prefix)` vorübergehend durch `True` ersetzen und
`test_ohne_cache_wird_der_volle_prompt_prefillt` **allein** laufen lassen — er muss **rot** werden
(der Test setzt `prime_darf_scheitern`, aber prüfe zusätzlich mit einer Attrappe, deren Tokenizer
im Präfix abweicht). Falls die vorhandenen Tests die Mutation nicht fangen, einen Test ergänzen,
der einen **abweichenden** Präfix erzeugt (z. B. `SpyRefiner` mit `_cache_prefix = [9, 9, 9, 9]`
nach `preload`) und prüft, dass dann der volle Prompt ohne Cache generiert wird. Danach die
Mutation zurücknehmen, grün bestätigen. Laufzeit und Ausgang festhalten.

- [ ] **Schritt 6: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/llm/mlx_refiner.py tests/test_llm_cache_policy.py
git commit -m "M8: Prompt-Cache-Lebenszyklus in MLXRefiner mit Rückfall auf Voll-Prefill"
```

---

## Task 3: On-device-Beleg — identische Ausgabe + Ersparnis

Die entscheidende Zusicherung der Spec, die nur echtes MLX beweisen kann: Ausgabe **mit** Cache ==
Ausgabe **ohne** Cache, und zwar über **zwei** aufeinanderfolgende Diktate (das beweist, dass das
Zurückstutzen den Cache sauber zurücksetzt). Der Test überspringt sich, wenn MLX fehlt oder das
On-device-Opt-in nicht gesetzt ist — die normale Suite lädt so nie ein 4B-Modell.

**Files:**
- Test: `engine/tests/test_llm_cache_ondevice.py`

**Interfaces:**
- Consumes: `MLXRefiner`, `Mode.DIKTAT`.

- [ ] **Schritt 1: Test schreiben**

Neue Datei `engine/tests/test_llm_cache_ondevice.py`:

```python
"""On-device-Beleg (Apple Silicon, echtes 4B-Modell). Überspringt sich ohne MLX oder ohne Opt-in.

Ausführen mit:  TYPELESS_ONDEVICE=1 uv run --extra mlx pytest tests/test_llm_cache_ondevice.py -s
"""

from __future__ import annotations

import os
import time

import pytest

from typeless_engine.llm.mlx_refiner import MLXRefiner
from typeless_engine.models import Mode


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
    "also ich wollte äh sagen dass wir das meeting verschieben müssen weil der kunde noch nicht geantwortet hat",
    "kannst du bitte den bericht bis freitag fertig machen ich meine bis donnerstag",
]


def _ohne_cache(refiner: MLXRefiner, text: str) -> str:
    # Cache abschalten, damit refine den Voll-Prefill nimmt (Referenz-Ausgabe).
    refiner._cache = None
    return refiner.refine(text, Mode.DIKTAT)


def test_ausgabe_mit_cache_ist_identisch_zu_ohne_cache_ueber_zwei_diktate() -> None:
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

    print(f"\nVoll-Prefill: {t_voll:.2f}s   mit Cache: {t_cache:.2f}s   gespart: {t_voll - t_cache:.2f}s")
    assert t_cache < t_voll  # der Cache muss messbar schneller sein
```

- [ ] **Schritt 2: Prüfen, dass sich der Test ohne Opt-in überspringt**

Run: `cd engine && uv run pytest tests/test_llm_cache_ondevice.py -q`
Erwartung: `2 skipped` (kein Opt-in) — die normale Suite lädt kein Modell.

- [ ] **Schritt 3: On-device wirklich ausführen (Apple Silicon)**

Run: `cd engine && TYPELESS_ONDEVICE=1 uv run --extra mlx pytest tests/test_llm_cache_ondevice.py -q -s`
Erwartung: `2 passed`, und die ausgegebene Ersparnis liegt in der Größenordnung ~2–2,5 s.
**Dieses Ergebnis (identisch + Ersparnis) im Bericht festhalten** — es ist der eigentliche Beleg.

- [ ] **Schritt 4: Volle Suite + Commit**

```bash
cd engine && bash ../scripts/check.sh   # normale Suite: On-device-Test übersprungen
git add tests/test_llm_cache_ondevice.py
git commit -m "M8: On-device-Beleg — Cache-Ausgabe identisch zum Voll-Prefill, messbar schneller"
```

---

## Handprobe (durch den Anwender, nach Task 3)

Neu bauen ist **nicht** nötig — M8 fasst nur die Engine an, nicht die Swift-App. Läuft der Sidecar
schon, reicht ein Neustart der Engine (Menü → „Engine neu starten") bzw. der App.

Diktier ein paar Mal normal. Erwartung: Der Text ist **spürbar schneller** da als vorher (~2 s pro
Diktat weniger), und die **Qualität** ist unverändert — dieselben Korrekturen, dieselben
Selbstkorrekturen wie zuvor. Fällt dir irgendein inhaltlicher Unterschied auf, ist das ein Fehler
(der Cache muss bitidentisch sein) — dann melden.
