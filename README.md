# TypeLess

Vollständig lokale KI-Diktier-App für macOS (Apple Silicon).

Fn halten → sprechen → loslassen. Der Text erscheint an der Cursorposition, korrigiert und
interpunktiert. **Keine Cloud, keine APIs, keine Daten verlassen den Rechner.**

Ablauf: Hotkey → lokale Transkription → deterministisches Wörterbuch → Sprachverbesserung (LLM)
→ Einfügen.

## Bedienung

**Fn halten, sprechen, loslassen.** Ein Overlay unten mittig zeigt den Verlauf: Live-Pegel beim
Zuhören, dann Verarbeitung, dann das Ergebnis.

| Anzeige | Bedeutung |
|---|---|
| „Eingefügt" | direkt an der Cursorposition eingefügt |
| „Fertig · ⌘V" + Textvorschau | der Text liegt in der Zwischenablage |
| „Abgebrochen" | verworfen (Taste bei gehaltenem Fn gedrückt) |

Jedes geglückte Diktat landet **zusätzlich** in der Zwischenablage — ein ⌘V rettet den Text, falls
das Einfügen unerwartet verpufft. Preis: vorher Kopiertes wird dabei überschrieben.

**Abbrechen:** bei gehaltenem Fn eine Taste drücken. Kein Ton, nie.

**Voraussetzung:** Systemeinstellungen → Tastatur → „Beim Drücken der 🌐-Taste" → **„Keine
Aktion"**. Steht dort Emoji-Picker, Eingabequelle oder Systemdiktat, öffnet macOS bei jedem
Diktat sein eigenes Fenster. Die App weist im Menü darauf hin, ändert die Einstellung aber nicht
selbst.

### Wohin eingefügt wird

Es wird getippt — außer in vier Fällen, dann geht der Text in die Zwischenablage:

1. Bedienungshilfen nicht erteilt
2. „Sichere Tastatureingabe" aktiv (Terminal, Passwortmanager) — macOS verwirft dann jedes
   synthetische Tastaturereignis
3. eine andere App ist vorne als beim Fn-Druck
4. ein Passwortfeld hat den Fokus

Bedingung 1 und 2 sind keine Vorsicht, sondern Physik: Getipptes käme nicht an, und
`CGEventPost` meldet das nicht zurück.

**Ehrlich benannte Grenzen:** Wechselst du während der Verarbeitung das Feld *innerhalb* derselben
App (⌘L in die Adressleiste), landet der Text im neuen Feld — genau wie beim echten Tippen; er
liegt zusätzlich in der Zwischenablage. Passwortfelder erkennt TypeLess nur, wo die
Bedienungshilfen Auskunft geben; wo nicht, wird hineingetippt. Der Schaden ist asymmetrisch
harmlos: TypeLess tippt **hinein** und liest nie **heraus**.

## Architektur

Native SwiftUI-Shell + Python-MLX-Sidecar, verbunden über einen lokalen Unix-Domain-Socket
(kein TCP-Port). Die Swift-App besitzt Hotkey, Audio, Overlay und das Einfügen; der Sidecar
besitzt STT und Sprachverbesserung. Beide Engines sind hinter Interfaces austauschbar — ein neues
Backend ist eine neue Klasse plus ein Zweig in der Factory.

```
apps/macos/   # SwiftUI-App: Hotkey, Audio, Overlay, Text-Einfügen
engine/       # Python-Sidecar: STT + LLM + Wörterbuch + Pipeline
```

- **STT:** `mlx-whisper` mit `whisper-large-v3-turbo` — Auto-Erkennung für gemischt Deutsch/Englisch.
- **LLM:** `mlx-lm` mit `Qwen3-4B-Instruct-2507-4bit`. Der ursprünglich geplante 3B-Default ist
  **verworfen**: Er löscht im Diktat-Modus reproduzierbar ganze Sätze und formuliert um, auch mit
  verschärftem Prompt. 3B und 7B bleiben konfigurierbar.
- **RAM-Strategie (16 GB):** STT bleibt warm, das LLM wird on-demand geladen (spekulativer Preload
  beim Fn-Druck, Idle-Unload). Nie beide dauerhaft resident.
- **Modi:** Diktat, Prompt, E-Mail, Slack, Brain Dump — je ein versioniertes Prompt-Template.

Ein persönliches Wörterbuch ersetzt vor dem LLM deterministisch Fehlerkennungen
(„Hot Spot" → „HubSpot"): `~/Library/Application Support/TypeLess/dictionary.json`.

## Status

- [x] **M1** Engine-Kern — Interfaces, Wörterbuch, Modi, Pipeline, Sanity-Check, CLI
- [x] **M2** Sidecar-Server — FastAPI über Unix-Domain-Socket, On-Demand-Modell-Lifecycle
- [x] **M3** Swift-Shell — MenuBarExtra, Berechtigungen, startet und beendet den Sidecar
- [x] **M4** Audio + Hotkey — Hold-to-talk über einen mitlesenden CGEventTap auf die Fn-Taste
- [x] **M5** Text-Einfügen — `CGEventKeyboardSetUnicodeString`, inzwischen zur Regel „tippen,
      außer in vier prüfbaren Fällen" umgekehrt; erreicht auch Electron- und WebKit-Editoren
- [x] Diktat-Overlay · Prompt-Prefix-Cache (LLM-Latenz) · Auslieferung mit Sparkle-Selbstupdate
- [ ] **M6** Modi-Umschalter · **M7** Settings-UI · **M8** Polish (Rest)

## Messwerte (Apple Silicon, 16 GB)

| | |
|---|---|
| Speicher idle (STT warm) | 1,5 GB |
| Speicher Peak (STT + LLM) | 3,6 GB |
| Latenz nach dem Loslassen | ~6–7 s für ein typisches Diktat |

Der Prompt-Prefix-Cache spart ~1,3–3,1 s pro Diktat, indem der feste Systemprompt nur einmal
geprefillt wird. Die STT-Zeit ist die Untergrenze und hängt kaum an der Audiolänge — tiefer geht
es nur über Qualitätskompromisse (kleineres Whisper), und die sind bewusst zurückgestellt:
`whisper-small` zerbricht englische Fachbegriffe im deutschen Satz, genau das Code-Switching,
für das `turbo` gewählt wurde.

## Entwicklung

**Engine** (siehe [`engine/README.md`](engine/README.md)):

```bash
cd engine
uv sync --extra dev                  # Kern + Tests, überall lauffähig
uv sync --extra dev --extra mlx      # zusätzlich MLX — nur Apple Silicon
uv run pytest -q                     # Tests mit Mock-Backends, kein Modell nötig
bash ../scripts/check.sh             # black + ruff + mypy(strict) + pytest
```

**macOS-App** (siehe [`apps/macos/README.md`](apps/macos/README.md)):

```bash
# Tests — mit Attrappen, kein Sidecar und kein Modell nötig
cd apps/macos && swift build && swift test

# App bauen — aus dem Repo-Root, nicht aus apps/macos
bash scripts/build-app.sh
open apps/macos/TypeLess.app
```

Das `.app`-Bundle ist nötig, weil macOS Mikrofon- und Bedienungshilfen-Rechte an eine
Bundle-**Identität** vergibt, nicht an ein nacktes Binary. `bash scripts/setup-signing-identity.sh`
legt einmalig eine stabile, selbst-signierte Entwickler-Identität an — danach bleiben die erteilten
Rechte über alle Neubauten erhalten.
