# TypeLess — Projektkontext für Claude Code

Vollständig lokale KI-Diktier-App für macOS (Apple Silicon, 16 GB RAM). Ziel: qualitativ
mit Superwhisper/Voicely konkurrieren. Ablauf: Hotkey (Hold-to-talk) → sprechen → lokale
Transkription → deterministisches Wörterbuch → LLM-Sprachverbesserung → Einfügen an der
Cursorposition. **Keine Cloud, keine APIs, keine Daten verlassen den Rechner.**

## Architektur

Native **SwiftUI-Shell** (Hotkey, Audio, Overlay, Text-Einfügen) + **Python-MLX-Sidecar**
(STT + LLM), verbunden über einen lokalen **Unix-Domain-Socket** (kein TCP).

```
apps/macos/   # SwiftUI-App: Hotkey, Audio, Overlay, Einfügen, Settings   (M3 fertig, nur macOS)
engine/       # Python-Sidecar: STT + LLM + Wörterbuch + Pipeline          (M1 fertig)
```

`apps/macos/` (Swift-Package mit drei Targets, s. `apps/macos/README.md`):

```
Sources/TypeLessCore/     # Bibliothek ohne jede UI (kein SwiftUI-/AppKit-UI-Import), daher
                          # vollständig testbar ohne ein Fenster zu öffnen.
  Sidecar/                # HTTPUnixTransport, SidecarClient, SidecarLifecycle (UDS zur Engine)
  Permissions/             # PermissionsService (Mikrofon/Bedienungshilfen/Eingabeüberwachung)
  Settings/                 # SettingsStore (engineDirectory/socketPath/uvPath, UserDefaults)
  AppState.swift            # @MainActor @Observable Zustandsautomat — das Bindeglied zur UI
Sources/TypeLess/          # Dünne SwiftUI-Hülle (MenuBarExtra) — zeigt nur an, was AppState
                          # sagt, enthält selbst keine Logik. TypeLessApp.swift (Komposition +
                          # App-Delegate für Start/Beenden), MenuContent.swift (Menüinhalt).
Tests/TypeLessCoreTests/  # 43 Tests (Swift Testing), reine Mocks/Fakes — kein echter Sidecar
                          # nötig.
```

Engine-Datenfluss:
```
Audio ──Transcriber──▶ Rohtext ──Wörterbuch──▶ bereinigt ──Refiner(LLM)──▶ Sanity-Check
                                                            ok ? LLM-Text : bereinigter Rohtext
```

## Kernentscheidungen (verbindlich)

- **STT:** `mlx-whisper` mit `whisper-large-v3-turbo` (Auto-Detect für DE+EN gemischt).
- **LLM:** `mlx-lm` mit `Qwen3-4B-Instruct-2507-4bit` als **Default**. Der ursprünglich
  geplante 3B-Default ist **verworfen**: Er löscht im Diktat-Modus reproduzierbar ganze
  Sätze und formuliert um — auch mit verschärftem Prompt (in M1 gemessen). 3B/7B bleiben
  über `EngineConfig` wählbar.
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

uv run python -m typeless_engine.server   # Sidecar starten (UDS, siehe engine/README.md)

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

## macOS-Shell entwickeln & testen

```bash
cd apps/macos
swift build && swift test        # 43 Tests (Swift Testing), reine Mocks — kein Sidecar nötig

bash scripts/build-app.sh        # baut TypeLess.app aus dem Repo-Root (relativer Pfad ab dort)
open apps/macos/TypeLess.app
```

`scripts/build-app.sh` erzeugt ein echtes `.app`-Bundle (macOS vergibt Mikrofon-/
Accessibility-Rechte an eine Bundle-Identität, nicht an ein nacktes Binary) und signiert es
**ad-hoc** (`codesign --sign -`) — für den persönlichen Gebrauch ausreichend, aber die
Signatur-Identität wechselt bei jedem Neubau. macOS kann deshalb nach einem Neubau **erneut**
nach Mikrofon-/Accessibility-/Eingabeüberwachungs-Rechten fragen. Ein echtes Zertifikat gibt es
erst in M8.

Die App startet den Sidecar selbst (spekulativ übernimmt sie eine bereits laufende Instanz statt
eine zweite zu spawnen) und beendet einen selbst gestarteten Sidecar beim Beenden wieder mit —
egal ob über den Menü-Button, Cmd+Q oder „Beenden“ im Dock (`applicationShouldTerminate` in
`TypeLessApp.swift` fängt **jeden** dieser Wege ab, s. Kommentar dort).

## Aktueller Stand

- [x] **M1** — Engine-Kern: Interfaces, Wörterbuch, Modi (Diktat/Prompt/Email/Slack/
  BrainDump), Pipeline + Sanity-Check (Länge **und** Divergenz), MLX-Backends (lazy) +
  Mocks, CLI. 41 Tests grün, ruff/mypy(strict)/black sauber.
- [x] **M1 auf echten Modellen verifiziert** (Apple Silicon, s. „Messwerte" unten).
- [x] **M2** — Sidecar-Server: FastAPI/uvicorn über **Unix-Domain-Socket** (kein TCP-Port).
  `engine/typeless_engine/server/`: `runtime.py` (Modelle, Lock, Idle-Unload — kennt kein
  HTTP), `app.py` (dünne HTTP-Schicht, zustandslos), `__main__.py` (Start, Socket-Hygiene).
  86 Tests grün, gegen echte Modelle über den Socket verifiziert.
  - `GET /health` → `starting|ready`, antwortet **immer sofort** (auch während der
    Verarbeitung; Modellaufrufe laufen im Worker-Thread).
  - `POST /preload` → `202` nach ~1 ms, lädt das LLM im Hintergrund (Hotkey-**Druck**).
  - `POST /process?mode=…[&language=…][&sample_rate=16000]` → rohes Float32-PCM als Body
    (16 kHz mono), liefert `ProcessResult` als JSON (Hotkey-**Loslassen**).
  - `POST /unload` → LLM sofort freigeben (macOS-Speicherdruck).
  - **Fehlerverhalten:** LLM-Ausfall → `200` mit `refined: false` + Rohtext (Diktat geht nie
    verloren). STT-Ausfall → `500`. Ungültige Eingabe → `400`, bevor ein Modell lädt.
  - Verarbeitung ist **serialisiert** (Lock); ein Unload fällt nie in eine laufende
    Generierung. Socket-Datei wird beim Start/Ende aufgeräumt; ein **lebender** Sidecar wird
    per `connect()`-Probe erkannt und nicht überschrieben.
- [x] **M3** — Swift-Shell: `TypeLessCore` (HTTP-Transport über UDS, `SidecarClient`,
  `SidecarLifecycle` — übernimmt einen laufenden Sidecar oder startet ihn selbst,
  `PermissionsService`, `SettingsStore`, `AppState` als `@MainActor @Observable`-
  Zustandsautomat) + dünne `MenuBarExtra`-Oberfläche (`LSUIElement`, kein Dock-Icon). 43 Tests
  grün, **gegen die echte Engine verifiziert** (Selbststart, Übernahme einer laufenden Instanz,
  Fehlerfall bei fehlendem Engine-Verzeichnis — je über Prozesstabelle und Menü-Text belegt).
  Beenden über Menü-Button, Cmd+Q **und** Dock laufen alle durch denselben
  `applicationShouldTerminate`-Pfad — kein verwaister Sidecar.
- [ ] **M4** Audio+Hotkey+Overlay · **M5** Einfügen · **M6** Modi-Umschalter · **M7**
  Settings-UI · **M8** Polish/Packaging.

## Messwerte (M1, Apple Silicon, 16 GB)

Speicher laut MLX-API (`mx.get_active_memory()`; **RSS ist irreführend**, da MLX die
Gewichte per mmap lädt):

| Zustand | Speicher | Plan-Annahme |
|---|---|---|
| Idle (nur STT warm) | **1,51 GB** | 2,0–2,5 GB |
| Peak (STT + LLM 4B) | **3,62 GB** | 4,0–4,5 GB |
| Nach LLM-Unload | 1,51 GB | — |

Latenz: STT ≈ **0,17× Echtzeit** (48 s Audio → 8,4 s). LLM-Preload 3,9 s (gecacht),
Refine 3,2–3,6 s. Für ein 15-s-Diktat also grob 2,6 s STT + ~3,5 s LLM. Das Planziel von
2–4 s nach dem Loslassen wird damit **nicht** erreicht (eher 6 s); der spekulative Preload
verdeckt nur die Ladezeit, nicht die Generierung. Optimierung → M8.

## Konventionen

- Python 3.11+, Typannotationen überall, `from __future__ import annotations`.
- Tooling: ruff + black (line-length 100), mypy **strict**, pytest. Vor Commits
  `scripts/check.sh` grün halten.
- Kommentare/Docstrings auf Deutsch (bestehendem Stil folgen).
- MLX-Imports immer **lazy** (nur bei Nutzung), damit der Kern plattformunabhängig bleibt.
- Iterativ arbeiten: jeder Meilenstein bleibt lauffängig. Commit/Push nur auf Ansage.
