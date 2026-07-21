# Verteilung Teil 2a: Modell-Bootstrap-Motor (Engine) — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Engine lädt beim ersten Start die von der Konfiguration benötigten Modelle (~3,9 GB)
explizit in den HF-Cache und meldet dabei Byte-Fortschritt über `/health` — mit einem
retry-fähigen Endpunkt, damit die Swift-Seite (Teil 2b) ein Einrichtungs-Fenster zeigen kann.

**Architecture:** Ein neues Modul `models_bootstrap.py` lädt die Modell-Dateien (`snapshot_download`
mit `tqdm_class`-Byte-Abgriff), ohne sie in den RAM zu laden. Die `EngineRuntime` bekommt einen
`ModelsState` und eine idempotente, retry-fähige `ensure_ready()`-Sequenz (erst Modelle sichern,
dann STT-Warm-up). `/health` meldet einen `models`-Block; `POST /models/ensure` stößt die Sequenz an
(auch als „Erneut versuchen" nach einem Netzfehler). Der Austauschbarkeits-Vertrag bleibt unberührt —
die Modell-Liste kommt aus der Config (`stt_model`/`llm_model`), nicht aus den Backend-Interfaces.

**Tech Stack:** Python 3.11+, huggingface_hub (`snapshot_download`, `HfApi.model_info`), FastAPI,
anyio `to_thread`, pytest.

**Verifizierte Grundlage (2026-07-21):** `HfApi().model_info(repo, files_metadata=True)` liefert
Dateigrößen (STT 1,61 GB + LLM 2,28 GB = ~3,89 GB); `snapshot_download` akzeptiert `tqdm_class`
(Byte-Fortschritt über `update(n)`, n = geladene Bytes).

## Global Constraints

- **Austauschbarkeit unberührt:** `interfaces/transcriber.py` (`transcribe`) und `interfaces/refiner.py`
  bleiben unverändert; `factory.py` bleibt die einzige Stelle mit konkreten Backends. Die Modell-Liste
  ist Infrastruktur und kommt aus `EngineConfig.stt_model` + `EngineConfig.llm_model`.
- **Cache-Ort:** Modelle liegen unter `HF_HOME` (in der ausgelieferten App via Teil 1 auf
  `~/Library/Application Support/TypeLess/models` gesetzt; im Dev-Betrieb der Default-HF-Cache).
- **Kein Diktat geht verloren / kein Zombie:** Scheitert der Modell-Download, meldet `/health`
  `models.state == "failed"` samt Grund; das STT-Warm-up wird dann übersprungen (nicht auf halben
  Modellen gestartet), und `POST /models/ensure` kann es erneut versuchen — ohne Sidecar-Neustart.
- **`/health` antwortet immer sofort** (nimmt keinen Lock), auch während des Downloads.
- Python 3.11+, `from __future__ import annotations`, Typannotationen überall, Docstrings/Kommentare
  auf Deutsch, mypy strict, ruff/black (line-length 100).

---

## Dateien-Überblick

- **Neu:** `engine/typeless_engine/server/models_bootstrap.py` — reine/HF-Funktionen: welche Modelle,
  sind sie im Cache, erwartete Gesamtgröße, Download mit Byte-Fortschritt.
- **Neu:** `engine/tests/test_models_bootstrap.py` — Tests der Bootstrap-Funktionen (huggingface_hub
  gemockt; kein echter Download).
- **Ändern:** `engine/typeless_engine/server/runtime.py` — `ModelsState`, `ensure_models()`,
  `ensure_ready()`, `_warm_up_stt()` (bisheriges `startup`-Innere), `health()` um `models` erweitert.
- **Ändern:** `engine/tests/test_server_runtime.py` (bzw. die vorhandene Runtime-Testdatei) — neue
  Zustands-/Sequenz-Tests mit Fakes.
- **Ändern:** `engine/typeless_engine/server/app.py` — `POST /models/ensure`; `models`-Block in
  `HealthResponse` + `/health`.
- **Ändern:** `engine/tests/test_server_app.py` (bzw. vorhandene App-Testdatei) — Endpunkt-Tests.
- **Neu:** `engine/scripts/measure_model_bootstrap.py` — On-device-Handprobe (Modelle in frischen
  Cache laden, Fortschritt beobachten).

---

### Task 1: `models_bootstrap.py` — Modell-Liste, Cache-Prüfung, Größe, Download mit Fortschritt

**Files:**
- Create: `engine/typeless_engine/server/models_bootstrap.py`
- Test: `engine/tests/test_models_bootstrap.py`

**Interfaces:**
- Produces:
  - `required_model_ids(config: EngineConfig) -> list[str]`
  - `models_cached(config: EngineConfig) -> bool`
  - `total_download_bytes(config: EngineConfig) -> int`
  - `download_models(config: EngineConfig, on_progress: Callable[[int, int], None]) -> None`
    — ruft `on_progress(downloaded_bytes, total_bytes)` laufend und am Ende genau einmal mit
    `(total, total)`.

- [ ] **Step 1: Failing tests**

```python
# engine/tests/test_models_bootstrap.py
from __future__ import annotations

from typeless_engine.config import EngineConfig
from typeless_engine.server import models_bootstrap as mb


def test_required_model_ids_kommen_aus_der_config():
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")
    assert mb.required_model_ids(cfg) == ["stt/repo", "llm/repo"]


def test_download_models_meldet_fortschritt_und_schliesst_mit_total(monkeypatch):
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")
    monkeypatch.setattr(mb, "total_download_bytes", lambda config: 1000)

    # snapshot_download durch ein Fake ersetzen, das die tqdm_class wie huggingface_hub bedient:
    # pro Repo 250 Bytes in zwei Häppchen laden.
    def fake_snapshot(repo_id, *, tqdm_class, **kwargs):
        bar = tqdm_class(total=250, unit="B")
        bar.update(100)
        bar.update(150)
        bar.close()

    monkeypatch.setattr(mb, "snapshot_download", fake_snapshot)

    calls: list[tuple[int, int]] = []
    mb.download_models(cfg, lambda d, t: calls.append((d, t)))

    # Zwischenstände monoton steigend, Gesamt immer 1000, Abschluss exakt (1000, 1000).
    assert calls[0] == (100, 1000)
    assert [d for d, _ in calls] == sorted(d for d, _ in calls)
    assert all(t == 1000 for _, t in calls)
    assert calls[-1] == (1000, 1000)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd engine && uv run pytest tests/test_models_bootstrap.py -q`
Expected: FAIL — Modul/Funktionen existieren nicht.

- [ ] **Step 3: Implement**

```python
# engine/typeless_engine/server/models_bootstrap.py
"""Modell-Bootstrap: lädt die von der Konfiguration benötigten Modell-Dateien in den HF-Cache,
bevor STT/LLM sie in den RAM laden, und meldet dabei Byte-Fortschritt. Lädt selbst NICHTS in den
RAM — das bleibt Sache von ``warm_up``/``preload``.

huggingface_hub wird lazy importiert: Der Kern muss ohne installierte Modelle importierbar bleiben.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from ..config import EngineConfig
from ..logging_ import get_logger

_log = get_logger(__name__)


def required_model_ids(config: EngineConfig) -> list[str]:
    """Die HF-Repo-IDs, die die aktuell konfigurierten Backends brauchen.

    Bewusst aus der Config, nicht aus den Backend-Interfaces: Der Austauschbarkeits-Vertrag
    (``transcribe``/``refine``) bleibt frei von Infrastruktur. Ein Backend, das andere Modelle
    braucht, bringt sie über dieselbe Config-Achse mit.
    """
    return [config.stt_model, config.llm_model]


def _snapshot_download(*args: Any, **kwargs: Any) -> Any:
    from huggingface_hub import snapshot_download  # noqa: PLC0415 (lazy)

    return snapshot_download(*args, **kwargs)


# Nach außen als Modulattribut sichtbar, damit Tests es mit monkeypatch ersetzen können.
snapshot_download = _snapshot_download


def models_cached(config: EngineConfig) -> bool:
    """Liegen alle benötigten Modelle bereits vollständig im lokalen HF-Cache? (kein Netz)"""
    from huggingface_hub.errors import LocalEntryNotFoundError  # noqa: PLC0415 (lazy)

    for repo in required_model_ids(config):
        try:
            snapshot_download(repo, local_files_only=True)
        except (LocalEntryNotFoundError, FileNotFoundError):
            return False
    return True


def total_download_bytes(config: EngineConfig) -> int:
    """Erwartete Gesamtgröße aller benötigten Modelle in Bytes (HF-Metadaten, braucht Netz)."""
    from huggingface_hub import HfApi  # noqa: PLC0415 (lazy)

    api = HfApi()
    total = 0
    for repo in required_model_ids(config):
        info = api.model_info(repo, files_metadata=True)
        total += sum((sibling.size or 0) for sibling in info.siblings)
    return total


def download_models(config: EngineConfig, on_progress: Callable[[int, int], None]) -> None:
    """Lädt alle benötigten Modell-Dateien in den Cache und meldet ``(downloaded, total)`` laufend.

    Der Fortschritt kommt über eine ``tqdm``-Unterklasse: huggingface_hub instanziiert sie pro Datei
    und ruft ``update(n)`` mit der Anzahl gerade geladener Bytes. Wir summieren diese über alle
    Dateien/Repos. Bereits gecachte Dateien lösen kein ``update`` aus — deshalb am Ende genau ein
    ``on_progress(total, total)``, damit der Balken auch bei teilweise vollem Cache sauber schließt.
    """
    import tqdm as tqdm_mod  # noqa: PLC0415 (lazy — nur beim echten Download nötig)

    total = total_download_bytes(config)
    downloaded = 0

    class _ProgressTqdm(tqdm_mod.tqdm):  # type: ignore[misc]
        def update(self, n: float | None = 1) -> bool | None:
            nonlocal downloaded
            downloaded += int(n or 0)
            on_progress(downloaded, total)
            return super().update(n)

    for repo in required_model_ids(config):
        _log.info("Lade Modell in den Cache: %s", repo)
        snapshot_download(repo, tqdm_class=_ProgressTqdm)

    on_progress(total, total)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd engine && uv run pytest tests/test_models_bootstrap.py -q`
Expected: PASS (2 Tests).

- [ ] **Step 5: Lint + Commit**

```bash
cd engine && uv run ruff check typeless_engine/server/models_bootstrap.py && uv run black --check typeless_engine/server/models_bootstrap.py
git add engine/typeless_engine/server/models_bootstrap.py engine/tests/test_models_bootstrap.py
git commit -m "M8-Verteilung Teil2a: models_bootstrap — Modell-Liste, Cache-Pruefung, Download mit Byte-Fortschritt"
```

---

### Task 2: Runtime — `ModelsState`, `ensure_ready()`-Sequenz, `health()`-Erweiterung

**Files:**
- Modify: `engine/typeless_engine/server/runtime.py`
- Test: `engine/tests/test_server_runtime.py` (vorhandene Runtime-Testdatei)

**Interfaces:**
- Consumes: `models_bootstrap.models_cached`, `.total_download_bytes`, `.download_models` (Task 1).
- Produces:
  - `@dataclass(frozen=True) ModelsState(state: str, downloaded_bytes: int, total_bytes: int, error: str | None)`
    — `state ∈ {"missing", "downloading", "ready", "failed"}`.
  - `EngineRuntime.ensure_ready() -> None` — idempotent, serialisiert: sichert Modelle, dann
    STT-Warm-up. Retry-fähig (nach `failed` erneut aufrufbar).
  - `HealthState.models: ModelsState` (neues Feld).

**Kontext:** Heute lädt `startup()` das STT direkt (`_transcriber.warm_up`) und öffnet danach
`_ready`. Neu wird das STT-Warm-up **hinter** die Modell-Sicherung gehängt. Der bisherige
`startup()`-Body wird zu `_warm_up_stt()`; `startup()` (vom Lifespan gerufen) delegiert an
`ensure_ready()`.

- [ ] **Step 1: Failing tests**

Nutze eine Test-Runtime mit Fakes. Der Transcriber-Fake zählt `warm_up`-Aufrufe. `models_bootstrap`
wird per monkeypatch gesteuert.

```python
# in engine/tests/test_server_runtime.py ergänzen
import typeless_engine.server.runtime as rt


def test_ensure_ready_bei_vorhandenem_cache_setzt_ready_und_waermt_stt(monkeypatch):
    monkeypatch.setattr(rt.models_bootstrap, "models_cached", lambda config: True)
    runtime = make_test_runtime()  # vorhandener Helfer mit FakeTranscriber/FakeRefiner
    import anyio
    anyio.run(runtime.ensure_ready)
    h = runtime.health()
    assert h.models.state == "ready"
    assert h.status == "ready"
    assert runtime._transcriber.warm_up_calls == 1  # STT wurde warm


def test_ensure_ready_bei_download_fehler_meldet_failed_und_ueberspringt_warmup(monkeypatch):
    monkeypatch.setattr(rt.models_bootstrap, "models_cached", lambda config: False)
    monkeypatch.setattr(rt.models_bootstrap, "total_download_bytes", lambda config: 1000)

    def boom(config, on_progress):
        raise RuntimeError("kein Netz")

    monkeypatch.setattr(rt.models_bootstrap, "download_models", boom)
    runtime = make_test_runtime()
    import anyio
    anyio.run(runtime.ensure_ready)
    h = runtime.health()
    assert h.models.state == "failed"
    assert "kein Netz" in (h.models.error or "")
    assert runtime._transcriber.warm_up_calls == 0  # STT NICHT auf halben Modellen gestartet
    assert h.status != "ready"


def test_ensure_ready_ist_nach_fehler_wiederholbar(monkeypatch):
    calls = {"n": 0}

    def cached(config):
        return calls["n"] > 0  # erster Lauf: fehlt; nach Retry: da

    monkeypatch.setattr(rt.models_bootstrap, "models_cached", cached)
    monkeypatch.setattr(rt.models_bootstrap, "total_download_bytes", lambda config: 10)

    def flaky(config, on_progress):
        calls["n"] += 1
        raise RuntimeError("kein Netz")  # erster Download scheitert

    monkeypatch.setattr(rt.models_bootstrap, "download_models", flaky)
    runtime = make_test_runtime()
    import anyio
    anyio.run(runtime.ensure_ready)
    assert runtime.health().models.state == "failed"
    # Retry: jetzt ist der Cache "da" (cached() liefert True) -> ready + STT warm
    anyio.run(runtime.ensure_ready)
    h = runtime.health()
    assert h.models.state == "ready"
    assert h.status == "ready"
    assert runtime._transcriber.warm_up_calls == 1
```

> Umsetzer-Hinweis: Nutze die in der Datei bereits vorhandenen Fakes/Helfer (`make_test_runtime`
> o. Ä., FakeTranscriber). Falls der FakeTranscriber noch keinen `warm_up_calls`-Zähler hat, ergänze
> ihn minimal. Bestehende `startup()`-Tests, die direkt `startup` aufrufen, weiter grün halten
> (siehe Step 3 — `startup` bleibt als Einstieg erhalten).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd engine && uv run pytest tests/test_server_runtime.py -q -k ensure_ready`
Expected: FAIL — `ensure_ready`/`ModelsState`/`models` gibt es nicht.

- [ ] **Step 3: Implement**

Ergänze in `runtime.py` den Import und die `ModelsState`, erweitere `HealthState`, und baue die
Sequenz. Konkret:

```python
from . import models_bootstrap
```

```python
@dataclass(frozen=True)
class ModelsState:
    """Zustand des Modell-Bootstraps (Teil des ``/health``-Reports)."""

    state: str  # "missing" | "downloading" | "ready" | "failed"
    downloaded_bytes: int = 0
    total_bytes: int = 0
    error: str | None = None
```

`HealthState` um ein Feld ergänzen:

```python
    models: ModelsState = ModelsState(state="missing")
```

Im `EngineRuntime.__init__` initialisieren:

```python
        self._models_state = ModelsState(state="missing")
        self._ensure_lock = asyncio.Lock()
```

`health()` reicht den Zustand mit durch (im `return HealthState(...)` ergänzen):

```python
            models=self._models_state,
```

Der bisherige `startup()`-Body wird zu `_warm_up_stt()`; `startup()` delegiert an `ensure_ready()`:

```python
    async def startup(self) -> None:
        """Vom Lifespan gerufen: Modelle sichern (mit Fortschritt), dann STT warm laden."""
        await self.ensure_ready()

    async def ensure_ready(self) -> None:
        """Idempotent + retry-fähig: erst die Modelle in den Cache, dann das STT-Warm-up.

        Serialisiert über ``_ensure_lock`` — der Lifespan-Startlauf und ein paralleles
        ``POST /models/ensure`` (Retry) dürfen sich nicht überlappen. Nach einem
        fehlgeschlagenen Download bleibt ``models.state == "failed"``; ein erneuter Aufruf
        (Retry ohne Sidecar-Neustart) versucht es wieder.
        """
        async with self._ensure_lock:
            await self._ensure_models_unlocked()
            if self._models_state.state == "ready" and not self._ready.is_set():
                await self._warm_up_stt()

    async def _ensure_models_unlocked(self) -> None:
        if self._models_state.state == "ready":
            return
        if models_bootstrap.models_cached(self._config):
            self._models_state = ModelsState(state="ready")
            return
        total = await to_thread.run_sync(lambda: models_bootstrap.total_download_bytes(self._config))
        self._models_state = ModelsState(state="downloading", downloaded_bytes=0, total_bytes=total)

        def on_progress(downloaded: int, total_bytes: int) -> None:
            # Reiner int-Schreibvorgang aus dem Worker-Thread; ``health()`` liest ihn im Loop.
            # Ein frozen-Replace ist atomar genug für einen Fortschrittswert (kein Lock nötig).
            self._models_state = ModelsState(
                state="downloading", downloaded_bytes=downloaded, total_bytes=total_bytes
            )

        try:
            await to_thread.run_sync(
                lambda: models_bootstrap.download_models(self._config, on_progress)
            )
        except Exception as exc:  # noqa: BLE001 — jeder Download-Fehler ist hier gleichwertig
            self._models_state = ModelsState(
                state="failed", total_bytes=total, error=f"Modell-Download fehlgeschlagen: {exc}"
            )
            _log.warning("Modell-Download fehlgeschlagen: %s", exc)
            return
        self._models_state = ModelsState(state="ready", downloaded_bytes=total, total_bytes=total)

    async def _warm_up_stt(self) -> None:
        # (bisheriger Body von startup(): to_thread warm_up, _startup_error, _ready.set())
        _log.info("Wärme STT auf ...")
        try:
            await to_thread.run_sync(self._transcriber.warm_up)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self._startup_error = f"STT-Warm-up fehlgeschlagen: {exc}"
            self._ready.set()
            raise
        self._ready.set()
        _log.info("Sidecar bereit.")
```

> Der `HealthState`-Default für `models` (`ModelsState(state="missing")`) und der `__init__`-Default
> müssen übereinstimmen. `stt_loaded`/`status`-Logik in `health()` bleibt unverändert.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd engine && uv run pytest tests/test_server_runtime.py -q`
Expected: PASS (neue + alle bestehenden Runtime-Tests).

- [ ] **Step 5: Commit**

```bash
git add engine/typeless_engine/server/runtime.py engine/tests/test_server_runtime.py
git commit -m "M8-Verteilung Teil2a: Runtime ModelsState + ensure_ready (Modelle sichern, dann STT-Warm-up, retry-faehig)"
```

---

### Task 3: HTTP — `POST /models/ensure` + `models`-Block in `/health`

**Files:**
- Modify: `engine/typeless_engine/server/app.py`
- Test: `engine/tests/test_server_app.py` (vorhandene App-Testdatei)

**Interfaces:**
- Consumes: `EngineRuntime.ensure_ready`, `HealthState.models` / `ModelsState` (Task 2).
- Produces: `HealthResponse.models: ModelsResponse` (JSON `{state, downloaded_bytes, total_bytes, error}`);
  `POST /models/ensure` → `202`.

- [ ] **Step 1: Failing tests**

```python
# in engine/tests/test_server_app.py ergänzen (nutzt den vorhandenen TestClient + Fake-Runtime)
def test_health_enthaelt_models_block(client_and_runtime):
    client, runtime = client_and_runtime
    resp = client.get("/health")
    body = resp.json()
    assert "models" in body
    assert set(body["models"]) == {"state", "downloaded_bytes", "total_bytes", "error"}


def test_models_ensure_startet_sequenz_und_antwortet_202(client_and_runtime):
    client, runtime = client_and_runtime
    resp = client.post("/models/ensure")
    assert resp.status_code == 202
    assert runtime.ensure_ready_calls >= 1  # Fake-Runtime zählt die Aufrufe
```

> Umsetzer-Hinweis: Die vorhandene App-Testdatei nutzt eine Fake-/Mock-Runtime. Ergänze dort einen
> `ensure_ready`-Zähler (analog zu vorhandenen Methoden) und liefere in `health()` einen
> `HealthState` mit einem `ModelsState`. Übernimm die bereits genutzten Fixture-Namen.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd engine && uv run pytest tests/test_server_app.py -q -k "models"`
Expected: FAIL — kein `models`-Feld / kein `/models/ensure`.

- [ ] **Step 3: Implement**

In `app.py` ein `ModelsResponse`-Modell ergänzen und in `HealthResponse` einhängen:

```python
class ModelsResponse(BaseModel):
    state: str  # "missing" | "downloading" | "ready" | "failed"
    downloaded_bytes: int
    total_bytes: int
    error: str | None = None


class HealthResponse(BaseModel):
    status: str
    stt_loaded: bool
    llm_loaded: bool
    busy: bool
    stt_model: str
    llm_model: str
    error: str | None = None
    models: ModelsResponse
```

Im `/health`-Handler den Block füllen:

```python
        return HealthResponse(
            status=state.status,
            stt_loaded=state.stt_loaded,
            llm_loaded=state.llm_loaded,
            busy=state.busy,
            stt_model=state.stt_model,
            llm_model=state.llm_model,
            error=state.error,
            models=ModelsResponse(
                state=state.models.state,
                downloaded_bytes=state.models.downloaded_bytes,
                total_bytes=state.models.total_bytes,
                error=state.models.error,
            ),
        )
```

Und den Endpunkt (im Hintergrund starten wie `/preload`, damit die Antwort sofort kommt):

```python
    @app.post("/models/ensure", status_code=202)
    async def ensure_models() -> Response:
        """Stößt Modell-Sicherung + STT-Warm-up an (auch als „Erneut versuchen" nach Netzfehler).

        Kehrt sofort mit 202 zurück; der Fortschritt läuft über ``/health`` (``models``-Block).
        """
        task = asyncio.create_task(runtime.ensure_ready())
        preload_tasks.add(task)  # dieselbe Menge hält den Task am Leben und räumt ihn im Lifespan ab
        task.add_done_callback(preload_tasks.discard)
        return Response(status_code=202)
```

> `preload_tasks` existiert bereits (Task-am-Leben-Halten + Abräumen im Lifespan). Die
> `ensure_ready`-Serialisierung (Task 2, `_ensure_lock`) sorgt dafür, dass ein Retry-Aufruf einen
> noch laufenden Startlauf nicht überlappt.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd engine && uv run pytest tests/test_server_app.py -q`
Expected: PASS (neue + bestehende App-Tests).

- [ ] **Step 5: Volle Suite + Lint + Commit**

```bash
cd engine && bash ../scripts/check.sh
git add engine/typeless_engine/server/app.py engine/tests/test_server_app.py
git commit -m "M8-Verteilung Teil2a: POST /models/ensure + models-Block in /health"
```

---

### Task 4: On-device-Handprobe — Modell-Bootstrap mit echtem Fortschritt

**Files:**
- Create: `engine/scripts/measure_model_bootstrap.py`

**Kontext:** Der Beweis, dass der Fortschritt on-device real läuft: in einen **frischen** HF-Cache
laden und die `(downloaded, total)`-Meldungen beobachten. Verhält sich wie ein frischer Mac.

- [ ] **Step 1: Skript schreiben**

```python
# engine/scripts/measure_model_bootstrap.py
"""On-device-Handprobe (Apple Silicon): lädt die Modelle in einen FRISCHEN Cache und zeigt den
Byte-Fortschritt. Simuliert den ersten Start auf einem neuen Mac.

    cd engine && uv run --extra mlx python scripts/measure_model_bootstrap.py
"""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from typeless_engine.config import EngineConfig
from typeless_engine.server import models_bootstrap as mb


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        import os

        os.environ["HF_HOME"] = str(Path(tmp) / "models")  # frischer Cache
        cfg = EngineConfig()
        print(f"cached (frisch, erwartet False): {mb.models_cached(cfg)}")
        total = mb.total_download_bytes(cfg)
        print(f"Gesamtgröße: {total / 1e9:.2f} GB")

        t0 = time.perf_counter()
        letzte = 0.0

        def on_progress(downloaded: int, total_bytes: int) -> None:
            nonlocal letzte
            now = time.perf_counter()
            if now - letzte >= 2.0 or downloaded == total_bytes:  # nicht zu geschwätzig
                pct = 100 * downloaded / total_bytes if total_bytes else 0
                print(f"  {pct:5.1f} %  ({downloaded / 1e9:.2f} / {total_bytes / 1e9:.2f} GB)")
                letzte = now

        mb.download_models(cfg, on_progress)
        print(f"fertig in {time.perf_counter() - t0:.0f} s; cached jetzt: {mb.models_cached(cfg)}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Ausführen und Fortschritt beobachten**

Run: `cd engine && uv run --extra mlx python scripts/measure_model_bootstrap.py`
Expected: `cached (frisch): False`, dann eine steigende Prozentanzeige von ~0 % auf `100.0 %`
(~3,9 GB), am Ende `cached jetzt: True`. (Lädt real ~3,9 GB — braucht Netz und einige Minuten.)

- [ ] **Step 3: Commit**

```bash
git add engine/scripts/measure_model_bootstrap.py
git commit -m "M8-Verteilung Teil2a: On-device-Handprobe fuer den Modell-Bootstrap"
```

---

## Selbstprüfung (nach dem Schreiben, gegen die Spec)

- **Spec-Abdeckung (Baustein 2, Engine-Teil):** `POST /models/ensure` (Task 3), `models`-Statusblock
  in `/health` mit `state`/`downloaded`/`total` (Task 2+3), Download der von den Backends benötigten
  Modelle nach `HF_HOME` (Task 1, aus Config), idempotent + retry-fähig (Task 2), Fehlerpfad kein
  Netz → `failed` (Task 2). Der Fortschritt kommt über den HF-Download-Callback (`tqdm_class`), wie
  in der Spec bevorzugt. ✓
- **Nicht in diesem Plan (Teil 2b):** Erststart-Erkennung + SwiftUI-Einrichtungsfenster + Swift-seitige
  `models`-Auswertung im `SidecarClient`/`AppState`. Das JSON-Schema des `models`-Blocks ist hier
  festgelegt (`state, downloaded_bytes, total_bytes, error`) — Teil 2b konsumiert es.
- **Austauschbarkeit:** Modell-Liste aus der Config, kein Backend-Interface angefasst. ✓
- **Typkonsistenz:** `ModelsState` (runtime) ↔ `ModelsResponse` (app) haben dieselben Felder
  (`state, downloaded_bytes, total_bytes, error`); `ensure_ready()` in Task 2 definiert, in Task 3
  genutzt. ✓

## Ausführungs-Hinweis

Reihenfolge 1→4 (Task 2 braucht 1, Task 3 braucht 2, Task 4 braucht 1). Nach Task 3 ist der Motor
komplett und über `curl --unix-socket … /health` + `POST /models/ensure` prüfbar; Task 4 belegt den
echten Download-Fortschritt. Danach Teil 2b (Swift-Erststart-Fenster) planen.
