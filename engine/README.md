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
- `llm/` — `MLXRefiner` (Apple Silicon, `Qwen3-4B-Instruct-2507-4bit`) + Mock-Refiner.
- `dictionary/` — deterministische Phrasen-Ersetzung (keine KI), vor dem LLM.
- `modes/` — Prompt-Definitionen: Diktat, Prompt, E-Mail, Slack, Brain Dump.
- `pipeline/` — Orchestrierung + Sanity-Check (Länge **und** Divergenz → Halluzinations-Fallback).
- `server/` — Sidecar: `EngineRuntime` (Modelle, Lock, Idle-Unload) + FastAPI über Unix-Socket.
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

## Sidecar (M2)

Lokaler Hintergrundprozess, den die Swift-App ab M3 anspricht. **Kein TCP-Port:** Die
Kommunikation läuft über einen Unix-Domain-Socket, also eine Datei
(`~/Library/Application Support/TypeLess/typeless.sock`, Verzeichnis `0700`). Es gibt keine
Netzwerkschnittstelle; Zugangskontrolle sind die Dateirechte.

```bash
uv run python -m typeless_engine.server        # startet den Sidecar
```

Beim Start lädt das STT-Modell warm (~15–25 s); `/health` meldet solange `starting` und
antwortet trotzdem sofort. Das LLM wird erst bei Bedarf geladen und nach 5 Minuten
Untätigkeit wieder entladen (RAM-Budget: 1,51 GB idle, 3,62 GB Peak).

```bash
SOCK=~/Library/Application\ Support/TypeLess/typeless.sock

curl --unix-socket "$SOCK" http://x/health
# {"status":"ready","stt_loaded":true,"llm_loaded":false,...}

curl -X POST --unix-socket "$SOCK" http://x/preload   # 202 sofort; lädt im Hintergrund
curl -X POST --unix-socket "$SOCK" http://x/unload    # LLM freigeben (Speicherdruck)

# Diktat: roher Float32-PCM-Body, 16 kHz mono. WAV -> PCM:
uv run python -c "from typeless_engine.audio import load_wav; \
  load_wav('memo.wav').samples.astype('<f4').tofile('memo.pcm')"

curl --unix-socket "$SOCK" -H 'Content-Type: application/octet-stream' \
     --data-binary @memo.pcm 'http://x/process?mode=diktat'
# {"final_text":"...","refined":true,"timings_ms":{...}}
```

Fällt das **LLM** aus, liefert `/process` trotzdem `200` mit `refined: false` und dem
wörterbuch-bereinigten Rohtext — ein Diktat geht nie verloren. Fällt das **STT** aus, gibt
es nichts zu retten: `500`.

## Tests

```bash
uv run pytest              # alle Tests (Mock-Backends, kein Modell nötig)
uv run pytest -m slow      # echte MLX-Modelle (nur Apple Silicon)
```
