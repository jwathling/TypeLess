# Verteilung Teil 2b: SwiftUI-Erststart-Einrichtungsfenster — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Beim ersten Start auf einem frischen Mac zeigt die App ein einmaliges Einrichtungs-Fenster
mit Fortschrittsbalken, während die Engine (Teil 2a) die Modelle lädt — mit Fehleranzeige und
„Erneut versuchen"; sind die Modelle da, erscheint nie ein Fenster.

**Architecture:** Der `SidecarClient`/`HealthState` bekommt den `models`-Block aus Teil 2a und einen
`ensureModels()`-Aufruf (`POST /models/ensure`). Eine reine, in `TypeLessCore` testbare Ableitung
`SetupState(models:)` bildet den Modell-Status auf einen UI-Zustand ab (nur `downloading`/`failed`
sind sichtbar — nie bei vollem Cache). `AppState` hält `setup` und aktualisiert es im bestehenden
Poll; die dünne SwiftUI-Hülle (`Sources/TypeLess`) öffnet/schließt daraufhin ein `Window` und holt
es als `LSUIElement`-App per `NSApp.activate` nach vorne.

**Tech Stack:** Swift, SwiftUI (`Window`-Szene, `openWindow`/`dismissWindow`), Swift Testing, AppKit
(`NSApp.activate`).

## Global Constraints

- **`TypeLessCore` bleibt UI-frei** (kein SwiftUI-/AppKit-UI-Import): die gesamte Entscheid-Logik
  (`SetupState`-Ableitung, `AppState`-Zustand) liegt dort und ist ohne Fenster testbar. Die SwiftUI-
  Hülle in `Sources/TypeLess` enthält keine Logik.
- **`models`-Block-Vertrag (aus Teil 2a, auf main):** JSON `{"state": "missing"|"downloading"|"ready"|"failed", "downloaded_bytes": int, "total_bytes": int, "error": string|null}`; `downloaded_bytes ≤ total_bytes` (geclampt). „Erneut versuchen" = `POST /models/ensure` (202).
- **Das Fenster ist die EINZIGE Ausnahme** von „kein Fenster/Overlay": es erscheint nur zur
  einmaligen Einrichtung (Zustand `downloading`/`failed`), nie beim Diktieren, nie bei vorhandenen
  Modellen. Danach nie wieder.
- **Kommentare auf Deutsch**, bestehendem Stil folgen. Swift Testing (`import Testing`, `@Test`, `#expect`).

---

## Dateien-Überblick

- **Ändern:** `apps/macos/Sources/TypeLessCore/Sidecar/SidecarModels.swift` — `ModelsStatus`-Struct;
  `HealthState.models`; `HealthDTO.models` (+ `ModelsDTO`).
- **Ändern:** `apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift` — `health()` parst `models`;
  neues `ensureModels()` im Protokoll + HTTP-Impl.
- **Neu:** `apps/macos/Sources/TypeLessCore/Dictation/SetupState.swift` — reine Ableitung Modell-Status → UI-Zustand.
- **Ändern:** `apps/macos/Sources/TypeLessCore/AppState.swift` — `setup`-Feld, im Poll gesetzt; `retryModelDownload()`.
- **Neu:** `apps/macos/Sources/TypeLess/SetupWindow.swift` — die SwiftUI-View (Fortschritt / Fehler+Retry).
- **Ändern:** `apps/macos/Sources/TypeLess/TypeLessApp.swift` — `Window`-Szene + Öffnen/Schließen-Steuerung.
- **Ändern/Neu:** `apps/macos/Tests/TypeLessCoreTests/…` — Tests für Parsing, `ensureModels`, `SetupState`, `AppState.setup`.

---

### Task 1: `ModelsStatus` + `HealthState`/`HealthDTO` um `models` erweitern

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarModels.swift`
- Modify: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift` (health-Parsing)
- Test: `apps/macos/Tests/TypeLessCoreTests/` (bestehende SidecarClient-Testdatei)

**Interfaces:**
- Produces: `struct ModelsStatus: Sendable, Equatable { let state: String; let downloadedBytes: Int; let totalBytes: Int; let error: String? }`;
  `HealthState.models: ModelsStatus`.

- [ ] **Step 1: Failing test** — ein `/health`-JSON mit `models`-Block wird korrekt geparst.

Nutze die vorhandene SidecarClient-Testinfrastruktur (Fake-Transport, der eine JSON-Antwort liefert
— finde den echten Namen selbst). Der Test lässt `client.health()` laufen und prüft `models`:

```swift
@Test func healthParstModelsBlock() async throws {
    let json = """
    {"status":"starting","stt_loaded":false,"llm_loaded":false,"busy":false,
     "stt_model":"s","llm_model":"l","error":null,
     "models":{"state":"downloading","downloaded_bytes":1500,"total_bytes":3900,"error":null}}
    """
    let client = makeClient(health: json)   // vorhandener Fake-Transport-Helfer
    let state = try await client.health()
    #expect(state.models == ModelsStatus(state: "downloading", downloadedBytes: 1500,
                                         totalBytes: 3900, error: nil))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter healthParstModelsBlock`
Expected: FAIL — `HealthState` hat kein `models`, `ModelsStatus` existiert nicht.

- [ ] **Step 3: Implement**

In `SidecarModels.swift` den Typ ergänzen und `HealthState` erweitern:

```swift
/// Zustand des Modell-Bootstraps (Teil des ``/health``-Reports, aus Teil 2a).
public struct ModelsStatus: Sendable, Equatable {
    public let state: String  // "missing" | "downloading" | "ready" | "failed"
    public let downloadedBytes: Int
    public let totalBytes: Int
    public let error: String?

    public init(state: String, downloadedBytes: Int, totalBytes: Int, error: String?) {
        self.state = state
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.error = error
    }
}
```

`HealthState` um das Feld erweitern (nach `error`):

```swift
    public let models: ModelsStatus
```

> `HealthState` hat einen synthetisierten Memberwise-Init (kein expliziter). Wird er in Tests/Code
> direkt konstruiert, brauchen diese Stellen jetzt `models:` — ergänze sie (Step 5 fängt das ab).

`HealthDTO` um den verschachtelten Block erweitern:

```swift
struct ModelsDTO: Decodable {
    let state: String
    let downloaded_bytes: Int
    let total_bytes: Int
    let error: String?
}
```

und in `HealthDTO` das Feld `let models: ModelsDTO` ergänzen.

In `SidecarClient.swift`, `health()`, den `models`-Block mitgeben (im bestehenden `return HealthState(...)`):

```swift
        return HealthState(status: dto.status, sttLoaded: dto.stt_loaded, llmLoaded: dto.llm_loaded,
                           busy: dto.busy, sttModel: dto.stt_model, llmModel: dto.llm_model,
                           error: dto.error,
                           models: ModelsStatus(state: dto.models.state,
                                                downloadedBytes: dto.models.downloaded_bytes,
                                                totalBytes: dto.models.total_bytes,
                                                error: dto.models.error))
```

- [ ] **Step 4: Run the new test — passes**

Run: `cd apps/macos && swift test --filter healthParstModelsBlock`
Expected: PASS.

- [ ] **Step 5: Volle Suite grün halten**

Run: `cd apps/macos && swift build && swift test`
Expected: Baut, alle Tests grün. Jede bestehende `HealthState(...)`-Konstruktion (in Tests/Fakes)
braucht nun ein `models:`-Argument — ergänze sie mit einem neutralen Wert, z. B.
`models: ModelsStatus(state: "ready", downloadedBytes: 0, totalBytes: 0, error: nil)`.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Sidecar/SidecarModels.swift apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift apps/macos/Tests/TypeLessCoreTests/
git commit -m "M8-Verteilung Teil2b: models-Block in HealthState/health-Parsing"
```

---

### Task 2: `ensureModels()` im `SidecarClient`

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/` (SidecarClient-Testdatei)

**Interfaces:**
- Produces: `SidecarClient.ensureModels() async throws` (Protokoll + HTTP-Impl, `POST /models/ensure`).

**Kontext:** Das `SidecarClient`-Protokoll hat vier Methoden (`health`/`preload`/`process`/`unload`).
`ensureModels` kommt als fünfte hinzu — das bricht **alle** Conformer (der echte `HTTPSidecarClient`
und jeder Test-Fake/Mock). Alle müssen die Methode bekommen (Fakes: triviale Impl).

- [ ] **Step 1: Failing test** — `ensureModels()` trifft `POST /models/ensure`.

Analog zu vorhandenen Endpunkt-Tests (z. B. dem `preload`-Test, der Methode+Pfad am Fake-Transport
prüft):

```swift
@Test func ensureModelsRuftPostModelsEnsure() async throws {
    let transport = RecordingTransport()   // vorhandener Fake — echten Namen übernehmen
    let client = HTTPSidecarClient(transport: transport)  // bzw. den vorhandenen Test-Konstruktor
    try await client.ensureModels()
    #expect(transport.lastMethod == "POST")
    #expect(transport.lastPath == "/models/ensure")
}
```

> Umsetzer-Hinweis: den echten Fake-Transport-Namen + Test-Konstruktionsweg von `HTTPSidecarClient`
> aus den bestehenden `preload`/`unload`-Tests übernehmen.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ensureModelsRuftPostModelsEnsure`
Expected: FAIL — `ensureModels` existiert nicht.

- [ ] **Step 3: Implement**

Im `SidecarClient`-Protokoll die Methode ergänzen:

```swift
    func ensureModels() async throws
```

In `HTTPSidecarClient` (analog zu `preload`, `preloadTimeout` wiederverwenden):

```swift
    public func ensureModels() async throws {
        _ = try await request("POST", "/models/ensure", body: nil, contentType: nil,
                              timeout: preloadTimeout)
    }
```

Alle **anderen** Conformer (Test-Fakes/Mocks von `SidecarClient`) um eine triviale `ensureModels()`
ergänzen (die meisten brauchen nur `func ensureModels() async throws {}` bzw. einen Zähler, wo der
Retry-Aufruf geprüft wird — s. Task 3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/macos && swift build && swift test`
Expected: Baut (alle Conformer erweitert), alle Tests grün.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift apps/macos/Tests/TypeLessCoreTests/
git commit -m "M8-Verteilung Teil2b: SidecarClient.ensureModels (POST /models/ensure)"
```

---

### Task 3: `SetupState`-Ableitung + `AppState`-Integration

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Dictation/SetupState.swift`
- Modify: `apps/macos/Sources/TypeLessCore/AppState.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/SetupStateTests.swift` (neu) + AppState-Testdatei

**Interfaces:**
- Consumes: `ModelsStatus` (Task 1), `SidecarClient.ensureModels` (Task 2).
- Produces: `enum SetupState: Sendable, Equatable { case hidden; case downloading(fraction: Double, downloadedBytes: Int, totalBytes: Int); case failed(String) }` mit `init(models: ModelsStatus)`;
  `AppState.setup: SetupState`; `AppState.retryModelDownload() async`.

- [ ] **Step 1: Failing tests — die reine Ableitung**

```swift
// SetupStateTests.swift
import Testing
@testable import TypeLessCore

@Test func downloadingIstSichtbarMitAnteil() {
    let s = SetupState(models: ModelsStatus(state: "downloading", downloadedBytes: 1950,
                                            totalBytes: 3900, error: nil))
    #expect(s == .downloading(fraction: 0.5, downloadedBytes: 1950, totalBytes: 3900))
}

@Test func failedIstSichtbarMitGrund() {
    let s = SetupState(models: ModelsStatus(state: "failed", downloadedBytes: 0, totalBytes: 3900,
                                            error: "kein Netz"))
    #expect(s == .failed("kein Netz"))
}

@Test func readyUndMissingSindVersteckt() {
    // Nie ein Fenster bei vollem Cache (ready) oder im kurzen Anlauf (missing).
    #expect(SetupState(models: ModelsStatus(state: "ready", downloadedBytes: 0, totalBytes: 0, error: nil)) == .hidden)
    #expect(SetupState(models: ModelsStatus(state: "missing", downloadedBytes: 0, totalBytes: 0, error: nil)) == .hidden)
}

@Test func downloadingOhneGesamtgroesseHatAnteilNull() {
    // total_bytes == 0 darf nicht durch Null teilen.
    let s = SetupState(models: ModelsStatus(state: "downloading", downloadedBytes: 0, totalBytes: 0, error: nil))
    #expect(s == .downloading(fraction: 0.0, downloadedBytes: 0, totalBytes: 0))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/macos && swift test --filter SetupStateTests`
Expected: FAIL — `SetupState` existiert nicht.

- [ ] **Step 3: Implement `SetupState`**

```swift
import Foundation

/// UI-Zustand des einmaligen Einrichtungs-Fensters, abgeleitet aus dem ``ModelsStatus`` der Engine.
///
/// Sichtbar sind bewusst NUR ``downloading`` und ``failed``: Bei vorhandenen Modellen läuft der
/// Status ``missing`` → ``ready`` durch, ohne je ``downloading`` zu erreichen — dann erscheint kein
/// Fenster. Das ``missing`` beim allerersten Anlauf (Metadaten werden geladen) ist bewusst ebenfalls
/// ``hidden``: sonst blitzte das Fenster bei jedem Start kurz auf.
public enum SetupState: Sendable, Equatable {
    case hidden
    case downloading(fraction: Double, downloadedBytes: Int, totalBytes: Int)
    case failed(String)

    public init(models: ModelsStatus) {
        switch models.state {
        case "downloading":
            let fraction = models.totalBytes > 0
                ? Double(models.downloadedBytes) / Double(models.totalBytes)
                : 0.0
            self = .downloading(fraction: fraction, downloadedBytes: models.downloadedBytes,
                                totalBytes: models.totalBytes)
        case "failed":
            self = .failed(models.error ?? "Der Modell-Download ist fehlgeschlagen.")
        default:  // "ready", "missing" und alles Unerwartete: kein Fenster
            self = .hidden
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/macos && swift test --filter SetupStateTests`
Expected: PASS (4 Tests).

- [ ] **Step 5: `AppState` integrieren — Test zuerst**

Finde in der AppState-Testdatei den Fake-`SidecarClient` und den Weg, `pollOnce()` (bzw. einen
Poll-Durchlauf) mit einem gescripteten `HealthState` auszulösen. Ergänze einen Test, dass `setup`
nach einem Poll mit `models.state == "downloading"` den sichtbaren Zustand trägt, und dass
`retryModelDownload()` `ensureModels()` am Client auslöst:

```swift
@Test func pollSetztSetupAusModelsBlock() async {
    let client = FakeSidecarClient(health: healthMitModels(state: "downloading",
                                                           downloaded: 1950, total: 3900))
    let state = AppState(lifecycle: ..., client: client, permissions: ...)
    _ = await state.pollOnceForTest()   // vorhandenen Test-Zugang zum Poll nutzen/ergänzen
    #expect(state.setup == .downloading(fraction: 0.5, downloadedBytes: 1950, totalBytes: 3900))
}

@Test func retryRuftEnsureModels() async {
    let client = CountingFakeSidecarClient()
    let state = AppState(lifecycle: ..., client: client, permissions: ...)
    await state.retryModelDownload()
    #expect(client.ensureModelsCalls == 1)
}
```

> Umsetzer-Hinweis: die echten Fake-/Helfer-Namen aus der AppState-Testdatei übernehmen. Wenn es
> keinen direkten Test-Zugang zu einem Poll-Durchlauf gibt, orientiere dich daran, wie die
> bestehenden Tests `engine` nach einem Poll prüfen (dieselbe Achse), und aktualisiere `setup` an
> genau der Stelle in `pollOnce`, an der `engine` aus `health()` gesetzt wird.

- [ ] **Step 6: Implement in `AppState`**

Feld ergänzen:

```swift
    public private(set) var setup: SetupState = .hidden
```

In `pollOnce()` — dort, wo aus einem erfolgreichen `health()` der `engine`-Zustand gesetzt wird —
zusätzlich:

```swift
            setup = SetupState(models: health.models)
```

(Beim selben `health`-Wert; kein zweiter Netzaufruf.) Und die Retry-Methode:

```swift
    /// „Erneut versuchen" aus dem Einrichtungs-Fenster: stößt den Modell-Bootstrap erneut an. Der
    /// Fortschritt/Erfolg kommt über den normalen Poll (``setup``) zurück, deshalb hier nur anstoßen.
    public func retryModelDownload() async {
        try? await client.ensureModels()
    }
```

- [ ] **Step 7: Run tests — pass**

Run: `cd apps/macos && swift build && swift test`
Expected: Baut, alle Tests grün.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/SetupState.swift apps/macos/Sources/TypeLessCore/AppState.swift apps/macos/Tests/TypeLessCoreTests/
git commit -m "M8-Verteilung Teil2b: SetupState-Ableitung + AppState.setup/retryModelDownload"
```

---

### Task 4: SwiftUI-Einrichtungs-Fenster + Verdrahtung (Handprobe)

**Files:**
- Create: `apps/macos/Sources/TypeLess/SetupWindow.swift`
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift`

**Kontext:** Die Logik steckt in `AppState.setup` (Task 3). Diese Task ist die reine Darstellung +
Fenster-Mechanik in der dünnen SwiftUI-Hülle — nicht unit-getestet (SwiftUI); Verifikation ist
`swift build` + Handprobe. Als `LSUIElement`-App muss das Fenster aktiv nach vorne geholt werden.

- [ ] **Step 1: Die View schreiben**

```swift
// apps/macos/Sources/TypeLess/SetupWindow.swift
import SwiftUI
import TypeLessCore

/// Einmaliges Einrichtungs-Fenster beim ersten Start: zeigt den Modell-Download-Fortschritt bzw.
/// einen Fehler mit „Erneut versuchen". Reine Anzeige — die Logik liegt in ``AppState/setup``.
struct SetupWindow: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("TypeLess wird eingerichtet")
                .font(.headline)
            switch state.setup {
            case .downloading(let fraction, let downloaded, let total):
                ProgressView(value: fraction) {
                    Text("Sprachmodelle werden geladen …")
                } currentValueLabel: {
                    Text("\(gib(downloaded)) von \(gib(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Das passiert nur beim ersten Start. Danach läuft alles lokal.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let grund):
                Text("Der Download ist fehlgeschlagen.").foregroundStyle(.red)
                Text(grund).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Erneut versuchen") { Task { await state.retryModelDownload() } }
            case .hidden:
                // Erscheint nicht — das Fenster wird in diesem Zustand geschlossen (TypeLessApp).
                EmptyView()
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    /// GB mit einer Nachkommastelle.
    private func gib(_ bytes: Int) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
```

- [ ] **Step 2: `Window`-Szene + Öffnen/Schließen in `TypeLessApp`**

In `TypeLessApp.swift` neben der bestehenden `MenuBarExtra`-Szene eine `Window`-Szene ergänzen und
sie am `setup`-Zustand steuern. `setup != .hidden` → Fenster öffnen und App nach vorne holen;
`.hidden` → schließen.

```swift
    // in `var body: some Scene { … }`, zusätzlich zur MenuBarExtra:
    Window("TypeLess Einrichtung", id: Self.setupWindowID) {
        SetupWindow(state: state)
            .onChange(of: istEinrichtung) { _, sichtbar in
                if sichtbar {
                    openWindow(id: Self.setupWindowID)
                    NSApp.activate(ignoringOtherApps: true)  // LSUIElement: sonst bleibt es im Hintergrund
                } else {
                    dismissWindow(id: Self.setupWindowID)
                }
            }
    }
    .windowResizability(.contentSize)
```

Dazu die Helfer in `TypeLessApp` (Environment-Aktionen + abgeleiteter Sichtbar-Flag + stabile ID):

```swift
    static let setupWindowID = "typeless-setup"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var istEinrichtung: Bool { state.setup != .hidden }
```

> Umsetzer-Hinweis: `@Environment(\.openWindow)`/`dismissWindow` sind in `App` verfügbar. Prüfe beim
> Bauen die genaue Platzierung von `.onChange`/den Environment-Zugriffen (SwiftUI erlaubt sie an der
> Szene bzw. an einer View in der Szene) und passe sie an, falls der Compiler eine andere Struktur
> verlangt — Ziel bleibt: bei `setup != .hidden` Fenster öffnen + `NSApp.activate`, sonst schließen.
> `openWindow`/`dismissWindow` mit einer nicht-vorhandenen ID sind harmlose No-ops.

- [ ] **Step 3: Bauen**

Run: `cd apps/macos && swift build && swift test`
Expected: Baut, alle 130+ Tests grün (die Hülle ist nicht unit-getestet, darf die Suite aber nicht brechen).

- [ ] **Step 4: Handprobe (echtes Bundle, frischer Cache)**

Modelle-Cache beiseitelegen, damit die Engine wirklich lädt, App starten, Fenster prüfen, danach
Cache zurück:

```bash
bash scripts/build-app.sh
mv ~/Library/Application\ Support/TypeLess/models{,.bak} 2>/dev/null || true
open apps/macos/TypeLess.app
# Erwartung: Einrichtungs-Fenster erscheint im Vordergrund, Balken steigt; bei getrenntem Netz
# „Erneut versuchen"; nach Abschluss schließt es sich und das Menüleisten-Symbol meldet „Bereit".
# Danach App beenden und den echten Cache zurückholen:
mv ~/Library/Application\ Support/TypeLess/models.bak ~/Library/Application\ Support/TypeLess/models 2>/dev/null || true
```

Dokumentiere das beobachtete Verhalten im Task-Report. (Wenn Netz/Zeit den vollen Download
verhindern: das Erscheinen des Fensters + steigender Balken bis zu einem Zwischenstand genügt als
Beleg; den Cache danach zurückholen.)

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLess/SetupWindow.swift apps/macos/Sources/TypeLess/TypeLessApp.swift
git commit -m "M8-Verteilung Teil2b: SwiftUI-Einrichtungsfenster + Fenster-Steuerung"
```

---

## Selbstprüfung (nach dem Schreiben, gegen die Spec)

- **Spec-Abdeckung (Baustein 2, Swift-Teil):** Erststart-Erkennung (Task 3, `SetupState` aus dem
  `models`-Block), einmaliges Fenster mit Fortschrittsbalken (Task 4), erscheint nur bei fehlenden
  Modellen / nie bei vollem Cache (Task 3: nur `downloading`/`failed` sichtbar), Fehler + „Erneut
  versuchen" → `POST /models/ensure` (Task 2+3+4). ✓
- **`TypeLessCore` UI-frei:** `SetupState` + `AppState.setup`/`retryModelDownload` in `TypeLessCore`
  (testbar); nur `SetupWindow.swift` + `TypeLessApp.swift` in `Sources/TypeLess` importieren SwiftUI. ✓
- **Vertrag zu Teil 2a:** `ModelsStatus`-Felder spiegeln den `models`-JSON-Block exakt
  (`state/downloaded_bytes/total_bytes/error`); `ensureModels()` trifft `POST /models/ensure`. ✓
- **Typkonsistenz:** `ModelsStatus` (Task 1) → `SetupState.init(models:)` (Task 3) → `SetupWindow`
  (Task 4); `SidecarClient.ensureModels` (Task 2) → `AppState.retryModelDownload` (Task 3) →
  Button (Task 4). ✓

## Ausführungs-Hinweis

Reihenfolge 1→4 (Task 2/3 brauchen Task 1; Task 4 braucht 3). Task 2 und die `HealthState`-Erweiterung
(Task 1) berühren alle `SidecarClient`-/`HealthState`-Nutzer (Test-Fakes) — dort ist der meiste
Anpassungsaufwand. Nach Task 4 ist Teil 2b per Handprobe abnehmbar. Danach Teil 3 (Sparkle-Selbst-
Update + GitHub-Releases).
