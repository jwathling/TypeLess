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
import contextlib
import time
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, replace

import numpy as np
from anyio import to_thread

from ..config import EngineConfig
from ..dictionary import DictionaryEngine
from ..factory import build_dictionary, build_refiner, build_transcriber
from ..interfaces import Refiner, StreamingTranscriber, Transcriber
from ..logging_ import get_logger
from ..models import AudioBuffer, Mode, ProcessResult, Transcription
from ..pipeline import PipelineConfig, process, process_text

_log = get_logger(__name__)


@dataclass(frozen=True)
class HealthState:
    """Momentaufnahme des Sidecar-Zustands (Antwort auf ``/health``)."""

    status: str  # "starting" | "ready" | "failed"
    stt_loaded: bool
    llm_loaded: bool
    busy: bool
    stt_model: str
    llm_model: str
    error: str | None = None  # Grund, falls ``status == "failed"``; sonst None


class StartupFailedError(RuntimeError):
    """Das STT-Warm-up ist gescheitert — der Sidecar wird nie einsatzbereit.

    Eigener Typ, damit die HTTP-Schicht diesen Zustand (503, Dienst nicht verfügbar) von einem
    echten Verarbeitungsfehler (500) unterscheiden kann.
    """


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
        try:
            self._inner.unload()
        except Exception as exc:  # noqa: BLE001 - jeder Backend-Fehler ist hier gleichwertig
            # Nicht propagieren: Der Aufrufer (EngineRuntime.unload) setzt den Zustand danach
            # unbedingt auf "nicht geladen" — ein zweiter Unload-Versuch würde am halb
            # freigegebenen Modell ohnehin nichts mehr reparieren.
            _log.warning("LLM konnte nicht sauber freigegeben werden: %s", exc)

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
        # Gate für "Start abgeschlossen" — gesetzt wird es in *beiden* Fällen: nach einem
        # erfolgreichen Warm-up und nach einem gescheiterten. Sonst warteten die
        # ``process()``-Aufrufer bei einem kaputten Modell für immer (siehe ``startup``).
        self._ready = asyncio.Event()
        self._startup_error: str | None = None
        self._llm_loaded = False
        # Nur "es wird gerade ein Diktat verarbeitet" — bewusst nicht ``self._lock.locked()``:
        # Den Lock hält auch ein reines ``/preload``, und die Swift-Shell (M3) hängt ihr Overlay
        # an ``busy``; es darf beim bloßen Hotkey-Druck nicht aufblitzen.
        self._busy = False
        self._last_used = clock()
        self._idle_task: asyncio.Task[None] | None = None

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
        if self._startup_error is not None:
            status = "failed"
        elif self._ready.is_set():
            status = "ready"
        else:
            status = "starting"
        return HealthState(
            status=status,
            stt_loaded=self._ready.is_set() and self._startup_error is None,
            llm_loaded=self._llm_loaded,
            busy=self._busy,
            stt_model=self._config.stt_model,
            llm_model=self._config.llm_model,
            error=self._startup_error,
        )

    # ---- Lebenszyklus -------------------------------------------------------

    async def startup(self) -> None:
        """Lädt das STT warm. Bis dahin meldet ``/health`` ``starting``.

        Scheitert das Laden (kaputter Modell-Cache, falsche Modell-ID, kein Netz beim ersten
        Download), wird der Grund festgehalten **und das Ready-Gate trotzdem geöffnet**: Sonst
        bliebe ``/health`` für immer auf ``starting`` und jede ``/process``-Anfrage hinge
        endlos — ein Zombie, den die Swift-Shell nicht von "lädt noch" unterscheiden könnte.
        Der Fehler wird danach weitergereicht, damit der Aufrufer ihn protokollieren kann.
        """
        _log.info("Wärme STT auf ...")
        try:
            await to_thread.run_sync(self._transcriber.warm_up)
        except asyncio.CancelledError:
            raise  # Regulärer Shutdown während des Warm-ups — kein Startfehler.
        except Exception as exc:
            self._startup_error = f"STT-Warm-up fehlgeschlagen: {exc}"
            self._ready.set()  # Wartende wecken — sie scheitern gleich mit StartupFailedError.
            raise
        self._ready.set()
        _log.info("Sidecar bereit.")

    async def preload(self) -> None:
        """Lädt das LLM (spekulativ beim Hotkey-Druck). Mehrfach aufrufbar."""
        if self._startup_error is not None:
            # Ohne funktionierendes STT wird nie transkribiert — dann muss auch kein LLM
            # (~2 GB) in einen Prozess geladen werden, der ohnehin nichts verarbeiten kann.
            _log.warning("Preload übersprungen: Sidecar ist nicht einsatzbereit.")
            return
        async with self._lock:
            await self._preload_unlocked()

    async def _preload_unlocked(self) -> None:
        # Zuerst die Uhr: Ein Hotkey-Druck ist eine Nutzung, auch wenn nichts zu laden ist.
        # Stünde das hinter dem Early-Return, frischte ein ``/preload`` bei bereits geladenem
        # LLM die Frist nicht auf — der Idle-Wächter könnte das Modell dann mitten im Diktat
        # entladen, also genau in dem Moment, für den ``/preload`` überhaupt existiert.
        self._last_used = self._clock()
        if self._llm_loaded:
            return
        self._refiner.reset()
        await to_thread.run_sync(self._refiner.preload)
        self._llm_loaded = self._refiner.last_error is None
        self._last_used = self._clock()

    async def unload(self) -> None:
        """Gibt das LLM frei. Wartet, falls gerade verarbeitet wird."""
        async with self._lock:
            await self._unload_unlocked()

    async def _unload_unlocked(self) -> None:
        if not self._llm_loaded:
            return
        await to_thread.run_sync(self._refiner.unload)
        self._llm_loaded = False

    async def maybe_idle_unload(self) -> bool:
        """Entlädt das LLM, wenn es lange genug ungenutzt war. Liefert True, wenn entladen.

        Frist-Prüfung und Entladen laufen atomar unter demselben Lock (TOCTOU-Fix): Würde
        ``idle_for`` — wie zuvor — außerhalb des Locks gelesen, könnte zwischen dieser
        Prüfung und dem eigentlichen Entladen ein ``process()``-Aufruf den Lock nehmen,
        ``_last_used`` auf „jetzt" aktualisieren und wieder freigeben; der anschließende
        ``unload()`` würde das dann trotzdem entladen, weil er nur noch ``_llm_loaded``
        prüft, nicht mehr die (inzwischen veraltete) Frist. Der Lock allein verhindert zwar
        zuverlässig, dass ein Entladen in eine laufende Generierung fällt — er verhindert
        aber nicht, dass die Freigabe auf einer bereits überholten Frist basiert. Deshalb
        hier — wie bei ``preload``/``_preload_unlocked`` — eine ``_unlocked``-Variante, die
        aus dem bereits gehaltenen Lock heraus aufgerufen wird, statt des reentrant nicht
        möglichen ``unload()``.
        """
        async with self._lock:
            if not self._llm_loaded:
                return False
            idle_for = self._clock() - self._last_used
            if idle_for < self._config.idle_unload_seconds:
                return False
            _log.info("LLM seit %.0fs ungenutzt — entlade.", idle_for)
            await self._unload_unlocked()
            return True

    def start_idle_watcher(self) -> None:
        """Startet den Hintergrund-Wächter, der periodisch ``maybe_idle_unload`` ruft."""
        if self._idle_task is None:
            self._idle_task = asyncio.create_task(self._idle_loop())

    async def stop_idle_watcher(self) -> None:
        if self._idle_task is None:
            return
        self._idle_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._idle_task
        self._idle_task = None

    async def _idle_loop(self) -> None:
        while True:
            await asyncio.sleep(self._config.idle_check_interval_seconds)
            try:
                await self.maybe_idle_unload()
            except asyncio.CancelledError:
                raise  # Regulärer Shutdown — nicht verschlucken.
            except Exception:  # noqa: BLE001 - ein Fehlschlag darf den Wächter nicht töten
                # Ohne diesen Guard stürbe der Task lautlos (nie wieder ein Idle-Unload), und
                # ``stop_idle_watcher()`` würfe die gespeicherte Exception beim Herunterfahren
                # aus ``shutdown()`` heraus erneut: ``cancel()`` ist auf einem bereits beendeten
                # Task ein No-op, das anschließende ``await`` re-raist dann.
                _log.exception("Idle-Wächter: Durchlauf fehlgeschlagen — läuft weiter.")

    async def shutdown(self) -> None:
        """Fährt sauber herunter: Wächter stoppen, LLM freigeben."""
        await self.stop_idle_watcher()
        await self.unload()

    # ---- Verarbeitung -------------------------------------------------------

    async def process(
        self, audio: AudioBuffer, mode: Mode, *, language: str | None = None
    ) -> ProcessResult:
        """Audio -> fertiger Text. Serialisiert; wartet auf das STT-Warm-up.

        ``language`` überschreibt für diesen einen Aufruf die Konfiguration (der Client kennt
        den Kontext oft besser als der Default). Ohne Angabe gilt weiter
        ``EngineConfig.language`` — dessen Default ``None`` bedeutet Auto-Detect und ist für
        gemischt Deutsch/Englisch die empfohlene Einstellung.

        Raises:
            StartupFailedError: Wenn das STT-Warm-up gescheitert ist. Das Warten hat dann kein
                Ziel mehr — der Aufrufer bekommt sofort eine klare Absage statt eines Hängers.
        """
        await self._ready.wait()
        if self._startup_error is not None:
            raise StartupFailedError(self._startup_error)
        effective_language = language if language is not None else self._config.language
        async with self._lock:
            self._busy = True
            try:
                self._refiner.reset()
                await self._preload_unlocked()

                result = await to_thread.run_sync(
                    self._run_pipeline, audio, mode, effective_language
                )
                self._last_used = self._clock()

                if self._refiner.last_error is not None:
                    # Der Sanity-Check hat bereits auf den Rohtext zurückgefallen; wir ersetzen
                    # nur seinen generischen Grund ("leerer LLM-Output") durch den echten.
                    result = replace(result, fallback_reason=self._refiner.last_error)
                return result
            finally:
                self._busy = False

    def _run_pipeline(self, audio: AudioBuffer, mode: Mode, language: str | None) -> ProcessResult:
        """Blockierender Teil — läuft im Worker-Thread."""
        return process(
            audio,
            mode,
            transcriber=self._transcriber,
            refiner=self._refiner,
            dictionary=self._dictionary,
            config=PipelineConfig(language=language),
        )

    async def process_stream(
        self,
        audio_chunks: AsyncIterator[np.ndarray],
        mode: Mode,
        *,
        language: str | None = None,
    ) -> ProcessResult:
        """Wie ``process``, aber die Transkription läuft schon **während** des Sprechens.

        Serialisiert (ein Diktat zur Zeit). Das LLM wird parallel zur Transkription geladen, damit
        seine Ladezeit im Sprechen verschwindet. Kann das Backend kein Streaming oder scheitert das
        Streaming, fällt der Aufruf auf den Batch-Weg über das vollständig gepufferte Audio zurück —
        nie ein Diktat verlieren.
        """
        await self._ready.wait()
        if self._startup_error is not None:
            raise StartupFailedError(self._startup_error)
        effective_language = language if language is not None else self._config.language

        async with self._lock:
            self._busy = True
            self._refiner.reset()
            # LLM parallel laden (Gewichte, weitgehend I/O) — überlappt mit der Transkription.
            preload_task = asyncio.create_task(to_thread.run_sync(self._refiner.preload))
            try:
                transcription = await self._consume_stream(audio_chunks, effective_language)
                await preload_task
                self._llm_loaded = self._refiner.last_error is None
                self._last_used = self._clock()
                result = await to_thread.run_sync(
                    self._refine_transcription, transcription, mode, effective_language
                )
                if self._refiner.last_error is not None:
                    result = replace(result, fallback_reason=self._refiner.last_error)
                return result
            finally:
                if not preload_task.done():
                    preload_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError, Exception):
                        await preload_task
                self._busy = False

    async def _consume_stream(
        self, audio_chunks: AsyncIterator[np.ndarray], language: str | None
    ) -> Transcription:
        """Konsumiert die Audio-Häppchen und liefert das Roh-Transkript.

        Streamt, wenn das Backend es kann; sammelt dabei ALLES Audio, um bei einem Streaming-Fehler
        (oder einem reinen Batch-Backend) auf ``transcribe(audio)`` zurückfallen zu können.
        """
        streaming = (
            self._transcriber if isinstance(self._transcriber, StreamingTranscriber) else None
        )
        collected: list[np.ndarray] = []
        if streaming is not None:
            try:
                await to_thread.run_sync(lambda: streaming.stream_begin(language=language))
                async for chunk in audio_chunks:
                    collected.append(chunk)
                    newly = await to_thread.run_sync(streaming.stream_feed, chunk)
                    # Festgeschriebenen Text bereitstellen + loggen (Datenquelle fürs spätere
                    # Overlay; im Motor-Teil noch nicht zum Client durchgereicht — s. Spec §3).
                    if newly:
                        _log.debug("festgeschrieben: %s", newly)
                return await to_thread.run_sync(streaming.stream_finalize)
            except Exception:  # noqa: BLE001 - jeder Streaming-Fehler => Batch-Rückfall
                _log.warning("Streaming fehlgeschlagen — falle auf Batch zurück.")
                async for chunk in audio_chunks:
                    collected.append(chunk)  # evtl. noch nicht konsumierte Häppchen mitnehmen
                return await self._batch_transcribe(collected, language)
        # Reines Batch-Backend: alles sammeln, einmal transkribieren.
        async for chunk in audio_chunks:
            collected.append(chunk)
        return await self._batch_transcribe(collected, language)

    async def _batch_transcribe(
        self, chunks: list[np.ndarray], language: str | None
    ) -> Transcription:
        samples = (np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)).astype(
            np.float32
        )
        audio = AudioBuffer(samples=samples)
        return await to_thread.run_sync(
            lambda: self._transcriber.transcribe(audio, language=language)
        )

    def _refine_transcription(
        self, transcription: Transcription, mode: Mode, language: str | None
    ) -> ProcessResult:
        """Blockierender Teil: Wörterbuch → Refiner → Löschschutz (bestehende Pipeline)."""
        return process_text(
            transcription.text,
            mode,
            refiner=self._refiner,
            dictionary=self._dictionary,
            language=transcription.language or language,
        )
