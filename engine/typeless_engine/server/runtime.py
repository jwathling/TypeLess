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
