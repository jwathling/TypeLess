"""HTTP-Schicht des Sidecars.

Bewusst dünn: Sie validiert Eingaben und reicht an die ``EngineRuntime`` weiter. Sie hält
keinen Zustand. Die Runtime wird injiziert — deshalb laufen die Tests ohne echte Modelle.

Der Transport ist HTTP über einen Unix-Domain-Socket (siehe ``__main__``): kein Port, keine
Netzwerkschnittstelle. Der Host-Teil der URL ist bedeutungslos.
"""

from __future__ import annotations

import asyncio
import contextlib
from typing import Annotated

import numpy as np
from fastapi import Body, FastAPI, HTTPException, Query, Response
from pydantic import BaseModel
from starlette.types import Lifespan

from ..logging_ import get_logger
from ..models import TARGET_SAMPLE_RATE, AudioBuffer, Mode
from .runtime import EngineRuntime, StartupFailedError

_log = get_logger(__name__)

# Float32 = 4 Byte. Eine Bytelänge, die kein Vielfaches davon ist, kann kein gültiger
# Samplepuffer sein.
_BYTES_PER_SAMPLE = 4


class ModelsResponse(BaseModel):
    state: str  # "missing" | "downloading" | "ready" | "failed"
    downloaded_bytes: int
    total_bytes: int
    error: str | None = None  # Grund, falls ``state == "failed"``


class HealthResponse(BaseModel):
    status: str  # "starting" | "ready" | "failed"
    stt_loaded: bool
    llm_loaded: bool
    busy: bool
    stt_model: str
    llm_model: str
    error: str | None = None  # Grund, falls ``status == "failed"``
    models: ModelsResponse


class ProcessResponse(BaseModel):
    final_text: str
    raw_text: str
    dictionary_text: str
    mode: str
    language: str | None
    refined: bool
    fallback_reason: str | None
    timings_ms: dict[str, float]


def create_app(
    runtime: EngineRuntime,
    *,
    lifespan: Lifespan[FastAPI] | None = None,
) -> FastAPI:
    """Baut die FastAPI-App über einer bereits konstruierten Runtime.

    ``lifespan`` wird an FastAPI durchgereicht (dokumentierte API) — früher setzte
    ``build_app`` stattdessen ``app.router.lifespan_context``, ein Starlette-Internal, das
    bei einem Upgrade still hätte brechen können.
    """
    app = FastAPI(title="TypeLess Sidecar", docs_url=None, redoc_url=None, lifespan=lifespan)

    # Referenzen auf laufende Preload-Tasks. Ohne sie hält nichts den Task am Leben: Der
    # Event-Loop führt nur schwache Referenzen, der Garbage Collector darf einen Task also
    # mitten in der Ausführung einsammeln (so dokumentiert bei ``asyncio.create_task``).
    # Über ``app.state`` erreichbar, damit der Lifespan sie beim Herunterfahren abräumen kann
    # (siehe ``cancel_preload_tasks``) — sonst lüde ein gerade angelaufener ``/preload`` das
    # LLM noch in den sterbenden Prozess.
    preload_tasks: set[asyncio.Task[None]] = set()
    app.state.preload_tasks = preload_tasks

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
            error=state.error,
            models=ModelsResponse(
                state=state.models.state,
                downloaded_bytes=state.models.downloaded_bytes,
                total_bytes=state.models.total_bytes,
                error=state.models.error,
            ),
        )

    @app.post("/preload", status_code=202)
    async def preload() -> Response:
        """Spekulativer Vorlauf beim Hotkey-Druck: startet das Laden und kehrt sofort zurück."""
        task = asyncio.create_task(runtime.preload())
        preload_tasks.add(task)
        task.add_done_callback(preload_tasks.discard)
        return Response(status_code=202)

    @app.post("/models/ensure", status_code=202)
    async def ensure_models() -> Response:
        """Stößt Modell-Sicherung + STT-Warm-up an (auch als „Erneut versuchen" nach Netzfehler).

        Kehrt sofort mit 202 zurück; der Fortschritt läuft über ``/health`` (``models``-Block).
        """
        task = asyncio.create_task(runtime.ensure_ready())
        preload_tasks.add(task)  # hält den Task am Leben, räumt ihn im Lifespan ab (s. /preload)
        task.add_done_callback(preload_tasks.discard)
        return Response(status_code=202)

    @app.post("/unload", response_model=HealthResponse)
    async def unload() -> HealthResponse:
        """Gibt das LLM frei (Swift ruft das bei macOS-Speicherdruck)."""
        await runtime.unload()
        return await health()

    @app.post("/process", response_model=ProcessResponse)
    async def process_audio(
        mode: Annotated[str, Query()],
        # Default ``b""`` statt eines Pflichtfelds: FastAPI liefert für einen komplett
        # leeren Request-Body kein leeres ``bytes``-Objekt, sondern ``None`` (der Body wird
        # nur bei nicht-leerem ``body_bytes`` überhaupt zugewiesen) — ein Pflichtfeld würde
        # das als "fehlt" werten und selbst mit 422 antworten, bevor ``_decode_pcm`` den
        # leeren Puffer sauber mit 400 ablehnen kann.
        audio: Annotated[bytes, Body(media_type="application/octet-stream")] = b"",
        language: Annotated[str | None, Query()] = None,
        sample_rate: Annotated[int, Query()] = TARGET_SAMPLE_RATE,
    ) -> ProcessResponse:
        """Rohes Float32-PCM (16 kHz mono) -> fertiger Text.

        ``language`` ist optional und hat Vorrang vor der Konfiguration; ohne Angabe bleibt es
        beim konfigurierten Wert (Default: Auto-Detect).
        """
        buffer = _decode_pcm(audio, sample_rate)
        try:
            parsed_mode = Mode.from_string(mode)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

        try:
            result = await runtime.process(buffer, parsed_mode, language=language)
        except StartupFailedError as exc:
            # Ein Startfehler ist ein Zustand, kein Verarbeitungsfehler: Der Dienst ist gar nicht
            # erst einsatzbereit geworden. 503 sagt genau das — und sagt dem Client zugleich, dass
            # ein Wiederholen sinnlos ist, solange /health "failed" meldet.
            raise HTTPException(
                status_code=503, detail=f"Sidecar nicht einsatzbereit: {exc}"
            ) from exc
        except Exception as exc:  # noqa: BLE001 - ohne Transkription gibt es nichts zu retten
            _log.exception("Verarbeitung fehlgeschlagen")
            raise HTTPException(
                status_code=500, detail=f"Verarbeitung fehlgeschlagen: {exc}"
            ) from exc

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


async def cancel_preload_tasks(app: FastAPI) -> None:
    """Bricht laufende ``/preload``-Tasks ab und wartet sie aus (Aufruf im Lifespan-``finally``).

    Ohne das gewänne beim Herunterfahren womöglich ``shutdown()`` das Rennen um den Lock,
    während ein gerade angelaufener ``/preload``-Task noch dahinter wartet — er lüde das LLM
    dann in den sterbenden Prozess ("Task was destroyed but it is pending!").
    """
    tasks: set[asyncio.Task[None]] = getattr(app.state, "preload_tasks", set())
    for task in list(tasks):
        task.cancel()
    for task in list(tasks):
        with contextlib.suppress(asyncio.CancelledError):
            await task


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
