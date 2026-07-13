# M3 — Swift-Shell-Skelett (Design)

Datum: 2026-07-13 · Status: freigegeben · Vorgänger: M2 (Sidecar-Server, auf `main`)

## Zweck

Die Engine läuft (M1) und ist als lokaler Sidecar über einen Unix-Domain-Socket ansprechbar
(M2). M3 baut die native Hülle: eine SwiftUI-**MenuBarExtra**-App, die den Sidecar startet,
seinen Zustand kennt und ihn verständlich anzeigt.

**M3 kann noch nicht zuhören.** Kein Hotkey, keine Aufnahme, kein Einfügen — das sind M4/M5.
M3 ist das Fundament: Die App bringt die Engine zuverlässig hoch, weiß jederzeit, wie es ihr
geht, und sagt es dem Nutzer.

## Entscheidungen (mit dem Nutzer abgestimmt)

| Frage | Entscheidung | Begründung |
|---|---|---|
| Build-Setup | **Swift Package Manager + Bundle-Skript**, kein Xcode | Xcode ist auf dem Rechner nicht installiert; verifiziert, dass SwiftUI, `MenuBarExtra`, AVFoundation und die AX-API mit den Command Line Tools (Swift 6.3.3, SDK 26.5) bauen. Alles bleibt textbasiert, versionierbar und automatisierbar. |
| Sidecar-Start | **Laufende Instanz übernehmen, sonst selbst starten** | Beim Entwickeln spart das die ~20 s Warm-up. Eine übernommene Instanz wird **nicht** beendet — wer sie gestartet hat, beendet sie. |
| Berechtigungen | **Nur anzeigen + Systemeinstellungen öffnen** | M3 braucht noch keine. macOS fragt ohnehin erst beim ersten echten Zugriff (Mikrofon in M4, Accessibility in M5). Der Status-Anzeige wegen: Der Nutzer soll sehen, was kommt, statt später vor einer stummen App zu stehen. |
| HTTP über den Socket | **Selbstgebauter Client über `NWConnection`** | `URLSession` kann keine Unix-Sockets. `NWEndpoint.unix(path:)` existiert (verifiziert). Vier Endpunkte, kleine JSON-Antworten, **beide Seiten unter unserer Kontrolle** → kein fremdes HTTP, das uns überrascht. Keine Fremdabhängigkeit in einer App, deren Kernversprechen „nichts verlässt den Rechner" ist. |

Verworfen: **AsyncHTTPClient/SwiftNIO** — ausgereifter, aber zieht ein Dutzend Pakete in eine
App, die vier JSON-Aufrufe macht. Der Wechsel bleibt möglich: Der Client steckt hinter einem
Protokoll, ein Austausch ist ein isolierter Eingriff.

## Architektur

```
apps/macos/
├── Package.swift
├── Sources/
│   ├── TypeLessCore/          # Bibliothek: Protokolle + Implementierungen. KEINE UI.
│   │   ├── Sidecar/           #   SidecarClient (HTTP über UDS), SidecarLifecycle
│   │   ├── Permissions/       #   PermissionsService
│   │   ├── Settings/          #   SettingsStore
│   │   └── AppState.swift     #   beobachtbarer Zustand (Vorläufer des RecordingCoordinator)
│   └── TypeLess/              # ausführbar: SwiftUI MenuBarExtra. Dünn.
└── Tests/TypeLessCoreTests/
```

Die Trennung spiegelt die der Engine: Die **Bibliothek kennt keine UI**, deshalb läuft
`swift test` gegen sie, ohne je ein Fenster zu öffnen. Das ausführbare Ziel zeigt nur an,
was `AppState` sagt.

### Warum ein `.app`-Bundle nötig ist

macOS vergibt Mikrofon- und Accessibility-Rechte an eine **Bundle-Identität**, nicht an ein
nacktes Binary. Ohne `.app` würden die Rechte dem Terminal erteilt statt TypeLess — und beim
Diktieren später ins Leere greifen. `scripts/build-app.sh` erzeugt das Bundle: Struktur
anlegen, `Info.plist` schreiben (`LSUIElement` = kein Dock-Icon, `NSMicrophoneUsageDescription`),
ad-hoc signieren. Es ist der einzige Ort, der Bundle-Interna kennt.

**Bekannte Grenze:** Bei Ad-hoc-Signatur ändert sich die Identität mit jedem Neubau. macOS
kann nach größeren Umbauten erneut nach den Berechtigungen fragen. Für den persönlichen
Gebrauch zumutbar; sauber lösbar erst mit Entwicklerzertifikat → M8.

## Die vier Protokolle

Jeweils ein Protokoll, eine echte Implementierung, ein Mock — dasselbe Muster wie
`Transcriber`/`Refiner` in der Engine. Die einzige Stelle, die konkrete Typen kennt, ist die
Komposition beim App-Start.

### `SidecarClient`

Spiegelt exakt die vier Endpunkte aus M2:

```swift
protocol SidecarClient: Sendable {
    func health() async throws -> HealthState
    func preload() async throws
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult
    func unload() async throws
}
```

Die echte Implementierung öffnet eine `NWConnection` zur Socket-Datei, schreibt eine
HTTP/1.1-Anfrage und liest die Antwort. Sie unterscheidet die drei Ausgänge, die M2 festgelegt
hat:

| Antwort | Bedeutung | Swift |
|---|---|---|
| `200`, `refined: true` | fertiger Text | `ProcessResult(refined: true, …)` |
| `200`, `refined: false` | Text da, aber unpoliert (LLM ausgefallen) — **kein Fehler** | `ProcessResult(refined: false, fallbackReason: …)` |
| `503` | Sidecar läuft, ist aber kaputt (STT-Warm-up gescheitert) | `SidecarError.notReady(reason)` |
| `500` | Verarbeitung fehlgeschlagen (STT-Ausfall) | `SidecarError.processingFailed(detail)` |
| keine Verbindung | Sidecar antwortet gar nicht | `SidecarError.unreachable` |

`503` (gestartet, aber kaputt) und `unreachable` (gar nicht da) sind **verschiedene Zustände**
und müssen es bleiben — das ist genau die Unterscheidung, für die in M2 der `failed`-Status
gebaut wurde.

`Mode`, `HealthState` und `ProcessResult` sind Swift-Spiegelungen der Engine-Typen aus M2
(`Mode` = `diktat|prompt|email|slack|braindump`; `ProcessResult` trägt `finalText`, `rawText`,
`dictionaryText`, `refined`, `fallbackReason`, `timingsMs`).

**Der Client implementiert alle vier Endpunkte, obwohl die App in M3 nur `health` nutzt.**
`process` und `preload` bleiben ohne Aufrufer, bis M4 das Audio liefert — sie jetzt zu bauen
kostet wenig und macht den Client in einem Rutsch gegen den echten Sidecar überprüfbar. Das
ist bewusst kein Scope Creep: Der Client ist eine Einheit, und ein halb implementiertes
Protokoll wäre nur halb getestet.

### `SidecarLifecycle`

```swift
protocol SidecarLifecycle: Sendable {
    func start() async throws -> SidecarOwnership   // .adopted | .spawned
    func stop() async
}
```

`start()` fragt zuerst `health()`. Antwortet jemand → **übernehmen** (`.adopted`), Prozess
nicht anfassen. Antwortet niemand → `uv run python -m typeless_engine.server` als Kindprozess
starten (`.spawned`), auf `ready` warten (Polling mit Timeout), beim Beenden terminieren.

**`stop()` beendet nur, was `start()` selbst gestartet hat.** Eine übernommene Instanz bleibt
laufen — wer sie gestartet hat, beendet sie.

Das Arbeitsverzeichnis (`engine/`) kommt aus dem `SettingsStore`.

### `PermissionsService`

Liest den Ist-Zustand, fragt **nichts** aktiv an:

```swift
protocol PermissionsService: Sendable {
    func status() -> PermissionStatus   // microphone, accessibility, inputMonitoring
    func openSettings(for: Permission)
}
```

Mikrofon über `AVCaptureDevice.authorizationStatus(for: .audio)`, Accessibility über
`AXIsProcessTrusted()`, Input-Monitoring über `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.
`openSettings` öffnet den passenden `x-apple.systempreferences:`-Bereich.

### `SettingsStore`

Nur, was M3 braucht: Pfad zum `engine`-Verzeichnis (Default: Repo) und zum Socket (Default:
`~/Library/Application Support/TypeLess/typeless.sock`). Persistiert über `UserDefaults`.

## `AppState`

Ein beobachtbares Objekt (`@Observable`), das alles zusammenführt. Das **Einzige**, was die
SwiftUI-Schicht kennt — und der Vorläufer des `RecordingCoordinator` aus M4.

```swift
enum EngineState: Equatable {
    case stopped
    case starting          // Sidecar läuft, STT lädt (~20 s)
    case ready
    case failed(String)    // mit Klartext-Grund
}
```

Übergänge: `stopped → starting → ready`, aus jedem Zustand nach `failed(Grund)`. „Engine neu
starten" führt von überall zurück nach `starting`.

**Wer den Zustand aktualisiert:** `AppState` pollt `health()` — eng getaktet, solange
`starting` (alle 1 s, damit der Sprung auf „Bereit" sofort sichtbar wird), danach entspannt
(alle 5 s, um ein Wegsterben des Sidecars zu bemerken). Das Polling gehört in `AppState`,
nicht in den Client: Der Client bleibt zustandslos und beantwortet genau eine Frage pro
Aufruf.

## Die Oberfläche

Ein Mikrofon-Symbol in der Menüleiste, **kein Dock-Icon, kein Fenster**. Der Klick zeigt:

1. **Zustand der Engine** — „Startet…", „Bereit" oder **„Fehler: ⟨Klartext⟩"**. Kein bloßes
   rotes Symbol: Der Grund steht da.
2. **Die drei Berechtigungen** mit Häkchen/Warnzeichen. Ein Klick öffnet den passenden Bereich
   der Systemeinstellungen. Noch braucht die App keine davon — der Nutzer soll sehen, was ab
   M4 nötig wird.
3. **„Engine neu starten"** für den Klemmfall.
4. **„TypeLess beenden"** — nimmt einen selbst gestarteten Sidecar sauber mit.

## Fehlerverhalten

| Fall | Verhalten |
|---|---|
| `uv` nicht gefunden / `engine`-Pfad falsch | `failed("Engine nicht gefunden: ⟨Pfad⟩")`, Hinweis auf die Einstellungen |
| Sidecar startet, aber `/health` bleibt `starting` | Timeout (90 s), dann `failed("Zeitüberschreitung beim Start")` |
| `/health` meldet `failed` | `failed(⟨Grund aus dem Sidecar⟩)` — der Klartext kommt aus M2 |
| Sidecar stirbt im Betrieb | beim nächsten Poll erkannt → `failed("Verbindung verloren")` |
| Bereits laufende Instanz | übernehmen, nicht scheitern |

## Tests

**Gegen Mocks, ohne Fenster** (`swift test` gegen `TypeLessCore`):
- `AppState`-Übergänge: `stopped → starting → ready`; jeder Zustand → `failed`; Neustart.
- `SidecarLifecycle` **übernimmt** eine laufende Instanz (`.adopted`) und startet keinen
  Prozess; `stop()` beendet eine übernommene Instanz **nicht**.
- `SidecarLifecycle` startet einen Prozess, wenn niemand antwortet (`.spawned`), und beendet
  ihn bei `stop()`.
- Timeout beim Warten auf `ready` → `failed`.
- Der Client übersetzt die fünf Antwortformen korrekt (siehe Tabelle oben) — insbesondere:
  `refined: false` ist **kein** Fehler, `503` ist **nicht** `unreachable`.

**Gegen den echten Sidecar** (der selbstgebaute HTTP-Client ist das Risiko, das ich selbst
eingebaut habe — er wird nicht nur gegen Mocks geprüft):
- `health()` über den echten Socket.
- `process()` mit echtem PCM → Text.
- Der Sidecar antwortet mit `Content-Length` (nicht chunked) — die Annahme, auf der der
  Parser steht, wird explizit geprüft.

## Nicht Teil von M3

Kein Hotkey, keine Audioaufnahme, kein Overlay, kein Text-Einfügen (M4/M5). Keine
Modi-Umschaltung (M6), kein Settings-Fenster (M7) — die wenigen Einstellungen leben in
`UserDefaults`, ohne UI. Keine Notarisierung (M8).
