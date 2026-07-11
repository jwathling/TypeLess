# TypeLess — Projektkontext für Claude Code

Vollständig lokale KI-Diktier-App für macOS (Apple Silicon, 16 GB RAM). Ziel: qualitativ
mit Superwhisper/Voicely konkurrieren. Ablauf: Hotkey (Hold-to-talk) → sprechen → lokale
Transkription → deterministisches Wörterbuch → LLM-Sprachverbesserung → Einfügen an der
Cursorposition. **Keine Cloud, keine APIs, keine Daten verlassen den Rechner.**

## Architektur

Native **SwiftUI-Shell** (Hotkey, Audio, Overlay, Text-Einfügen) + **Python-MLX-Sidecar**
(STT + LLM), verbunden über einen lokalen **Unix-Domain-Socket** (kein TCP).

```
apps/macos/   # SwiftUI-App: Hotkey, Audio, Overlay, Einfügen, Settings   (ab M3, nur macOS)
engine/       # Python-Sidecar: STT + LLM + Wörterbuch + Pipeline          (M1 fertig)
```

Engine-Datenfluss:
```
Audio ──Transcriber──▶ Rohtext ──Wörterbuch──▶ bereinigt ──Refiner(LLM)──▶ Sanity-Check
                                                            ok ? LLM-Text : bereinigter Rohtext
```

## Kernentscheidungen (verbindlich)

- **STT:** `mlx-whisper` mit `whisper-large-v3-turbo` (Auto-Detect für DE+EN gemischt).
- **LLM:** `mlx-lm` mit `Qwen2.5-3B-Instruct-4bit` als **Default** (leicht wegen RAM);
  Qwen3-4B / 7B als opt-in Qualitätsstufen über `EngineConfig`.
- **RAM-Strategie (16 GB):** STT warm halten, LLM **on-demand** (spekulativer Preload beim
  Hotkey-Druck + Idle-Unload + Memory-Pressure-Handling). Nie beide dauerhaft resident.
- **Text-Einfügen (ab M5):** primär `CGEventKeyboardSetUnicodeString` (universell, **ohne
  Clipboard**), AX-API optional, Clipboard nur als letzter Fallback.
- **Hotkey:** `KeyboardShortcuts` (Sindre Sorhus) + CGEventTap für Hold-to-talk.

## Austauschbarkeit (wichtiges Prinzip)

Der Kern hängt **ausschließlich** an den Interfaces `interfaces/transcriber.py`
(`transcribe(audio) -> Transcription`) und `interfaces/refiner.py`. Die **einzige** Stelle,
die konkrete Engines kennt, ist `factory.py`. Ein neues Backend (z. B. whisper.cpp) =
neue Klasse + ein Zweig in der Factory, sonst nichts. Diesen Vertrag nicht aufweichen.

## Engine entwickeln & testen

```bash
cd engine
uv sync --extra dev                  # Kern + Tests (überall lauffähig)
uv sync --extra dev --extra mlx      # zusätzlich MLX — NUR Apple Silicon

uv run pytest -q                     # Tests (Mock-Backends, kein Modell nötig)
bash ../scripts/check.sh             # black + ruff + mypy(strict) + pytest

# Mock-Pfad (ohne Modelle):
uv run typeless dict "wir nutzen hot spot"
uv run typeless refine "text" --mode diktat --llm mock --show-stages

# Echter Pfad (Apple Silicon, lädt Modelle beim 1. Lauf):
uv run typeless refine "hot spot ist mega" --mode diktat --show-stages
uv run typeless transcribe test.wav --mode diktat --show-stages
# WAV erzeugen aus Sprachmemo (.m4a):
#   afconvert -f WAVE -d LEI16@16000 -c 1 memo.m4a test.wav
```

Persönliches Wörterbuch (deterministisch, vor dem LLM): JSON unter
`~/Library/Application Support/TypeLess/dictionary.json` (Default-Pfad), Beispiel in
`engine/examples/dictionary.example.json`.

## Aktueller Stand

- [x] **M1** — Engine-Kern: Interfaces, Wörterbuch, Modi (Diktat/Prompt/Email/Slack/
  BrainDump), Pipeline + Sanity-Check, MLX-Backends (lazy) + Mocks, CLI. 32 Tests grün,
  ruff/mypy(strict)/black sauber. Commit `7880cb6`, gemerged auf `main`.
- [ ] **M2** — Sidecar-Server: FastAPI/uvicorn über **Unix-Domain-Socket**, Endpunkte
  `/health`, `/preload` (LLM vorladen), `/process` (PCM+Modus → Text), `/unload`.
  STT warm beim Start, LLM on-demand. Logging.
- [ ] **M3** Swift-Shell · **M4** Audio+Hotkey+Overlay · **M5** Einfügen · **M6** Modi-
  Umschalter · **M7** Settings-UI · **M8** Polish/Packaging.

## Bekannte offene Verifikation

⚠️ **`mlx_lm.generate`-API** in `engine/typeless_engine/llm/mlx_refiner.py` ist gegen die
tatsächlich installierte `mlx-lm`-Version zu prüfen (Signatur `sampler=` vs. `temp=` hat
sich zwischen Versionen geändert). Bei Fehlern zu `sampler`/`make_sampler`/`generate()`:
Signatur an die installierte Version anpassen (`uv pip show mlx-lm`).

## Konventionen

- Python 3.11+, Typannotationen überall, `from __future__ import annotations`.
- Tooling: ruff + black (line-length 100), mypy **strict**, pytest. Vor Commits
  `scripts/check.sh` grün halten.
- Kommentare/Docstrings auf Deutsch (bestehendem Stil folgen).
- MLX-Imports immer **lazy** (nur bei Nutzung), damit der Kern plattformunabhängig bleibt.
- Iterativ arbeiten: jeder Meilenstein bleibt lauffängig. Commit/Push nur auf Ansage.
