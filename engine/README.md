# TypeLess Engine

Headless STT- + LLM-Pipeline für die TypeLess-Diktier-App. Läuft ohne GUI und ist über
klare Interfaces von den konkreten Backends (MLX, Mock, später whisper.cpp) entkoppelt.

## Architektur

```
Audio ──Transcriber──▶ Rohtext ──Wörterbuch──▶ bereinigt ──Refiner(LLM)──▶ Sanity-Check
                                                                               │
                                                       ok ? LLM-Text : bereinigter Rohtext
```

- `interfaces/` — abstrakte `Transcriber` (`transcribe(audio) -> Transcription`) und `Refiner`.
- `stt/` — `MLXWhisperTranscriber` (Apple Silicon, `whisper-large-v3-turbo`) + `MockTranscriber`.
- `llm/` — `MLXRefiner` (Apple Silicon, `Qwen2.5-3B-Instruct-4bit`) + Mock-Refiner.
- `dictionary/` — deterministische Phrasen-Ersetzung (keine KI), vor dem LLM.
- `modes/` — Prompt-Definitionen: Diktat, Prompt, E-Mail, Slack, Brain Dump.
- `pipeline/` — Orchestrierung + Sanity-Check (Halluzinations-Fallback).
- `factory.py` — einzige Stelle, die konkrete Backends kennt (DI aus `config.py`).

## Setup

```bash
uv sync --extra dev            # Kern + Dev-Tools (überall)
uv sync --extra dev --extra mlx  # zusätzlich MLX — NUR auf Apple Silicon
```

## Nutzung (CLI)

```bash
# Plattformunabhängig (Mock-Backends, kein Modell nötig):
uv run typeless dict "wir nutzen hot spot und sales force"
uv run typeless refine "hot spot ist super" --mode diktat --llm mock --show-stages

# Auf dem Mac mit echten Modellen:
uv run typeless transcribe sample.wav --mode diktat --show-stages
```

## Tests

```bash
uv run pytest              # schnelle Tests (Mock-Backends)
uv run pytest -m slow      # echte MLX-Modelle (nur Apple Silicon)
```
