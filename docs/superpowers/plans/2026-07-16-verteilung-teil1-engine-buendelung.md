# Verteilung Teil 1: Engine-Bündelung & Bundled-vs-Dev-Start — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die ausgelieferte `TypeLess.app` startet ihre Python-Engine aus dem eigenen App-Bündel
heraus (ohne Entwickler-Setup, ohne geklontes Projekt), während der bestehende Entwickler-Ablauf
(`uv run` gegen das Repo) unverändert weiterläuft.

**Architecture:** Ein mitgeliefertes `uv`-Binary plus die Engine-Quellen liegen schreibgeschützt im
Bündel unter `Contents/Resources/engine/`. Beim Start baut `uv run --frozen --project <bundle>` die
Python-Umgebung an einem **beschreibbaren, externen** Ort unter Application Support auf (das
signierte Bündel bleibt unangetastet → Signatur und Berechtigungen bleiben stabil). Welcher
Startbefehl gilt (gebündelt vs. Entwicklung), entscheidet eine **reine Funktion** im Composition-
Root; der `SidecarLifecycle`-Kern (Übernahme, Warten, Beenden) bleibt unberührt.

**Tech Stack:** Swift (TypeLessCore, Swift Testing), `uv` (Astral), bestehendes `scripts/build-app.sh`.

**Verifizierter Kern (Spike, 2026-07-16):** `uv run --frozen --project <read-only-engine>` mit
`UV_PROJECT_ENVIRONMENT=<extern>` baut die Umgebung extern auf, importiert `typeless_engine`,
`mlx_whisper`, `mlx_lm`, `fastapi`, und schreibt **nichts** ins schreibgeschützte Projekt. Die
Umgebung ist ~1,1–1,3 GB (inkl. `torch`, transitiv über `transformers`/`mlx-lm`).

## Global Constraints

- **Austauschbarkeit unberührt:** Der Vertrag `interfaces/transcriber.py` (`transcribe`) und
  `interfaces/refiner.py` bleibt unverändert; `factory.py` bleibt die einzige Stelle, die konkrete
  Backends kennt. Dieser Plan fasst **keinen** Engine-Python-Code an, nur Verpackung + Start.
- **Nur Apple Silicon**, nur eigene Macs. Kein Apple-Konto, keine Notarisierung.
- **Bundle-Identität stabil:** Bundle-ID bleibt `de.typeless.TypeLess`, Signatur-Identität bleibt
  `TypeLess Dev` (Default in `build-app.sh`).
- **Dev-Ablauf darf nicht brechen:** `swift build && swift test` und `uv run python -m
  typeless_engine.server` müssen unverändert funktionieren.
- **Kommentare/Docstrings auf Deutsch**, bestehendem Stil folgen.
- **Externe Pfade (Application Support):** Laufzeit-Umgebung nach
  `~/Library/Application Support/TypeLess/runtime`, uv-Cache nach `.../uv-cache`, Modell-Cache
  (`HF_HOME`) nach `.../models`. Der Modell-Cache wird hier nur als Umgebungsvariable gesetzt; das
  eigentliche Erststart-Download-Erlebnis ist Teil 2.

---

## Dateien-Überblick

- **Neu:** `apps/macos/Sources/TypeLessCore/Sidecar/EngineLaunch.swift` — Wert-Typ für die vier
  Startparameter + reine `resolve`-Funktion (gebündelt vs. Entwicklung).
- **Ändern:** `apps/macos/Sources/TypeLessCore/Sidecar/SidecarLifecycle.swift` — der
  `DefaultSidecarLifecycle` nimmt ein `EngineLaunch` statt `engineDirectory`/`uvPath`; die
  Start-/Validierungslogik nutzt dessen Felder. Kern (Übernahme/Warten/Stop) bleibt.
- **Ändern:** `apps/macos/Sources/TypeLess/TypeLessApp.swift` — Composition-Root baut das
  `EngineLaunch` über `resolve(...)` und reicht es in den Lifecycle.
- **Ändern:** `apps/macos/Tests/TypeLessCoreTests/SidecarLifecycleTests.swift` (bzw. die
  bestehende Lifecycle-Testdatei) — an die neue Init-Signatur angepasst.
- **Neu:** `apps/macos/Tests/TypeLessCoreTests/EngineLaunchTests.swift` — Tests der reinen Auswahl.
- **Ändern:** `scripts/build-app.sh` — bettet `uv` + Engine-Quellen ins Bündel ein.
- **Neu:** `scripts/verify-bundled-engine.sh` — startet die gebündelte Engine in einer sauberen
  Umgebung und prüft `/health` → `ready` (Abnahme für Task 5).

---

### Task 1: `EngineLaunch` — Startparameter + reine Auswahl

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Sidecar/EngineLaunch.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/EngineLaunchTests.swift`

**Interfaces:**
- Produces:
  - `struct EngineLaunch: Sendable, Equatable { let executable: String; let arguments: [String]; let workingDirectory: String; let environment: [String: String] }`
  - `static func EngineLaunch.resolve(bundledEngineDirectory: String?, uvPath: String, engineDirectory: String, socketPath: String, appSupportDirectory: String) -> EngineLaunch`
    — ist `bundledEngineDirectory` non-nil, liefert es den **gebündelten** Start, sonst den
    **Entwicklungs**-Start.

- [ ] **Step 1: Failing test — Entwicklungs-Fall (bundledEngineDirectory == nil)**

```swift
import Testing
@testable import TypeLessCore

@Test func resolveWaehltEntwicklungWennNichtGebuendelt() {
    let launch = EngineLaunch.resolve(
        bundledEngineDirectory: nil,
        uvPath: "/opt/uv",
        engineDirectory: "/repo/engine",
        socketPath: "/sock/typeless.sock",
        appSupportDirectory: "/AS/TypeLess")

    #expect(launch.executable == "/opt/uv")
    #expect(launch.arguments == ["run", "python", "-m", "typeless_engine.server"])
    #expect(launch.workingDirectory == "/repo/engine")
    #expect(launch.environment == ["TYPELESS_SOCKET_PATH": "/sock/typeless.sock"])
}
```

- [ ] **Step 2: Failing test — gebündelter Fall (bundledEngineDirectory gesetzt)**

```swift
@Test func resolveWaehltGebuendeltMitExternerUmgebung() {
    let launch = EngineLaunch.resolve(
        bundledEngineDirectory: "/App/Contents/Resources/engine",
        uvPath: "/opt/uv",                 // im gebündelten Fall ignoriert
        engineDirectory: "/repo/engine",   // im gebündelten Fall ignoriert
        socketPath: "/sock/typeless.sock",
        appSupportDirectory: "/AS/TypeLess")

    #expect(launch.executable == "/App/Contents/Resources/engine/uv")
    #expect(launch.arguments == [
        "run", "--frozen", "--project", "/App/Contents/Resources/engine",
        "--extra", "mlx", "--extra", "server",
        "python", "-m", "typeless_engine.server",
    ])
    // Arbeitsverzeichnis MUSS beschreibbar sein — niemals das read-only Bundle.
    #expect(launch.workingDirectory == "/AS/TypeLess")
    #expect(launch.environment == [
        "TYPELESS_SOCKET_PATH": "/sock/typeless.sock",
        "UV_PROJECT_ENVIRONMENT": "/AS/TypeLess/runtime",
        "UV_CACHE_DIR": "/AS/TypeLess/uv-cache",
        "HF_HOME": "/AS/TypeLess/models",
    ])
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd apps/macos && swift test --filter EngineLaunchTests`
Expected: FAIL — `EngineLaunch` existiert nicht.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// Die vier Werte, mit denen der ``SidecarLifecycle`` den Engine-Prozess startet. Bewusst ein
/// reiner Wert-Typ ohne Verhalten — *welche* Werte gelten (gebündelt vs. Entwicklung), entscheidet
/// ``resolve(bundledEngineDirectory:uvPath:engineDirectory:socketPath:appSupportDirectory:)``,
/// damit die Auswahl ohne echtes App-Bundle testbar bleibt.
public struct EngineLaunch: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String,
                environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Wählt den Startbefehl. Ist ``bundledEngineDirectory`` gesetzt (die App läuft aus einem
    /// Bündel mit eingebetteter Engine), wird die Python-Umgebung mit dem mitgelieferten `uv`
    /// **extern** unter Application Support aufgebaut — das schreibgeschützte, signierte Bündel
    /// bleibt unangetastet. Sonst gilt der Entwicklungs-Start (wie bisher: `uv run` gegen das Repo).
    public static func resolve(bundledEngineDirectory: String?, uvPath: String,
                               engineDirectory: String, socketPath: String,
                               appSupportDirectory: String) -> EngineLaunch {
        guard let bundle = bundledEngineDirectory else {
            return EngineLaunch(
                executable: uvPath,
                arguments: ["run", "python", "-m", "typeless_engine.server"],
                workingDirectory: engineDirectory,
                environment: ["TYPELESS_SOCKET_PATH": socketPath])
        }
        return EngineLaunch(
            executable: bundle + "/uv",
            arguments: [
                "run", "--frozen", "--project", bundle,
                "--extra", "mlx", "--extra", "server",
                "python", "-m", "typeless_engine.server",
            ],
            workingDirectory: appSupportDirectory,
            environment: [
                "TYPELESS_SOCKET_PATH": socketPath,
                "UV_PROJECT_ENVIRONMENT": appSupportDirectory + "/runtime",
                "UV_CACHE_DIR": appSupportDirectory + "/uv-cache",
                "HF_HOME": appSupportDirectory + "/models",
            ])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd apps/macos && swift test --filter EngineLaunchTests`
Expected: PASS (2 Tests).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Sidecar/EngineLaunch.swift apps/macos/Tests/TypeLessCoreTests/EngineLaunchTests.swift
git commit -m "M8-Verteilung Teil1: EngineLaunch — reine Auswahl gebündelt vs. Entwicklung"
```

---

### Task 2: `DefaultSidecarLifecycle` nimmt `EngineLaunch`

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarLifecycle.swift`
- Modify: `apps/macos/Tests/TypeLessCoreTests/SidecarLifecycleTests.swift` (bestehende Lifecycle-Tests)

**Interfaces:**
- Consumes: `EngineLaunch` (Task 1).
- Produces: `DefaultSidecarLifecycle.init(client:runner:launch:socketPath:readyTimeout:pollInterval:terminateTimeout:terminatePollInterval:)`
  — `engineDirectory`/`uvPath` entfallen, ersetzt durch `launch: EngineLaunch`.

**Kontext:** Heute prüft `start()` `engineDirectory` (existiert als Verzeichnis) und `uvPath`
(ausführbar) und ruft dann `runner.run(executable: uvPath, arguments: [...], workingDirectory:
engineDirectory, environment: ["TYPELESS_SOCKET_PATH": socketPath])`. Das wird auf `launch`
umgestellt. Die Übernahme-, Warte- und Stop-Logik (`waitForReady`, `stop`, `waitUntilExited`)
bleibt **unverändert**.

- [ ] **Step 1: Failing test — Lifecycle startet mit den Werten aus `launch`**

Passe den bestehenden Spawn-Test an (bzw. füge diesen hinzu). Er nutzt den vorhandenen
Fake-`ProcessRunner`, der die `run`-Argumente festhält:

```swift
@Test func startVerwendetEngineLaunchWerte() async throws {
    let launch = EngineLaunch(
        executable: "/App/Contents/Resources/engine/uv",
        arguments: ["run", "--frozen", "--project", "/App/Contents/Resources/engine",
                    "--extra", "mlx", "--extra", "server", "python", "-m", "typeless_engine.server"],
        workingDirectory: "/AS/TypeLess",
        environment: ["TYPELESS_SOCKET_PATH": "/sock/typeless.sock",
                      "UV_PROJECT_ENVIRONMENT": "/AS/TypeLess/runtime"])
    let runner = RecordingProcessRunner()               // vorhandener Fake
    let client = ScriptedSidecarClient(health: [.unreachableThen(.ready)])  // vorhandener Fake
    let lifecycle = DefaultSidecarLifecycle(
        client: client, runner: runner, launch: launch, socketPath: "/sock/typeless.sock",
        readyTimeout: .seconds(1), pollInterval: .milliseconds(5))

    let ownership = try await lifecycle.start()

    #expect(ownership == .spawned)
    #expect(runner.lastExecutable == "/App/Contents/Resources/engine/uv")
    #expect(runner.lastArguments == launch.arguments)
    #expect(runner.lastWorkingDirectory == "/AS/TypeLess")
    #expect(runner.lastEnvironment["UV_PROJECT_ENVIRONMENT"] == "/AS/TypeLess/runtime")
}
```

> Hinweis für den Umsetzer: Die genauen Namen der vorhandenen Fakes (`RecordingProcessRunner`,
> `ScriptedSidecarClient` o. Ä.) aus der bestehenden Testdatei übernehmen — nicht neu erfinden.
> Alle bereits vorhandenen Lifecycle-Tests, die `engineDirectory:`/`uvPath:` im Init verwenden,
> auf `launch:` umstellen (ein `EngineLaunch` mit den bisherigen Werten bauen).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SidecarLifecycleTests`
Expected: FAIL — Init-Signatur kennt `launch:` noch nicht / alte Tests kompilieren nicht.

- [ ] **Step 3: Implement — Init und Start-Zweig umstellen**

Ersetze in `SidecarLifecycle.swift` die Felder `engineDirectory`/`uvPath` durch `launch` und passe
`init` sowie den Spawn-Zweig an:

```swift
    private let launch: EngineLaunch
    // (engineDirectory und uvPath entfallen)

    public init(client: SidecarClient, runner: ProcessRunner, launch: EngineLaunch,
                socketPath: String, readyTimeout: Duration = .seconds(90),
                pollInterval: Duration = .seconds(1), terminateTimeout: Duration = .seconds(2),
                terminatePollInterval: Duration = .milliseconds(20)) {
        self.client = client
        self.runner = runner
        self.launch = launch
        self.socketPath = socketPath
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
        self.terminateTimeout = terminateTimeout
        self.terminatePollInterval = terminatePollInterval
    }
```

Im Spawn-Zweig von `start()` die Validierung und den `run`-Aufruf ersetzen:

```swift
        // 2. Niemand da: selbst starten. Das auszuführende Programm (mitgeliefertes `uv` im
        // Bündel oder das Dev-`uv`) muss vorhanden und ausführbar sein.
        guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
            throw LifecycleError.uvMissing(launch.executable)
        }

        ownProcess = try runner.run(
            executable: launch.executable,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory,
            environment: launch.environment)
```

> Die `case engineDirectoryMissing(String)` in `LifecycleError` bleibt bestehen (bleibt für
> andere Aufrufer/Tests kompatibel), wird aber im Start-Zweig nicht mehr geworfen — die Existenz
> des Arbeitsverzeichnisses ist im gebündelten Fall durch das Anlegen unter Application Support
> (Task 3, Composition-Root) sichergestellt, im Dev-Fall durch das vorhandene Repo. Kein
> Verhaltensverlust: Fehlt das gebündelte `uv`, greift `uvMissing`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/macos && swift test --filter SidecarLifecycleTests`
Expected: PASS (alle bestehenden + neuer Test).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Sidecar/SidecarLifecycle.swift apps/macos/Tests/TypeLessCoreTests/SidecarLifecycleTests.swift
git commit -m "M8-Verteilung Teil1: SidecarLifecycle nimmt EngineLaunch statt uvPath/engineDirectory"
```

---

### Task 3: Composition-Root verdrahtet `resolve` + legt Application Support an

**Files:**
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift`
- Modify: `apps/macos/Sources/TypeLessCore/Settings/SettingsStore.swift` (nur ein Helfer für den
  Application-Support-Pfad, falls nicht vorhanden)

**Interfaces:**
- Consumes: `EngineLaunch.resolve(...)` (Task 1), `DefaultSidecarLifecycle.init(...launch:...)` (Task 2).

**Kontext:** `TypeLessApp.init()` ist der einzige Ort, der konkrete Typen kennt. Hier wird
ermittelt, ob eine gebündelte Engine vorliegt (`Bundle.main.resourceURL/engine/uv` existiert und
ist ausführbar), das Application-Support-Verzeichnis angelegt, und `resolve` aufgerufen.

- [ ] **Step 1: Application-Support-Pfad + Bundle-Erkennung implementieren**

In `TypeLessApp.init()`, vor dem Lifecycle-Aufbau, ersetze die Zeilen 16–21 (den bisherigen
`DefaultSidecarLifecycle(...)`-Aufruf mit `engineDirectory:`/`uvPath:`) durch:

```swift
        // Application-Support-Wurzel für Laufzeit-Umgebung, uv-Cache und Modelle. Beschreibbar,
        // liegt außerhalb des (read-only, signierten) Bündels und überlebt App-Updates.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeLess", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // Liegt eine gebündelte Engine vor? (nur dann läuft die App „ausgeliefert").
        let bundledEngineDir = Bundle.main.resourceURL?
            .appendingPathComponent("engine", isDirectory: true).path
        let bundledUv = bundledEngineDir.map { $0 + "/uv" }
        let isBundled = bundledUv.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false

        let launch = EngineLaunch.resolve(
            bundledEngineDirectory: isBundled ? bundledEngineDir : nil,
            uvPath: settings.uvPath,
            engineDirectory: settings.engineDirectory,
            socketPath: settings.socketPath,
            appSupportDirectory: appSupport.path)

        let lifecycle = DefaultSidecarLifecycle(
            client: client, runner: FoundationProcessRunner(),
            launch: launch, socketPath: settings.socketPath)
```

> `settings` und `client` sind bereits oberhalb definiert (Zeilen 14–15). Der Rest von `init`
> (AppState, DictationCoordinator, `_state`/`_dictation`) bleibt unverändert.

- [ ] **Step 2: Dev-Betrieb prüfen (kein Bundle → Entwicklungs-Start)**

Run: `cd apps/macos && swift build && swift test`
Expected: Baut, alle Tests grün. (Ohne Bundle greift `isBundled == false` → unveränderter Dev-Start.)

- [ ] **Step 3: Manuelle Dev-Gegenprobe**

Run (aus dem Repo-Root, mit laufender Dev-Engine oder frisch): `swift run` aus `apps/macos` bzw.
das bestehende Dev-Startskript. Erwartung: Die App startet die Engine wie bisher über `uv run`
gegen `~/Projekte/TypeLess/engine` (Menütext „Bereit"/„ready"). Kein Regressions-Bruch.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/TypeLess/TypeLessApp.swift apps/macos/Sources/TypeLessCore/Settings/SettingsStore.swift
git commit -m "M8-Verteilung Teil1: Composition-Root wählt gebündelt/Dev und legt Application Support an"
```

---

### Task 4: `build-app.sh` bettet `uv` + Engine-Quellen ins Bündel

**Files:**
- Modify: `scripts/build-app.sh`

**Kontext:** `build-app.sh` baut heute nur das Swift-Binary ins Bündel (s. Datei). Neu: nach dem
Zusammensetzen des Bündels, **vor** dem `codesign`, die Engine einbetten. Die `uv`-Binary wird vom
Build-Mac übernommen (`command -v uv`), die Engine-Quellen aus `engine/`.

- [ ] **Step 1: Einbettungs-Block einfügen**

Füge in `scripts/build-app.sh` unmittelbar **vor** dem `codesign`-Abschnitt („macOS bindet …") ein:

```bash
# --- Engine ins Bündel einbetten (ausgelieferter Betrieb ohne Entwickler-Setup) ---
# uv baut daraus beim ersten Start die Python-Umgebung EXTERN unter Application Support auf
# (UV_PROJECT_ENVIRONMENT) — dieses Verzeichnis hier bleibt schreibgeschützt und signiert.
ENGINE_SRC="$(cd "$(dirname "$0")/../engine" && pwd)"
ENGINE_DST="$APP/Contents/Resources/engine"
echo "== Engine einbetten aus $ENGINE_SRC =="
rm -rf "$ENGINE_DST"
mkdir -p "$ENGINE_DST"
# Nur die zur Laufzeit nötigen Teile — keine .venv, kein __pycache__, keine Tests.
cp -R "$ENGINE_SRC/typeless_engine" "$ENGINE_DST/typeless_engine"
cp "$ENGINE_SRC/pyproject.toml" "$ENGINE_SRC/uv.lock" "$ENGINE_SRC/README.md" "$ENGINE_DST/"
find "$ENGINE_DST" -name "__pycache__" -type d -prune -exec rm -rf {} +

UV_BIN="$(command -v uv || true)"
if [ -z "$UV_BIN" ]; then
  echo "FEHLER: uv nicht gefunden (command -v uv leer). uv installieren und erneut bauen." >&2
  exit 1
fi
cp "$UV_BIN" "$ENGINE_DST/uv"
chmod +x "$ENGINE_DST/uv"
echo "   eingebettet: uv ($("$ENGINE_DST/uv" --version)) + typeless_engine + uv.lock"
```

> `uv.lock` MUSS mit ins Bündel (der Start nutzt `--frozen` und darf die Sperre nicht neu berechnen).
> Existiert `engine/uv.lock` noch nicht, einmalig `cd engine && uv lock` ausführen und einchecken.

- [ ] **Step 2: Bündel bauen und Inhalt prüfen**

Run: `bash scripts/build-app.sh`
Expected: Läuft durch; danach existieren
`apps/macos/TypeLess.app/Contents/Resources/engine/{uv,uv.lock,pyproject.toml,typeless_engine/}`.

Run: `ls apps/macos/TypeLess.app/Contents/Resources/engine`
Expected: `README.md  pyproject.toml  typeless_engine  uv  uv.lock`

- [ ] **Step 3: Signatur intakt trotz eingebetteter Binärdatei**

Run: `codesign --verify --deep --strict apps/macos/TypeLess.app && echo SIGNATUR_OK`
Expected: `SIGNATUR_OK` (das eingebettete `uv` ist mitsigniert, weil die Einbettung vor `codesign`
läuft).

- [ ] **Step 4: Commit**

```bash
git add scripts/build-app.sh engine/uv.lock
git commit -m "M8-Verteilung Teil1: build-app.sh bettet uv + Engine-Quellen ins Bündel ein"
```

---

### Task 5: Abnahme — gebündelte Engine startet in sauberer Umgebung

**Files:**
- Create: `scripts/verify-bundled-engine.sh`

**Kontext:** Der eigentliche Beweis von Teil 1: Das gebaute Bündel startet die Engine **ohne**
Repo-`uv`, **ohne** Projektverzeichnis und mit externem, frischem Umgebungs-/Cache-Ort — genau wie
auf einem fremden Mac. Der Modell-Download beim `warm_up` (STT) darf hier real passieren (braucht
Netz); geprüft wird, dass die Engine über den Socket `ready` meldet.

- [ ] **Step 1: Verifikationsskript schreiben**

```bash
#!/usr/bin/env bash
# Startet die INS BÜNDEL eingebettete Engine in einer sauberen Umgebung und prüft /health.
# Simuliert einen frischen Mac: eigener Application-Support-Ort, kein Repo-uv im Spiel.
set -euo pipefail

APP="apps/macos/TypeLess.app"
ENGINE="$PWD/$APP/Contents/Resources/engine"
[ -x "$ENGINE/uv" ] || { echo "FEHLER: $ENGINE/uv fehlt — erst scripts/build-app.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
SOCK="$WORK/typeless.sock"
echo "== Start der gebündelten Engine (frische Umgebung unter $WORK) =="
env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    TYPELESS_SOCKET_PATH="$SOCK" \
    UV_PROJECT_ENVIRONMENT="$WORK/runtime" \
    UV_CACHE_DIR="$WORK/uv-cache" \
    HF_HOME="$WORK/models" \
    "$ENGINE/uv" run --frozen --project "$ENGINE" --extra mlx --extra server \
    python -m typeless_engine.server &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "== auf /health = ready warten (bis 300 s; erster Lauf lädt Umgebung + STT-Modell) =="
for i in $(seq 1 300); do
  RESP="$(curl -s --unix-socket "$SOCK" http://localhost/health 2>/dev/null || true)"
  echo "$RESP" | grep -q '"status":"ready"' && { echo "READY nach ${i}s: $RESP"; exit 0; }
  echo "$RESP" | grep -q '"status":"failed"' && { echo "FAILED: $RESP" >&2; exit 1; }
  sleep 1
done
echo "TIMEOUT: Engine nicht ready" >&2; exit 1
```

- [ ] **Step 2: Ausführbar machen und laufen lassen**

Run: `chmod +x scripts/verify-bundled-engine.sh && bash scripts/build-app.sh && bash scripts/verify-bundled-engine.sh`
Expected: `READY nach <n>s: {"status":"ready"}` (erster Lauf länger — Umgebung + STT-Modell laden).

- [ ] **Step 3: Gegenprobe — nichts ins Bündel geschrieben**

Run: `codesign --verify --deep --strict apps/macos/TypeLess.app && echo SIGNATUR_WEITERHIN_OK`
Expected: `SIGNATUR_WEITERHIN_OK` (die Umgebung entstand extern; das Bündel ist unverändert).

- [ ] **Step 4: Commit**

```bash
git add scripts/verify-bundled-engine.sh
git commit -m "M8-Verteilung Teil1: Abnahmeskript — gebündelte Engine startet in sauberer Umgebung"
```

---

## Selbstprüfung (nach dem Schreiben, gegen die Spec)

- **Spec-Abdeckung:** Baustein 1 der Spec (Engine-Bündelung, Bundled-vs-Dev-Erkennung, „Dev-Ablauf
  unberührt", externe Umgebung) ist durch Tasks 1–5 abgedeckt. Der Plan-B-Weg der Spec (uv
  mitliefern) ist hier der **Hauptweg** — durch den Spike vom 2026-07-16 als tragfähig belegt (das
  volle Einbetten von Python entfällt).
- **Nicht in diesem Plan (Folge-Pläne):** Modell-Bootstrap-Endpunkt + Erststart-Fenster (Teil 2);
  Sparkle + `release`-Skript + Schlüssel-Sicherung (Teil 3). Die `HF_HOME`-Umleitung wird hier nur
  als Umgebungsvariable gesetzt; das sichtbare Download-Erlebnis kommt in Teil 2.
- **Austauschbarkeit:** kein Engine-Python-Code angefasst — Vertrag unberührt. ✓
- **Typkonsistenz:** `EngineLaunch` (Felder `executable/arguments/workingDirectory/environment`)
  identisch in Task 1 (Definition), Task 2 (Konsum) und Task 3 (Erzeugung). Init-Signatur
  `DefaultSidecarLifecycle(...launch:socketPath:...)` in Task 2 definiert, in Task 3 verwendet. ✓

## Ausführungs-Hinweis

Reihenfolge strikt 1→5 (Task 2 braucht Task 1, Task 3 braucht 1+2, Task 5 braucht 4). Nach Task 5
ist die App auf einem frischen Mac lauffähig (manuell installiert) — der Meilenstein bleibt
lauffähig. Danach Teil 2 planen.
