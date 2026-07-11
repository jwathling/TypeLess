"""Headless-CLI der Engine.

Erlaubt das Ausführen der Pipeline ohne GUI/Sidecar — ideal zum Testen der ML-Bausteine
auf dem Mac und der übrigen Logik plattformunabhängig (mit ``--stt/--llm mock``).

Beispiele:
    uv run typeless transcribe sample.wav --mode diktat
    uv run typeless refine "hot spot ist super" --mode diktat --llm mock
    uv run typeless dict "wir nutzen hot spot und sales force"
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import typer

from .audio import load_wav
from .config import Backend, EngineConfig
from .factory import build_dictionary, build_refiner, build_transcriber
from .logging_ import configure_logging, get_logger
from .models import Mode, ProcessResult
from .pipeline import process, process_text

app = typer.Typer(add_completion=False, help="TypeLess-Engine (STT + Sprachverbesserung).")
_log = get_logger(__name__)


def _config(stt: Backend | None, llm: Backend | None, dictionary: Path | None) -> EngineConfig:
    overrides: dict[str, Any] = {}
    if stt is not None:
        overrides["stt_backend"] = stt
    if llm is not None:
        overrides["llm_backend"] = llm
    if dictionary is not None:
        overrides["dictionary_path"] = dictionary
    return EngineConfig(**overrides)


@app.command()
def transcribe(
    file: Path = typer.Argument(..., exists=True, dir_okay=False, help="WAV-Datei."),
    mode: str = typer.Option("diktat", "--mode", "-m", help="Ausgabemodus."),
    stt: Backend | None = typer.Option(None, help="STT-Backend (Default: Config)."),
    llm: Backend | None = typer.Option(None, help="LLM-Backend (Default: Config)."),
    dictionary: Path | None = typer.Option(None, help="Pfad zum Wörterbuch-JSON."),
    show_stages: bool = typer.Option(False, help="Zwischenschritte + Timings ausgeben."),
) -> None:
    """Transkribiert eine WAV-Datei und verbessert den Text im gewählten Modus."""
    configure_logging()
    cfg = _config(stt, llm, dictionary)
    audio = load_wav(file)
    result = process(
        audio,
        Mode.from_string(mode),
        transcriber=build_transcriber(cfg),
        refiner=build_refiner(cfg),
        dictionary=build_dictionary(cfg),
    )
    _emit(result, show_stages)


@app.command()
def refine(
    text: str = typer.Argument(..., help="Rohtext (statt Audio)."),
    mode: str = typer.Option("diktat", "--mode", "-m", help="Ausgabemodus."),
    llm: Backend | None = typer.Option(None, help="LLM-Backend (Default: Config)."),
    dictionary: Path | None = typer.Option(None, help="Pfad zum Wörterbuch-JSON."),
    show_stages: bool = typer.Option(False, help="Zwischenschritte ausgeben."),
) -> None:
    """Wendet Wörterbuch + Sprachverbesserung auf einen gegebenen Text an (ohne STT)."""
    configure_logging()
    cfg = _config(None, llm, dictionary)
    result = process_text(
        text,
        Mode.from_string(mode),
        refiner=build_refiner(cfg),
        dictionary=build_dictionary(cfg),
        language=cfg.language,
    )
    _emit(result, show_stages)


@app.command("dict")
def apply_dictionary(
    text: str = typer.Argument(..., help="Text, auf den das Wörterbuch angewendet wird."),
    dictionary: Path | None = typer.Option(None, help="Pfad zum Wörterbuch-JSON."),
) -> None:
    """Wendet nur die deterministische Wörterbuch-Ersetzung an."""
    configure_logging()
    cfg = _config(None, None, dictionary)
    engine = build_dictionary(cfg)
    typer.echo(engine.apply(text))


def _emit(result: ProcessResult, show_stages: bool) -> None:
    if show_stages:
        typer.echo(f"[roh]        {result.raw_text}")
        typer.echo(f"[wörterbuch] {result.dictionary_text}")
        typer.echo(f"[modus]      {result.mode.value}  (refined={result.refined})")
        if result.fallback_reason:
            typer.echo(f"[fallback]   {result.fallback_reason}")
        if result.timings_ms:
            timings = "  ".join(f"{k}={v}ms" for k, v in result.timings_ms.items())
            typer.echo(f"[timings]    {timings}")
        typer.echo("[final]")
    typer.echo(result.final_text)


if __name__ == "__main__":
    app()
