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
