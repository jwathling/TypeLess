# M2 — Sidecar-Server (Design)

Datum: 2026-07-11 · Status: freigegeben · Vorgänger: M1 (Engine-Kern, verifiziert)

## Zweck

Die Engine aus M1 ist eine Bibliothek mit CLI. M2 macht sie zu einem dauerhaft laufenden
lokalen Prozess, den die spätere SwiftUI-App (ab M3) ansprechen kann, ohne die Modelle bei
jedem Diktat neu zu laden (Whisper braucht ~14 s zum Laden).

„Server“ meint hier ausschließlich einen **lokalen Hintergrundprozess**. Es wird kein
Netzwerk-Port geöffnet: Die Kommunikation läuft über einen **Unix-Domain-Socket**, also
eine Datei im Dateisystem. Zugangskontrolle sind die Dateirechte. Keine Cloud, keine API,
keine Netzwerkschnittstelle — das Kernversprechen des Projekts bleibt unangetastet.

## Entscheidungen (mit dem Nutzer abgestimmt)

| Frage | Entscheidung | Begründung |
|---|---|---|
| Audio-Transport | **Rohes Float32-PCM als Request-Body** | Kein Encoding-Schritt im heißen Pfad, kein Base64-Overhead (~33 %), nichts, was man falsch kodieren kann. Latenzbudget ist ohnehin knapp. |
| Idle-Unload | **Timer im Sidecar + `/unload`-Endpunkt** | Der Sidecar ist auch allein korrekt (CLI/Test); Swift kann bei macOS-Speicherdruck sofort eingreifen, da nur es diese Meldungen empfängt. |
| Nebenläufigkeit | **Serialisieren (Lock), zweite Anfrage wartet** | MLX-Modelle sind Einzelinstanzen. Kein Diktat geht verloren; Wartezeit im schlimmsten Fall ~6 s. |
| LLM-Ausfall | **200 mit Rohtext + `refined: false`** | Der Text liegt bereits vor; ihn wegzuwerfen wäre der schlechtere Ausgang. Konsistent zum Sanity-Fallback aus M1. |
| Interne Struktur | **Dünne HTTP-Schicht über `EngineRuntime`** | Lebenszyklus ohne HTTP testbar (Mock-Backends, injizierte Uhr). Analog zu M1: Pipeline kennt keine Engines, Runtime kennt kein HTTP. |

Verworfen: eigener Worker-Prozess für die Modelle (YAGNI — löst kein Problem, das wir
haben), Netzwerk-Port (Privacy), Zustand in den FastAPI-Handlern (untestbar).

## Architektur

```
Swift-App ──HTTP über Unix-Domain-Socket──▶ app.py (FastAPI)
                                              │  validiert, kein Zustand
                                              ▼
                                          runtime.py (EngineRuntime)
                                              │  Modelle, Lock, Idle-Timer
                                              ▼
                                          pipeline.process()   [M1, unverändert]
```

Neue Dateien unter `engine/typeless_engine/server/`:

- **`runtime.py`** — `EngineRuntime`: besitzt Transcriber, Refiner, Wörterbuch und den
  Zustand (LLM geladen?, letzte Nutzung, Lock). Baut über die bestehende `factory.py`,
  hängt also weiterhin nur an den Interfaces `Transcriber`/`Refiner`. Kennt kein HTTP.
  Öffentliche Fläche: `startup()`, `preload()`, `process(audio, mode)`, `unload()`,
  `health()`, `shutdown()`.
- **`app.py`** — FastAPI-App. Übersetzt HTTP → Runtime, validiert Eingaben, lagert die
  blockierenden MLX-Aufrufe in einen Worker-Thread aus. Zustandslos.
- **`__main__.py`** — Start: verwaiste Socket-Datei entfernen, uvicorn auf dem UDS starten,
  beim Beenden aufräumen.

`EngineConfig` (bestehend) bekommt zwei Felder: `socket_path`
(Default `~/Library/Application Support/TypeLess/typeless.sock`, also neben dem Wörterbuch
im vorhandenen `APP_SUPPORT_DIR`) und `idle_unload_seconds` (Default 300).

**Blockierende Aufrufe:** uvicorn ist asynchron, MLX blockiert. Würden die Modellaufrufe im
Event-Loop laufen, stünde der Server während einer ~6-s-Verarbeitung still — `/health`
hinge, `/unload` bei Speicherdruck käme nicht durch. Alle Modellaufrufe laufen deshalb in
einem Worker-Thread (`anyio.to_thread.run_sync`).

## API

Alle Endpunkte über den Unix-Domain-Socket. Der Host-Teil der URL ist bedeutungslos.

### `GET /health`

Antwortet **immer sofort**, auch während einer laufenden Verarbeitung.

```json
{
  "status": "starting" | "ready",
  "stt_loaded": true,
  "llm_loaded": false,
  "busy": false,
  "stt_model": "mlx-community/whisper-large-v3-turbo",
  "llm_model": "mlx-community/Qwen3-4B-Instruct-2507-4bit"
}
```

`status` ist `starting`, solange das STT-Modell lädt (~14 s). Swift pollt bis `ready`.

### `POST /preload`

Wird beim **Drücken** des Hotkeys gerufen. Stößt das Laden des LLM im Hintergrund an und
antwortet **sofort** (`202`), ohne auf das Ende zu warten. Idempotent: Ist das Modell
geladen oder lädt bereits, passiert nichts. Während der Nutzer spricht, wird das Modell
fertig (gemessen: 3,9 s) — die Ladezeit verschwindet hinter dem Sprechen.

### `POST /process`

Wird beim **Loslassen** des Hotkeys gerufen.

```
POST /process?mode=diktat[&language=de][&sample_rate=16000]
Content-Type: application/octet-stream

<Float32LE-Samples, 16 kHz, mono>
```

`mode` ist Pflicht und einer aus `diktat|prompt|email|slack|braindump`. `language` ist
optional; fehlt es, gilt Auto-Detect (empfohlen für DE+EN gemischt). `sample_rate` ist
optional (Default 16000) — die Rate steht nicht in den Rohdaten und muss deshalb
mitgeschickt werden, damit die Strenge unten überhaupt prüfbar ist.

Antwort `200` — die Felder spiegeln `ProcessResult` aus M1:

```json
{
  "final_text": "...",
  "raw_text": "...",
  "dictionary_text": "...",
  "mode": "diktat",
  "language": "de",
  "refined": true,
  "fallback_reason": null,
  "timings_ms": {"transcribe": 2600.0, "dictionary": 0.0, "refine": 3500.0}
}
```

Swift braucht im Normalfall nur `final_text`; der Rest dient der Fehlersuche und dem
späteren Overlay.

**Audioformat ist strikt:** genau 16 kHz, Float32, mono. Kein stiller Resample-Fallback —
Swift wandelt bereits mit `AVAudioConverter` um, und ein Automatismus würde nur
verschleiern, wenn die Aufnahmeseite eines Tages kaputtgeht.

**Während `status: starting`:** `/process` wird nicht abgelehnt, sondern **wartet**, bis das
STT warm ist, und verarbeitet dann normal. Der Regelfall ist ohnehin, dass Swift bis `ready`
pollt, bevor es den Hotkey scharf schaltet; wer trotzdem früher anfragt, soll sein Diktat
nicht verlieren — dieselbe Begründung wie beim LLM-Fallback.

### `POST /unload`

Gibt das LLM sofort frei. Wird von Swift bei macOS-Speicherdruck gerufen
(`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`). Antwortet mit dem neuen Zustand. Wartet, falls
gerade verarbeitet wird — ein Unload darf nie in eine laufende Generierung fallen.

## Fehlerverhalten

| Fall | Antwort | Begründung |
|---|---|---|
| Unbekannter Modus | `400` | Validierung vor jedem Modellzugriff. |
| Leerer Body | `400` | — |
| Bytelänge kein Vielfaches von 4 | `400` | Keine gültigen Float32-Samples. |
| `sample_rate` ≠ 16000 | `400` | Kein stiller Resample-Fallback. |
| **LLM scheitert** (Laden oder Generierung) | **`200`**, `refined: false`, `fallback_reason` gesetzt, `final_text` = wörterbuch-bereinigter Rohtext | Der Text liegt vor. Ihn wegzuwerfen wäre der schlechtere Ausgang. |
| **STT scheitert** | `500` | Es gibt keinen Text, den man retten könnte. Swift zeigt den Fehler im Overlay. |

## Lebenszyklus

1. **Start:** STT wird warm geladen (~14 s, 1,51 GB). `/health` meldet solange `starting`.
2. **LLM on-demand:** geladen durch `/preload` (Regelfall) oder notgedrungen innerhalb von
   `/process`, falls kein Preload kam.
3. **Idle-Unload:** Ein Hintergrund-Task prüft periodisch die Zeit seit der letzten Nutzung.
   Nach `idle_unload_seconds` (Default 300) wird das LLM entladen. **Das STT bleibt warm** —
   es ist latenzkritisch und mit 1,51 GB bezahlbar.
4. **Speicherdruck:** `/unload` entlädt sofort.
5. **Ende:** Sauberes Herunterfahren, Socket-Datei wird entfernt.

Der Lock serialisiert `process` und `unload` gegeneinander. Gemessenes Speicherprofil aus
M1: idle 1,51 GB (nur STT), Peak 3,62 GB (STT + LLM), nach Unload wieder 1,51 GB.

## Tests

**Alle Tests laufen ohne echte Modelle** — mit den Mock-Backends aus M1, gegen `httpx`. Kein
MLX, kein Download, Laufzeit im Millisekundenbereich. Genau dafür kennt die Runtime kein
HTTP und baut über die Factory.

*Runtime (ohne HTTP):*
- `startup()` macht das STT warm.
- `preload()` ist idempotent (mehrfacher Aufruf lädt nicht doppelt).
- `process()` funktioniert auch ohne vorheriges `preload()`.
- `process()` vor dem Ende von `startup()` wartet, statt zu scheitern.
- Zwei gleichzeitige `process()`-Aufrufe werden serialisiert; beide erhalten ihr korrektes
  Ergebnis.
- Idle-Unload schlägt nach Ablauf der Frist zu — mit **injizierter Uhr**, nicht mit echtem
  Warten.
- `unload()` wartet, wenn gerade verarbeitet wird (zieht dem Refiner nicht das Modell weg).

*HTTP-Schicht:*
- `/health` spiegelt den Zustand und antwortet **auch während einer Verarbeitung** sofort
  (verifiziert die Worker-Thread-Auslagerung).
- `/process` übersetzt rohes PCM korrekt in einen `AudioBuffer`.
- Unbekannter Modus / leerer Body / krumme Bytelänge → je `400`, ohne Modellzugriff.
- LLM-Ausfall → `200` mit `refined: false`; STT-Ausfall → `500`.

*Socket (nicht mockbar):*
- Server auf einem echten UDS im Temp-Verzeichnis starten und darüber sprechen.
- Verwaiste Socket-Datei wird beim Start weggeräumt.

**Handprobe (aus dem Plan):**

```bash
curl --unix-socket ~/Library/Application\ Support/TypeLess/typeless.sock http://x/health
curl --unix-socket ... --data-binary @memo.pcm -H 'Content-Type: application/octet-stream' \
     'http://x/process?mode=diktat'
```

## Nicht Teil von M2

Keine Authentifizierung (Dateirechte des Sockets sind die Zugangskontrolle), kein
Mehrbenutzerbetrieb, keine Prioritäts-Warteschlange, kein Streaming (v1 transkribiert beim
Loslassen; Streaming ist laut Plan frühestens M8). Ein Nutzer, ein Diktat zur Zeit.
