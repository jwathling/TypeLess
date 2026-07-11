# TypeLess

Vollständig lokale KI-Diktier-App für macOS (Apple Silicon).

Hotkey → Sprechen → lokale Transkription → deterministisches Wörterbuch →
Sprachverbesserung (LLM) → Einfügen an der Cursorposition.
Keine Cloud, keine APIs, keine Daten verlassen den Rechner.

## Architektur

Native SwiftUI-Shell + Python-MLX-Sidecar, verbunden über einen lokalen Unix-Domain-Socket.
Die Swift-App besitzt Hotkey, Audio, Overlay und das Einfügen; der Sidecar besitzt STT +
Sprachverbesserung. Beide Engines sind hinter Interfaces austauschbar.

```
apps/macos/   # SwiftUI-App: Hotkey, Audio, Overlay, Text-Einfügen, Settings   (ab M3)
engine/       # Python-Sidecar: STT + LLM + Wörterbuch + Pipeline               (M1 ✅)
```

- **STT:** `mlx-whisper` mit `whisper-large-v3-turbo` (Apple Silicon).
- **LLM:** `mlx-lm` mit `Qwen2.5-3B-Instruct-4bit` (Default), größere Modelle opt-in.
- **RAM-Strategie (16 GB):** STT warm, LLM on-demand (spekulativer Preload + Idle-Unload).

## Status (iterative Meilensteine)

- [x] **M1** — Python-Engine-Kern (headless, testbar): Interfaces, Wörterbuch, Modi,
  Pipeline, Sanity-Check, MLX-Backends (lazy), CLI, Tests.
- [ ] **M2** — Sidecar-Server (FastAPI/UDS, On-Demand-Modell-Lifecycle).
- [ ] **M3** — Swift-Shell-Skelett (MenuBarExtra, Berechtigungen, startet Sidecar).
- [ ] **M4** — Audio + Hotkey (Hold-to-talk) + Overlay.
- [ ] **M5** — Text-Einfügen (CGEvent-Unicode + AX-Fallback).
- [ ] **M6** — Modi-Umschalter · **M7** — Settings-UI · **M8** — Polish/Packaging.

## Engine-Entwicklung

Siehe [`engine/README.md`](engine/README.md). Kurzform:

```bash
cd engine
uv sync --extra dev                 # überall (Kern + Tests)
uv run pytest -q                    # Tests (Mock-Backends)
uv run typeless dict "hot spot"     # deterministische Wörterbuch-Ersetzung

# Auf Apple Silicon zusätzlich:
uv sync --extra dev --extra mlx
uv run typeless transcribe sample.wav --mode diktat --show-stages
```
