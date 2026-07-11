# M2 — Sidecar-Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Engine aus M1 als dauerhaft laufenden lokalen Prozess bereitstellen, den die spätere SwiftUI-App über einen Unix-Domain-Socket anspricht, ohne die Modelle bei jedem Diktat neu zu laden.

**Architecture:** Dünne FastAPI-Schicht (`app.py`, zustandslos) über einer `EngineRuntime` (`runtime.py`), die Modelle, Lock und Idle-Timer besitzt und kein HTTP kennt. Die Runtime baut ihre Bausteine über die bestehende `factory.py` und hängt damit weiterhin nur an den Interfaces `Transcriber`/`Refiner`. Alle blockierenden MLX-Aufrufe laufen in einem Worker-Thread, damit `/health` und `/unload` auch während einer ~6-Sekunden-Verarbeitung sofort antworten.

**Tech Stack:** Python 3.11, FastAPI, uvicorn (Unix-Domain-Socket), anyio, httpx (Tests), pytest.

**Spec:** `docs/superpowers/specs/2026-07-11-m2-sidecar-server-design.md`

## Global Constraints

- Python 3.11 (via `engine/.python-version` gepinnt), `from __future__ import annotations` in jeder Datei.
- Typannotationen überall; mypy **strict** muss grün bleiben.
- ruff + black, line-length **100**.
- Kommentare und Docstrings auf **Deutsch**, im Stil der bestehenden Dateien.
- MLX-Imports bleiben **lazy** — der Server-Code darf `mlx_whisper`/`mlx_lm` niemals direkt importieren, nur über die Factory.
- Der Kern hängt ausschließlich an `interfaces/transcriber.py` und `interfaces/refiner.py`. Die einzige Stelle, die konkrete Engines kennt, bleibt `factory.py`. Diesen Vertrag nicht aufweichen.
- **Alle Tests laufen ohne echte Modelle** (Mock-Backends, injizierte Uhr). Kein Test lädt MLX.
- Nach jeder Task muss `bash scripts/check.sh` grün sein (black + ruff + mypy strict + pytest).
- Audioformat im gesamten Server: Float32, 16 kHz, mono. `TARGET_SAMPLE_RATE` aus `models.py` ist die einzige Quelle dieser Zahl.

## File Structure

| Datei | Verantwortung |
|---|---|
| `engine/typeless_engine/server/__init__.py` | Exporte (`EngineRuntime`, `create_app`) |
| `engine/typeless_engine/server/runtime.py` | `EngineRuntime`: Modelle, Lock, Idle-Timer, Fehler-Resilienz. Kein HTTP. |
| `engine/typeless_engine/server/app.py` | FastAPI: HTTP → Runtime. Validierung, Thread-Auslagerung. Zustandslos. |
| `engine/typeless_engine/server/__main__.py` | Start: Socket anlegen/aufräumen, uvicorn auf UDS. |
| `engine/typeless_engine/config.py` | **ändern**: `socket_path`, `idle_unload_seconds` |
| `engine/pyproject.toml` | **ändern**: `server`-Extra vervollständigen, Test-Deps ins `dev`-Extra |
| `engine/tests/test_runtime.py` | Runtime-Tests (Lebenszyklus, Lock, Idle-Unload, Resilienz) |
| `engine/tests/test_server_api.py` | HTTP-Tests (Endpunkte, Validierung, Fehlercodes) |
| `engine/tests/test_server_socket.py` | Echter Unix-Domain-Socket, verwaiste Socket-Datei |

---

### Task 1: Konfiguration und Abhängigkeiten

**Files:**
- Modify: `engine/pyproject.toml`
- Modify: `engine/typeless_engine/config.py`
- Test: `engine/tests/test_config.py` (neu)

**Interfaces:**
- Consumes: nichts (erste Task)
- Produces: `EngineConfig.socket_path: Path` (Default `APP_SUPPORT_DIR / "typeless.sock"`), `EngineConfig.idle_unload_seconds: float` (Default `300.0`), `EngineConfig.idle_check_interval_seconds: float` (Default `10.0`). Alle über Umgebungsvariablen mit Präfix `TYPELESS_` überschreibbar.

- [ ] **Step 1: Test schreiben**

Neue Datei `engine/tests/test_config.py`:

```python
"""Tests der Engine-Konfiguration."""

from __future__ import annotations

from pathlib import Path

import pytest

from typeless_engine.config import APP_SUPPORT_DIR, EngineConfig


def test_socket_path_defaults_next_to_dictionary() -> None:
    cfg = EngineConfig()

    assert cfg.socket_path == APP_SUPPORT_DIR / "typeless.sock"


def test_idle_unload_defaults_to_five_minutes() -> None:
    cfg = EngineConfig()

    assert cfg.idle_unload_seconds == 300.0
    assert cfg.idle_check_interval_seconds == 10.0


def test_socket_path_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TYPELESS_SOCKET_PATH", "/tmp/custom.sock")

    cfg = EngineConfig()

    assert cfg.socket_path == Path("/tmp/custom.sock")


def test_idle_unload_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TYPELESS_IDLE_UNLOAD_SECONDS", "42")

    cfg = EngineConfig()

    assert cfg.idle_unload_seconds == 42.0
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `cd engine && uv run pytest tests/test_config.py -v`
Expected: FAIL — `AttributeError`/`ValidationError`, `socket_path` existiert nicht.

- [ ] **Step 3: Konfiguration erweitern**

In `engine/typeless_engine/config.py`, nach der Zeile `DEFAULT_DICTIONARY_PATH = APP_SUPPORT_DIR / "dictionary.json"` ergänzen:

```python
DEFAULT_SOCKET_PATH = APP_SUPPORT_DIR / "typeless.sock"
```

In der Klasse `EngineConfig`, nach `dictionary_path`, ergänzen:

```python
    socket_path: Path = Field(default=DEFAULT_SOCKET_PATH)
    """Unix-Domain-Socket, über den die Swift-App den Sidecar anspricht (kein TCP-Port)."""

    idle_unload_seconds: float = 300.0
    """Nach so langer Untätigkeit wird das LLM entladen. Das STT bleibt warm."""

    idle_check_interval_seconds: float = 10.0
    """Wie oft der Idle-Wächter prüft."""
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `cd engine && uv run pytest tests/test_config.py -v`
Expected: PASS (4 Tests)

- [ ] **Step 5: Abhängigkeiten ergänzen**

In `engine/pyproject.toml` das `server`-Extra und das `dev`-Extra ersetzen:

```toml
# Sidecar-Server (M2).
server = [
    "fastapi>=0.110",
    "uvicorn>=0.29",
]
dev = [
    "pytest>=8.0",
    "ruff>=0.5",
    "black>=24.0",
    "mypy>=1.10",
    # Die Server-Tests laufen ohne MLX, brauchen aber FastAPI und einen HTTP-Client.
    # Beides ist reines Python und überall installierbar.
    "fastapi>=0.110",
    "uvicorn>=0.29",
    "httpx>=0.27",
]
```

- [ ] **Step 6: Installieren und Checks laufen lassen**

Run: `cd engine && uv sync --extra dev && cd .. && bash scripts/check.sh`
Expected: „Alle Checks bestanden."

- [ ] **Step 7: Commit**

```bash
git add engine/pyproject.toml engine/uv.lock engine/typeless_engine/config.py engine/tests/test_config.py
git commit -m "M2: Socket-Pfad und Idle-Timeout in EngineConfig"
```

---

### Task 2: EngineRuntime — Start, Preload, Process, Health

**Files:**
- Create: `engine/typeless_engine/server/__init__.py`
- Create: `engine/typeless_engine/server/runtime.py`
- Test: `engine/tests/test_runtime.py`

**Interfaces:**
- Consumes: `EngineConfig` (Task 1); `build_transcriber`/`build_refiner`/`build_dictionary` aus `factory.py`; `process` aus `pipeline`; `Mode`, `AudioBuffer`, `ProcessResult` aus `models.py`.
- Produces:
  - `class EngineRuntime` mit `__init__(self, config: EngineConfig, *, transcriber: Transcriber, refiner: Refiner, dictionary: DictionaryEngine, clock: Callable[[], float] = time.monotonic)`
  - `classmethod from_config(cls, config: EngineConfig) -> EngineRuntime` (baut über die Factory)
  - `async def startup(self) -> None` — lädt das STT warm
  - `async def preload(self) -> None` — lädt das LLM (idempotent)
  - `async def process(self, audio: AudioBuffer, mode: Mode) -> ProcessResult`
  - `async def unload(self) -> None`
  - `def health(self) -> HealthState` (Dataclass: `status: str`, `stt_loaded: bool`, `llm_loaded: bool`, `busy: bool`, `stt_model: str`, `llm_model: str`)
  - `async def shutdown(self) -> None`

- [ ] **Step 1: Test schreiben**

Neue Datei `engine/tests/test_runtime.py`:

```python
"""Tests der EngineRuntime — Lebenszyklus, Serialisierung, Fehler-Resilienz.

Läuft vollständig ohne MLX: Die Bausteine werden als Test-Doubles injiziert.
"""

from __future__ import annotations

import asyncio

import numpy as np
import pytest

from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, Transcriber
from typeless_engine.models import TARGET_SAMPLE_RATE, AudioBuffer, Mode, Transcription
from typeless_engine.server.runtime import EngineRuntime


class SpyTranscriber(Transcriber):
    """Zählt Warm-ups und Transkriptionen; kann Fehler simulieren."""

    def __init__(self, text: str = "hot spot ist super", fail: bool = False) -> None:
        self.warm_ups = 0
        self.calls = 0
        self._text = text
        self._fail = fail

    def warm_up(self) -> None:
        self.warm_ups += 1

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        self.calls += 1
        if self._fail:
            raise RuntimeError("STT kaputt")
        return Transcription(text=self._text, language="de", duration_seconds=1.0)


class SpyRefiner(Refiner):
    """Zählt Preloads/Unloads; kann beim Laden oder beim Generieren scheitern."""

    def __init__(self, fail_preload: bool = False, fail_refine: bool = False) -> None:
        self.preloads = 0
        self.unloads = 0
        self.refines = 0
        self._fail_preload = fail_preload
        self._fail_refine = fail_refine

    def preload(self) -> None:
        if self._fail_preload:
            raise RuntimeError("LLM lädt nicht")
        self.preloads += 1

    def unload(self) -> None:
        self.unloads += 1

    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        self.refines += 1
        if self._fail_refine:
            raise RuntimeError("Generierung kaputt")
        return text.capitalize() + "."


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def make_runtime(
    transcriber: Transcriber | None = None,
    refiner: Refiner | None = None,
    entries: dict[str, str] | None = None,
) -> EngineRuntime:
    return EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber or SpyTranscriber(),
        refiner=refiner or SpyRefiner(),
        dictionary=DictionaryEngine(entries or {"hot spot": "HubSpot"}),
    )


def audio(seconds: float = 1.0) -> AudioBuffer:
    return AudioBuffer(samples=np.zeros(int(TARGET_SAMPLE_RATE * seconds), dtype=np.float32))


@pytest.mark.anyio
async def test_startup_warms_stt() -> None:
    stt = SpyTranscriber()
    runtime = make_runtime(transcriber=stt)

    assert runtime.health().status == "starting"
    await runtime.startup()

    assert stt.warm_ups == 1
    assert runtime.health().status == "ready"
    assert runtime.health().stt_loaded is True


@pytest.mark.anyio
async def test_preload_is_idempotent() -> None:
    llm = SpyRefiner()
    runtime = make_runtime(refiner=llm)
    await runtime.startup()

    await runtime.preload()
    await runtime.preload()
    await runtime.preload()

    assert llm.preloads == 1
    assert runtime.health().llm_loaded is True


@pytest.mark.anyio
async def test_process_without_preload_loads_llm() -> None:
    llm = SpyRefiner()
    runtime = make_runtime(refiner=llm)
    await runtime.startup()

    result = await runtime.process(audio(), Mode.DIKTAT)

    assert llm.preloads == 1
    assert result.refined is True
    # Wörterbuch greift vor dem LLM:
    assert "HubSpot" in result.dictionary_text
    assert "HubSpot" in result.final_text


@pytest.mark.anyio
async def test_process_waits_for_startup() -> None:
    """Ein Diktat vor dem Ende des Warm-ups darf nicht scheitern, sondern wartet."""
    stt = SpyTranscriber()
    runtime = make_runtime(transcriber=stt)

    task = asyncio.create_task(runtime.process(audio(), Mode.DIKTAT))
    await asyncio.sleep(0)  # dem Task Gelegenheit geben, zu blockieren
    assert not task.done()

    await runtime.startup()
    result = await task

    assert result.final_text != ""
    assert stt.calls == 1


@pytest.mark.anyio
async def test_concurrent_process_calls_are_serialized() -> None:
    runtime = make_runtime()
    await runtime.startup()

    results = await asyncio.gather(
        runtime.process(audio(), Mode.DIKTAT),
        runtime.process(audio(), Mode.DIKTAT),
    )

    assert len(results) == 2
    for result in results:
        assert "HubSpot" in result.final_text


@pytest.mark.anyio
async def test_llm_load_failure_yields_raw_text() -> None:
    """LLM kaputt: Das Diktat geht nicht verloren, es kommt unpoliert zurück."""
    runtime = make_runtime(refiner=SpyRefiner(fail_preload=True))
    await runtime.startup()

    result = await runtime.process(audio(), Mode.DIKTAT)

    assert result.refined is False
    assert result.final_text == result.dictionary_text
    assert "HubSpot" in result.final_text
    assert result.fallback_reason is not None and "LLM" in result.fallback_reason


@pytest.mark.anyio
async def test_llm_generation_failure_yields_raw_text() -> None:
    runtime = make_runtime(refiner=SpyRefiner(fail_refine=True))
    await runtime.startup()

    result = await runtime.process(audio(), Mode.DIKTAT)

    assert result.refined is False
    assert result.final_text == result.dictionary_text
    assert result.fallback_reason is not None and "LLM" in result.fallback_reason


@pytest.mark.anyio
async def test_stt_failure_propagates() -> None:
    """Ohne Transkription gibt es keinen Text, den man retten könnte."""
    runtime = make_runtime(transcriber=SpyTranscriber(fail=True))
    await runtime.startup()

    with pytest.raises(RuntimeError, match="STT kaputt"):
        await runtime.process(audio(), Mode.DIKTAT)
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `cd engine && uv run pytest tests/test_runtime.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'typeless_engine.server'`

- [ ] **Step 3: Runtime implementieren**

Neue Datei `engine/typeless_engine/server/__init__.py`:

```python
"""Sidecar: lokaler Hintergrundprozess über einen Unix-Domain-Socket (kein TCP)."""

from __future__ import annotations

from .runtime import EngineRuntime, HealthState

__all__ = ["EngineRuntime", "HealthState"]
```

Neue Datei `engine/typeless_engine/server/runtime.py`:

```python
"""Laufzeit des Sidecars: Modelle, Lock, Idle-Timer — ohne jedes HTTP.

Die Runtime ist der Zustand, den die HTTP-Schicht nur noch bedient. Sie hängt (wie der
gesamte Kern) ausschließlich an den Interfaces ``Transcriber``/``Refiner`` und baut ihre
Bausteine über die Factory. Dadurch lässt sich der heikle Teil — Preload, Serialisierung,
Idle-Unload, Fallback bei LLM-Fehlern — vollständig mit Mock-Backends testen.

RAM-Strategie (16 GB): STT bleibt warm (1,51 GB, latenzkritisch), das LLM wird on-demand
geladen und im Leerlauf wieder freigegeben (Peak mit LLM: 3,62 GB).
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable
from dataclasses import dataclass, replace

from anyio import to_thread

from ..config import EngineConfig
from ..dictionary import DictionaryEngine
from ..factory import build_dictionary, build_refiner, build_transcriber
from ..interfaces import Refiner, Transcriber
from ..logging_ import get_logger
from ..models import AudioBuffer, Mode, ProcessResult
from ..pipeline import PipelineConfig, process

_log = get_logger(__name__)


@dataclass(frozen=True)
class HealthState:
    """Momentaufnahme des Sidecar-Zustands (Antwort auf ``/health``)."""

    status: str  # "starting" | "ready"
    stt_loaded: bool
    llm_loaded: bool
    busy: bool
    stt_model: str
    llm_model: str


class _ResilientRefiner(Refiner):
    """Fängt LLM-Fehler ab, statt das bereits transkribierte Diktat zu verlieren.

    Im Fehlerfall wird ein leerer Text zurückgegeben. Der Sanity-Check aus M1 wertet das
    als Fehlschlag und fällt auf den wörterbuch-bereinigten Rohtext zurück — genau das
    gewünschte Verhalten. Den echten Grund merkt sich ``last_error``; die Runtime schreibt
    ihn danach in das Ergebnis.
    """

    def __init__(self, inner: Refiner) -> None:
        self._inner = inner
        self.last_error: str | None = None

    def reset(self) -> None:
        self.last_error = None

    def preload(self) -> None:
        try:
            self._inner.preload()
        except Exception as exc:  # noqa: BLE001 - jeder Backend-Fehler ist hier gleichwertig
            self.last_error = f"LLM konnte nicht geladen werden: {exc}"
            _log.warning("%s", self.last_error)

    def unload(self) -> None:
        self._inner.unload()

    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        if self.last_error is not None:
            return ""  # Laden ist bereits gescheitert — gar nicht erst versuchen.
        try:
            return self._inner.refine(text, mode, language=language)
        except Exception as exc:  # noqa: BLE001
            self.last_error = f"LLM-Generierung fehlgeschlagen: {exc}"
            _log.warning("%s", self.last_error)
            return ""


class EngineRuntime:
    """Hält die Modelle warm und serialisiert die Verarbeitung."""

    def __init__(
        self,
        config: EngineConfig,
        *,
        transcriber: Transcriber,
        refiner: Refiner,
        dictionary: DictionaryEngine,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._config = config
        self._transcriber = transcriber
        self._refiner = _ResilientRefiner(refiner)
        self._dictionary = dictionary
        self._clock = clock

        self._lock = asyncio.Lock()
        self._ready = asyncio.Event()
        self._llm_loaded = False
        self._last_used = clock()

    @classmethod
    def from_config(cls, config: EngineConfig) -> EngineRuntime:
        """Baut die Runtime aus der Konfiguration (einzige Stelle: die Factory)."""
        return cls(
            config,
            transcriber=build_transcriber(config),
            refiner=build_refiner(config),
            dictionary=build_dictionary(config),
        )

    # ---- Zustand ------------------------------------------------------------

    def health(self) -> HealthState:
        """Sofort beantwortbar — nimmt bewusst keinen Lock."""
        return HealthState(
            status="ready" if self._ready.is_set() else "starting",
            stt_loaded=self._ready.is_set(),
            llm_loaded=self._llm_loaded,
            busy=self._lock.locked(),
            stt_model=self._config.stt_model,
            llm_model=self._config.llm_model,
        )

    # ---- Lebenszyklus -------------------------------------------------------

    async def startup(self) -> None:
        """Lädt das STT warm. Bis dahin meldet ``/health`` ``starting``."""
        _log.info("Wärme STT auf ...")
        await to_thread.run_sync(self._transcriber.warm_up)
        self._ready.set()
        _log.info("Sidecar bereit.")

    async def preload(self) -> None:
        """Lädt das LLM (spekulativ beim Hotkey-Druck). Mehrfach aufrufbar."""
        async with self._lock:
            await self._preload_unlocked()

    async def _preload_unlocked(self) -> None:
        if self._llm_loaded:
            return
        self._refiner.reset()
        await to_thread.run_sync(self._refiner.preload)
        self._llm_loaded = self._refiner.last_error is None
        self._last_used = self._clock()

    async def unload(self) -> None:
        """Gibt das LLM frei. Wartet, falls gerade verarbeitet wird."""
        async with self._lock:
            if not self._llm_loaded:
                return
            await to_thread.run_sync(self._refiner.unload)
            self._llm_loaded = False

    async def shutdown(self) -> None:
        """Fährt sauber herunter."""
        await self.unload()

    # ---- Verarbeitung -------------------------------------------------------

    async def process(self, audio: AudioBuffer, mode: Mode) -> ProcessResult:
        """Audio -> fertiger Text. Serialisiert; wartet auf das STT-Warm-up."""
        await self._ready.wait()
        async with self._lock:
            self._refiner.reset()
            await self._preload_unlocked()

            result = await to_thread.run_sync(self._run_pipeline, audio, mode)
            self._last_used = self._clock()

            if self._refiner.last_error is not None:
                # Der Sanity-Check hat bereits auf den Rohtext zurückgefallen; wir ersetzen
                # nur seinen generischen Grund ("leerer LLM-Output") durch den echten.
                result = replace(result, fallback_reason=self._refiner.last_error)
            return result

    def _run_pipeline(self, audio: AudioBuffer, mode: Mode) -> ProcessResult:
        """Blockierender Teil — läuft im Worker-Thread."""
        return process(
            audio,
            mode,
            transcriber=self._transcriber,
            refiner=self._refiner,
            dictionary=self._dictionary,
            config=PipelineConfig(language=self._config.language),
        )
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `cd engine && uv run pytest tests/test_runtime.py -v`
Expected: PASS (8 Tests)

- [ ] **Step 5: Checks laufen lassen**

Run: `bash scripts/check.sh`
Expected: „Alle Checks bestanden."

- [ ] **Step 6: Commit**

```bash
git add engine/typeless_engine/server engine/tests/test_runtime.py
git commit -m "M2: EngineRuntime (Warm-up, Preload, Serialisierung, LLM-Fallback)"
```

---

### Task 3: Idle-Unload

**Files:**
- Modify: `engine/typeless_engine/server/runtime.py`
- Test: `engine/tests/test_runtime.py` (ergänzen)

**Interfaces:**
- Consumes: `EngineRuntime` aus Task 2; `EngineConfig.idle_unload_seconds`, `EngineConfig.idle_check_interval_seconds` aus Task 1.
- Produces:
  - `async def maybe_idle_unload(self) -> bool` — entlädt das LLM, wenn die Frist abgelaufen ist; liefert `True`, wenn entladen wurde. **Der Test ruft diese Methode direkt auf** (mit injizierter Uhr), statt fünf Minuten zu warten.
  - `def start_idle_watcher(self) -> None` / `async def stop_idle_watcher(self) -> None` — Hintergrund-Task, der `maybe_idle_unload()` periodisch ruft.

- [ ] **Step 1: Test schreiben**

An `engine/tests/test_runtime.py` anhängen:

```python
class FakeClock:
    """Manipulierbare Uhr — damit der Idle-Test nicht fünf Minuten dauert."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def make_runtime_with_clock(clock: FakeClock, refiner: Refiner) -> EngineRuntime:
    return EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock", idle_unload_seconds=300.0),
        transcriber=SpyTranscriber(),
        refiner=refiner,
        dictionary=DictionaryEngine({}),
        clock=clock,
    )


@pytest.mark.anyio
async def test_idle_unload_frees_llm_after_timeout() -> None:
    clock = FakeClock()
    llm = SpyRefiner()
    runtime = make_runtime_with_clock(clock, llm)
    await runtime.startup()
    await runtime.preload()
    assert runtime.health().llm_loaded is True

    clock.advance(301.0)
    unloaded = await runtime.maybe_idle_unload()

    assert unloaded is True
    assert llm.unloads == 1
    assert runtime.health().llm_loaded is False


@pytest.mark.anyio
async def test_idle_unload_keeps_llm_before_timeout() -> None:
    clock = FakeClock()
    llm = SpyRefiner()
    runtime = make_runtime_with_clock(clock, llm)
    await runtime.startup()
    await runtime.preload()

    clock.advance(299.0)
    unloaded = await runtime.maybe_idle_unload()

    assert unloaded is False
    assert llm.unloads == 0
    assert runtime.health().llm_loaded is True


@pytest.mark.anyio
async def test_idle_unload_keeps_stt_warm() -> None:
    """Das STT ist latenzkritisch und bleibt geladen — nur das LLM fliegt raus."""
    clock = FakeClock()
    runtime = make_runtime_with_clock(clock, SpyRefiner())
    await runtime.startup()
    await runtime.preload()

    clock.advance(301.0)
    await runtime.maybe_idle_unload()

    assert runtime.health().stt_loaded is True
    assert runtime.health().status == "ready"


@pytest.mark.anyio
async def test_process_resets_the_idle_clock() -> None:
    clock = FakeClock()
    llm = SpyRefiner()
    runtime = make_runtime_with_clock(clock, llm)
    await runtime.startup()
    await runtime.preload()

    clock.advance(299.0)
    await runtime.process(audio(), Mode.DIKTAT)
    clock.advance(299.0)  # seit der Nutzung erst 299 s -> noch nicht entladen

    assert await runtime.maybe_idle_unload() is False
    assert llm.unloads == 0
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `cd engine && uv run pytest tests/test_runtime.py -k idle -v`
Expected: FAIL — `AttributeError: 'EngineRuntime' object has no attribute 'maybe_idle_unload'`

- [ ] **Step 3: Idle-Unload implementieren**

In `engine/typeless_engine/server/runtime.py` im Abschnitt „Lebenszyklus", nach `unload()`, ergänzen:

```python
    async def maybe_idle_unload(self) -> bool:
        """Entlädt das LLM, wenn es lange genug ungenutzt war. Liefert True, wenn entladen."""
        if not self._llm_loaded:
            return False
        idle_for = self._clock() - self._last_used
        if idle_for < self._config.idle_unload_seconds:
            return False
        _log.info("LLM seit %.0fs ungenutzt — entlade.", idle_for)
        await self.unload()
        return True

    def start_idle_watcher(self) -> None:
        """Startet den Hintergrund-Wächter, der periodisch ``maybe_idle_unload`` ruft."""
        if self._idle_task is None:
            self._idle_task = asyncio.create_task(self._idle_loop())

    async def stop_idle_watcher(self) -> None:
        if self._idle_task is None:
            return
        self._idle_task.cancel()
        try:
            await self._idle_task
        except asyncio.CancelledError:
            pass
        self._idle_task = None

    async def _idle_loop(self) -> None:
        while True:
            await asyncio.sleep(self._config.idle_check_interval_seconds)
            await self.maybe_idle_unload()
```

Im `__init__`, nach `self._last_used = clock()`, ergänzen:

```python
        self._idle_task: asyncio.Task[None] | None = None
```

`shutdown()` ersetzen durch:

```python
    async def shutdown(self) -> None:
        """Fährt sauber herunter: Wächter stoppen, LLM freigeben."""
        await self.stop_idle_watcher()
        await self.unload()
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `cd engine && uv run pytest tests/test_runtime.py -v`
Expected: PASS (12 Tests)

- [ ] **Step 5: Checks laufen lassen**

Run: `bash scripts/check.sh`
Expected: „Alle Checks bestanden."

- [ ] **Step 6: Commit**

```bash
git add engine/typeless_engine/server/runtime.py engine/tests/test_runtime.py
git commit -m "M2: Idle-Unload des LLM (STT bleibt warm)"
```

---

### Task 4: FastAPI-Schicht

**Files:**
- Create: `engine/typeless_engine/server/app.py`
- Modify: `engine/typeless_engine/server/__init__.py`
- Test: `engine/tests/test_server_api.py`

**Interfaces:**
- Consumes: `EngineRuntime`, `HealthState` (Tasks 2–3); `Mode.from_string`, `TARGET_SAMPLE_RATE`, `AudioBuffer` aus `models.py`.
- Produces: `def create_app(runtime: EngineRuntime) -> FastAPI` — die Runtime wird **injiziert** (Tests reichen eine Mock-Runtime herein; `__main__.py` baut sie aus der Config).

- [ ] **Step 1: Test schreiben**

Neue Datei `engine/tests/test_server_api.py`:

```python
"""Tests der HTTP-Schicht — ohne echte Modelle, ohne echten Socket."""

from __future__ import annotations

import asyncio

import numpy as np
import pytest
from httpx import ASGITransport, AsyncClient

from tests.test_runtime import SpyRefiner, SpyTranscriber
from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, Transcriber
from typeless_engine.models import TARGET_SAMPLE_RATE
from typeless_engine.server.app import create_app
from typeless_engine.server.runtime import EngineRuntime


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def build(
    transcriber: Transcriber | None = None, refiner: Refiner | None = None
) -> EngineRuntime:
    return EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber or SpyTranscriber(),
        refiner=refiner or SpyRefiner(),
        dictionary=DictionaryEngine({"hot spot": "HubSpot"}),
    )


def pcm(seconds: float = 1.0) -> bytes:
    """Rohes Float32-PCM, 16 kHz mono — genau das, was Swift schicken wird."""
    samples = np.zeros(int(TARGET_SAMPLE_RATE * seconds), dtype=np.float32)
    return samples.tobytes()


async def client_for(runtime: EngineRuntime) -> AsyncClient:
    app = create_app(runtime)
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://sidecar")


@pytest.mark.anyio
async def test_health_reports_starting_then_ready() -> None:
    runtime = build()
    async with await client_for(runtime) as client:
        response = await client.get("/health")
        assert response.status_code == 200
        assert response.json()["status"] == "starting"

        await runtime.startup()

        body = (await client.get("/health")).json()
        assert body["status"] == "ready"
        assert body["stt_loaded"] is True
        assert body["llm_loaded"] is False
        assert body["busy"] is False
        assert body["stt_model"]  # Modell-IDs werden mitgeliefert
        assert body["llm_model"]


@pytest.mark.anyio
async def test_process_returns_final_text() -> None:
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post(
            "/process?mode=diktat",
            content=pcm(),
            headers={"Content-Type": "application/octet-stream"},
        )

    assert response.status_code == 200
    body = response.json()
    assert "HubSpot" in body["final_text"]
    assert body["mode"] == "diktat"
    assert body["refined"] is True
    assert body["fallback_reason"] is None
    assert "transcribe" in body["timings_ms"]


@pytest.mark.anyio
async def test_preload_returns_immediately_and_loads() -> None:
    llm = SpyRefiner()
    runtime = build(refiner=llm)
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/preload")
        assert response.status_code == 202

        for _ in range(100):  # dem Hintergrund-Task Zeit geben
            if runtime.health().llm_loaded:
                break
            await asyncio.sleep(0.01)

    assert llm.preloads == 1


@pytest.mark.anyio
async def test_unload_frees_llm() -> None:
    llm = SpyRefiner()
    runtime = build(refiner=llm)
    await runtime.startup()
    await runtime.preload()

    async with await client_for(runtime) as client:
        response = await client.post("/unload")

    assert response.status_code == 200
    assert response.json()["llm_loaded"] is False
    assert llm.unloads == 1


@pytest.mark.anyio
async def test_unknown_mode_is_rejected_without_touching_models() -> None:
    stt = SpyTranscriber()
    runtime = build(transcriber=stt)
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=gibtsnicht", content=pcm())

    assert response.status_code == 400
    assert stt.calls == 0


@pytest.mark.anyio
async def test_empty_body_is_rejected() -> None:
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=b"")

    assert response.status_code == 400


@pytest.mark.anyio
async def test_body_length_not_multiple_of_four_is_rejected() -> None:
    """Float32 sind 4 Byte — eine krumme Länge kann kein gültiger Puffer sein."""
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=b"\x00\x00\x00")

    assert response.status_code == 400


@pytest.mark.anyio
async def test_wrong_sample_rate_is_rejected() -> None:
    """Aus rohem PCM ist die Rate nicht ablesbar — deshalb muss sie mitgeschickt werden."""
    runtime = build()
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat&sample_rate=44100", content=pcm())

    assert response.status_code == 400
    assert "16000" in response.json()["detail"]


@pytest.mark.anyio
async def test_llm_failure_returns_200_with_raw_text() -> None:
    runtime = build(refiner=SpyRefiner(fail_refine=True))
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=pcm())

    assert response.status_code == 200
    body = response.json()
    assert body["refined"] is False
    assert body["final_text"] == body["dictionary_text"]
    assert "LLM" in body["fallback_reason"]


@pytest.mark.anyio
async def test_stt_failure_returns_500() -> None:
    runtime = build(transcriber=SpyTranscriber(fail=True))
    await runtime.startup()
    async with await client_for(runtime) as client:
        response = await client.post("/process?mode=diktat", content=pcm())

    assert response.status_code == 500
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `cd engine && uv run pytest tests/test_server_api.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'typeless_engine.server.app'`

- [ ] **Step 3: App implementieren**

Neue Datei `engine/typeless_engine/server/app.py`:

```python
"""HTTP-Schicht des Sidecars.

Bewusst dünn: Sie validiert Eingaben und reicht an die ``EngineRuntime`` weiter. Sie hält
keinen Zustand. Die Runtime wird injiziert — deshalb laufen die Tests ohne echte Modelle.

Der Transport ist HTTP über einen Unix-Domain-Socket (siehe ``__main__``): kein Port, keine
Netzwerkschnittstelle. Der Host-Teil der URL ist bedeutungslos.
"""

from __future__ import annotations

import asyncio
from typing import Annotated

import numpy as np
from fastapi import Body, FastAPI, HTTPException, Query, Response
from pydantic import BaseModel

from ..logging_ import get_logger
from ..models import TARGET_SAMPLE_RATE, AudioBuffer, Mode
from .runtime import EngineRuntime

_log = get_logger(__name__)

# Float32 = 4 Byte. Eine Bytelänge, die kein Vielfaches davon ist, kann kein gültiger
# Samplepuffer sein.
_BYTES_PER_SAMPLE = 4


class HealthResponse(BaseModel):
    status: str
    stt_loaded: bool
    llm_loaded: bool
    busy: bool
    stt_model: str
    llm_model: str


class ProcessResponse(BaseModel):
    final_text: str
    raw_text: str
    dictionary_text: str
    mode: str
    language: str | None
    refined: bool
    fallback_reason: str | None
    timings_ms: dict[str, float]


def create_app(runtime: EngineRuntime) -> FastAPI:
    """Baut die FastAPI-App über einer bereits konstruierten Runtime."""
    app = FastAPI(title="TypeLess Sidecar", docs_url=None, redoc_url=None)

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        """Antwortet immer sofort — auch während einer laufenden Verarbeitung."""
        state = runtime.health()
        return HealthResponse(
            status=state.status,
            stt_loaded=state.stt_loaded,
            llm_loaded=state.llm_loaded,
            busy=state.busy,
            stt_model=state.stt_model,
            llm_model=state.llm_model,
        )

    @app.post("/preload", status_code=202)
    async def preload() -> Response:
        """Spekulativer Vorlauf beim Hotkey-Druck: startet das Laden und kehrt sofort zurück."""
        asyncio.create_task(runtime.preload())  # noqa: RUF006 - bewusst fire-and-forget
        return Response(status_code=202)

    @app.post("/unload", response_model=HealthResponse)
    async def unload() -> HealthResponse:
        """Gibt das LLM frei (Swift ruft das bei macOS-Speicherdruck)."""
        await runtime.unload()
        return await health()

    @app.post("/process", response_model=ProcessResponse)
    async def process_audio(
        audio: Annotated[bytes, Body(media_type="application/octet-stream")],
        mode: Annotated[str, Query()],
        language: Annotated[str | None, Query()] = None,
        sample_rate: Annotated[int, Query()] = TARGET_SAMPLE_RATE,
    ) -> ProcessResponse:
        """Rohes Float32-PCM (16 kHz mono) -> fertiger Text."""
        buffer = _decode_pcm(audio, sample_rate)
        try:
            parsed_mode = Mode.from_string(mode)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

        try:
            result = await runtime.process(buffer, parsed_mode)
        except Exception as exc:  # noqa: BLE001 - ohne Transkription gibt es nichts zu retten
            _log.exception("Verarbeitung fehlgeschlagen")
            raise HTTPException(status_code=500, detail=f"Verarbeitung fehlgeschlagen: {exc}") from exc

        return ProcessResponse(
            final_text=result.final_text,
            raw_text=result.raw_text,
            dictionary_text=result.dictionary_text,
            mode=result.mode.value,
            language=result.language,
            refined=result.refined,
            fallback_reason=result.fallback_reason,
            timings_ms=result.timings_ms,
        )

    return app


def _decode_pcm(payload: bytes, sample_rate: int) -> AudioBuffer:
    """Validiert den Binärpuffer und wandelt ihn in einen ``AudioBuffer``.

    Die Sample-Rate steht nicht in den Rohdaten und muss deshalb mitgeschickt werden. Wir
    resampeln bewusst **nicht**: Swift wandelt bereits mit ``AVAudioConverter`` um, und ein
    stiller Fallback würde nur verschleiern, wenn die Aufnahmeseite kaputtgeht.
    """
    if sample_rate != TARGET_SAMPLE_RATE:
        raise HTTPException(
            status_code=400,
            detail=f"Erwarte {TARGET_SAMPLE_RATE} Hz, erhalten {sample_rate} Hz.",
        )
    if not payload:
        raise HTTPException(status_code=400, detail="Leerer Audiopuffer.")
    if len(payload) % _BYTES_PER_SAMPLE != 0:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Bytelänge {len(payload)} ist kein Vielfaches von {_BYTES_PER_SAMPLE} — "
                "erwartet werden Float32-Samples."
            ),
        )
    samples = np.frombuffer(payload, dtype="<f4").astype(np.float32)
    return AudioBuffer(samples=samples, sample_rate=TARGET_SAMPLE_RATE)
```

`engine/typeless_engine/server/__init__.py` ersetzen:

```python
"""Sidecar: lokaler Hintergrundprozess über einen Unix-Domain-Socket (kein TCP)."""

from __future__ import annotations

from .app import create_app
from .runtime import EngineRuntime, HealthState

__all__ = ["EngineRuntime", "HealthState", "create_app"]
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `cd engine && uv run pytest tests/test_server_api.py -v`
Expected: PASS (9 Tests)

- [ ] **Step 5: Checks laufen lassen**

Run: `bash scripts/check.sh`
Expected: „Alle Checks bestanden."

- [ ] **Step 6: Commit**

```bash
git add engine/typeless_engine/server engine/tests/test_server_api.py
git commit -m "M2: FastAPI-Endpunkte (/health, /preload, /process, /unload)"
```

---

### Task 5: Start über den Unix-Domain-Socket

**Files:**
- Create: `engine/typeless_engine/server/__main__.py`
- Test: `engine/tests/test_server_socket.py`

**Interfaces:**
- Consumes: `create_app` (Task 4), `EngineRuntime.from_config` (Task 2), `EngineConfig.socket_path` (Task 1).
- Produces:
  - `def prepare_socket_path(path: Path) -> None` — legt das Verzeichnis an und entfernt eine **verwaiste** Socket-Datei (Rest eines abgestürzten Vorlaufs).
  - `def build_app() -> FastAPI` — Runtime aus der Config bauen, App erzeugen, Lifespan verdrahten (Warm-up als Hintergrund-Task, damit `/health` sofort `starting` melden kann; Idle-Wächter starten; beim Beenden `shutdown()`).
  - `def main() -> None` — uvicorn auf dem UDS starten.

- [ ] **Step 1: Test schreiben**

Neue Datei `engine/tests/test_server_socket.py`:

```python
"""Verifiziert das Einzige, was sich nicht mocken lässt: den echten Unix-Domain-Socket."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
import uvicorn
from httpx import AsyncClient, AsyncHTTPTransport

from tests.test_runtime import SpyRefiner, SpyTranscriber
from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.server.__main__ import prepare_socket_path
from typeless_engine.server.app import create_app
from typeless_engine.server.runtime import EngineRuntime


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def test_prepare_socket_path_removes_stale_file(tmp_path: Path) -> None:
    """Nach einem Absturz bleibt die Socket-Datei liegen — sonst startet der Server nie wieder."""
    socket_path = tmp_path / "nested" / "typeless.sock"
    socket_path.parent.mkdir(parents=True)
    socket_path.write_bytes(b"")  # verwaiste Datei
    assert socket_path.exists()

    prepare_socket_path(socket_path)

    assert not socket_path.exists()
    assert socket_path.parent.is_dir()


def test_prepare_socket_path_creates_missing_directory(tmp_path: Path) -> None:
    socket_path = tmp_path / "neu" / "typeless.sock"

    prepare_socket_path(socket_path)

    assert socket_path.parent.is_dir()


@pytest.mark.anyio
async def test_server_speaks_over_a_real_unix_socket(tmp_path: Path) -> None:
    socket_path = tmp_path / "typeless.sock"
    runtime = EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=SpyTranscriber(),
        refiner=SpyRefiner(),
        dictionary=DictionaryEngine({}),
    )
    await runtime.startup()

    config = uvicorn.Config(
        create_app(runtime), uds=str(socket_path), log_level="warning", lifespan="off"
    )
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())
    try:
        for _ in range(200):  # auf den Socket warten
            if socket_path.exists():
                break
            await asyncio.sleep(0.01)
        assert socket_path.exists(), "Server hat den Socket nicht angelegt"

        transport = AsyncHTTPTransport(uds=str(socket_path))
        async with AsyncClient(transport=transport, base_url="http://sidecar") as client:
            response = await client.get("/health")

        assert response.status_code == 200
        assert response.json()["status"] == "ready"
    finally:
        server.should_exit = True
        await task
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `cd engine && uv run pytest tests/test_server_socket.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'typeless_engine.server.__main__'`

- [ ] **Step 3: Einstiegspunkt implementieren**

Neue Datei `engine/typeless_engine/server/__main__.py`:

```python
"""Start des Sidecars auf einem Unix-Domain-Socket.

Bewusst kein TCP-Port: Der Socket ist eine Datei, die Zugangskontrolle sind Dateirechte.
Es gibt keine Netzwerkschnittstelle, unter der der Sidecar erreichbar wäre.

    uv run python -m typeless_engine.server
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI

from ..config import EngineConfig
from ..logging_ import configure_logging, get_logger
from .app import create_app
from .runtime import EngineRuntime

_log = get_logger(__name__)


def prepare_socket_path(path: Path) -> None:
    """Legt das Verzeichnis an und entfernt eine verwaiste Socket-Datei.

    Nach einem Absturz bleibt die Datei liegen; uvicorn würde sich sonst weigern, den
    Socket anzulegen, und der Sidecar käme nie wieder hoch.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        _log.warning("Entferne verwaiste Socket-Datei: %s", path)
        path.unlink()


def build_app(config: EngineConfig | None = None) -> FastAPI:
    """Baut Runtime + App und verdrahtet den Lebenszyklus."""
    cfg = config or EngineConfig()
    runtime = EngineRuntime.from_config(cfg)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        # Das Warm-up läuft als Hintergrund-Task: Der Server muss sofort antworten können,
        # damit /health die ~14 s Ladezeit als "starting" melden kann.
        warm_up = asyncio.create_task(runtime.startup())
        runtime.start_idle_watcher()
        try:
            yield
        finally:
            warm_up.cancel()
            await runtime.shutdown()

    app = create_app(runtime)
    app.router.lifespan_context = lifespan
    return app


def main() -> None:
    """Startet den Sidecar auf dem konfigurierten Socket."""
    configure_logging()
    cfg = EngineConfig()
    prepare_socket_path(cfg.socket_path)
    _log.info("Sidecar startet auf %s", cfg.socket_path)

    uvicorn.run(build_app(cfg), uds=str(cfg.socket_path), log_level=cfg.log_level.lower())


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `cd engine && uv run pytest tests/test_server_socket.py -v`
Expected: PASS (3 Tests)

- [ ] **Step 5: Alle Checks laufen lassen**

Run: `bash scripts/check.sh`
Expected: „Alle Checks bestanden." (Gesamtzahl der Tests: 48 aus M1 + 4 Config + 12 Runtime + 9 API + 3 Socket = 76)

- [ ] **Step 6: Commit**

```bash
git add engine/typeless_engine/server/__main__.py engine/tests/test_server_socket.py
git commit -m "M2: Start auf dem Unix-Domain-Socket, verwaiste Socket-Datei aufräumen"
```

---

### Task 6: Handprobe mit echten Modellen und Dokumentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `engine/README.md`

**Interfaces:**
- Consumes: den fertigen Sidecar aus den Tasks 1–5.
- Produces: nichts im Code — dies ist die Verifikation gegen echte Modelle plus Doku.

- [ ] **Step 1: Sidecar mit echten Modellen starten**

```bash
cd engine && uv run --extra mlx python -m typeless_engine.server
```

Erwartung: Log meldet „Sidecar startet auf …/typeless.sock", danach „Wärme STT auf …" und nach ~14 s „Sidecar bereit."

- [ ] **Step 2: /health über den Socket abfragen (zweites Terminal)**

```bash
curl --unix-socket ~/Library/Application\ Support/TypeLess/typeless.sock http://x/health
```

Erwartung: zunächst `{"status":"starting",...}`, nach dem Warm-up `{"status":"ready","stt_loaded":true,"llm_loaded":false,...}`

- [ ] **Step 3: Eine Sprachmemo als rohes PCM durchschicken**

```bash
# WAV -> rohes Float32-PCM, 16 kHz mono (genau das Format, das Swift liefern wird)
afconvert -f WAVE -d LEF32@16000 -c 1 memo.m4a memo_f32.wav
# WAV-Header (44 Byte) abschneiden, nur die Samples senden
tail -c +45 memo_f32.wav > memo.pcm

curl --unix-socket ~/Library/Application\ Support/TypeLess/typeless.sock \
     -H 'Content-Type: application/octet-stream' \
     --data-binary @memo.pcm \
     'http://x/process?mode=diktat'
```

Erwartung: JSON mit korrektem `final_text`, `refined: true`, und `timings_ms`, die zu den M1-Messungen passen (transcribe ≈ 0,17× der Audiolänge).

- [ ] **Step 4: Preload-Wirkung prüfen**

```bash
curl -X POST --unix-socket ~/Library/Application\ Support/TypeLess/typeless.sock http://x/preload
sleep 5
curl --unix-socket ~/Library/Application\ Support/TypeLess/typeless.sock http://x/health
```

Erwartung: `llm_loaded: true`. Ein anschließendes `/process` zeigt in `timings_ms.refine` **keine** Ladezeit mehr (~3,5 s statt ~7 s).

- [ ] **Step 5: Unload prüfen**

```bash
curl -X POST --unix-socket ~/Library/Application\ Support/TypeLess/typeless.sock http://x/unload
```

Erwartung: `{"llm_loaded":false,...}`. Der Speicherverbrauch des Prozesses fällt auf das STT-Niveau zurück (M1-Messung: 1,51 GB aktiv).

- [ ] **Step 6: Dokumentation aktualisieren**

In `CLAUDE.md` unter „Aktueller Stand" den M2-Eintrag von `- [ ]` auf `- [x]` setzen und die tatsächlichen Endpunkte festhalten. In `engine/README.md` einen Abschnitt „Sidecar" mit dem Startbefehl und den vier `curl`-Aufrufen aus den Schritten 2–5 ergänzen.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md engine/README.md
git commit -m "M2: Sidecar gegen echte Modelle verifiziert, Doku aktualisiert"
```

---

## Offene Risiken

- **`lifespan`-Verdrahtung:** `app.router.lifespan_context` nachträglich zu setzen funktioniert, ist aber nicht die üblichste FastAPI-Form. Falls es in der installierten Version klemmt, stattdessen `create_app(runtime, lifespan=...)` als optionalen Parameter einführen — die Tests aus Task 4 bleiben davon unberührt, weil sie ohne Lifespan arbeiten.
- **`asyncio.create_task` in `/preload`:** Der Task ist bewusst „fire and forget". Scheitert das Laden, wird der Fehler nicht im Endpunkt sichtbar, sondern erst beim nächsten `/process` (dort greift dann der LLM-Fallback aus Task 2). Das ist gewollt: `/preload` soll niemals blockieren.
- **Header-Länge bei `tail -c +45`** (Task 6, Schritt 3): Gilt für den Standard-WAV-Header. Erzeugt `afconvert` eine abweichende Header-Länge, schlägt die Transkription mit Rauschen fehl — dann den Header mit `python -c "import wave, sys; ..."` sauber überspringen statt fest 44 Byte anzunehmen.
