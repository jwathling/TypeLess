# M3 — Swift-Shell-Skelett Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine SwiftUI-MenuBarExtra-App, die den Python-Sidecar startet (oder eine laufende Instanz übernimmt), seinen Zustand kennt und ihn verständlich anzeigt — inklusive Berechtigungsstatus.

**Architecture:** Swift-Package mit drei Zielen. `TypeLessCore` ist eine Bibliothek **ohne jede UI** (Protokolle, Implementierungen, Zustandsautomat) und damit vollständig testbar; `TypeLess` ist die dünne SwiftUI-App darüber; `TypeLessCoreTests` testet die Bibliothek. Ein Skript packt das Binary in ein `.app`-Bundle, weil macOS Berechtigungen an eine Bundle-Identität vergibt, nicht an ein nacktes Binary.

**Tech Stack:** Swift 6.3 (Xcode 26.6), SwiftUI (`MenuBarExtra`), Network.framework (`NWConnection` über `NWEndpoint.unix`), Observation (`@Observable`), swift-testing (`import Testing`, `@Test`, `#expect`).

## Verifizierte Vorbedingungen

Diese Annahmen sind auf dem Zielrechner **bereits geprüft** — nicht erneut in Frage stellen:

- `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`; `swift test` läuft mit swift-testing.
- `@Observable` und `MenuBarExtra` bauen mit `swift-tools-version: 6.0`, Plattform `.macOS(.v14)`.
- `NWEndpoint.unix(path:)` funktioniert; ein Swift-Client hat erfolgreich `GET /health` gegen den **echten** Sidecar gesprochen.
- Der Sidecar antwortet mit `Content-Length` und **ohne** `Transfer-Encoding: chunked`.
- `NWListener` kann in Tests einen eigenen Unix-Socket-Server hochziehen (Fake-Sidecar).

## Global Constraints

- Swift 6.3, `swift-tools-version: 6.0`, Plattform `.macOS(.v14)`, strict concurrency (Swift-6-Sprachmodus).
- Kommentare und Docstrings auf **Deutsch** — wie im Python-Teil des Projekts.
- `TypeLessCore` importiert **niemals** SwiftUI oder AppKit-UI. Es darf AVFoundation/ApplicationServices für Berechtigungsabfragen importieren.
- Jede austauschbare Komponente steckt hinter einem **Protokoll** (`SidecarClient`, `SidecarLifecycle`, `PermissionsService`, `SettingsStore`). Die einzige Stelle, die konkrete Typen kennt, ist die Komposition beim App-Start. Dieser Vertrag darf nicht aufgeweicht werden — er ist der Grund, warum die Tests ohne Fenster und ohne echten Sidecar laufen.
- **Alle Tests laufen ohne den echten Sidecar** (Fake-Server über `NWListener`, Mocks) und **ohne feste Wartezeiten**. Die einzige Ausnahme ist die Handprobe in Task 7.
- `swift build` und `swift test` (aus `apps/macos/`) müssen nach jeder Task grün sein.
- Der Sidecar-Vertrag aus M2 ist bindend: `503` = „läuft, aber kaputt" ≠ keine Verbindung. `refined: false` ist **kein** Fehler, sondern ein Ergebnis.

## File Structure

| Datei | Verantwortung |
|---|---|
| `apps/macos/Package.swift` | Paketdefinition, drei Ziele |
| `apps/macos/Sources/TypeLessCore/Sidecar/HTTPUnixTransport.swift` | HTTP/1.1 über `NWConnection` zu einer Socket-Datei. Kennt keine TypeLess-Semantik. |
| `apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift` | Protokoll + typisierte Implementierung (die vier Endpunkte, Fehlerabbildung) |
| `apps/macos/Sources/TypeLessCore/Sidecar/SidecarModels.swift` | `HealthState`, `ProcessResult`, `Mode`, `SidecarError` |
| `apps/macos/Sources/TypeLessCore/Sidecar/SidecarLifecycle.swift` | Protokoll + Prozessstart (übernehmen oder starten) |
| `apps/macos/Sources/TypeLessCore/Permissions/PermissionsService.swift` | Protokoll + echte Abfrage (Mikrofon, Accessibility, Input-Monitoring) |
| `apps/macos/Sources/TypeLessCore/Settings/SettingsStore.swift` | Protokoll + `UserDefaults`-Implementierung |
| `apps/macos/Sources/TypeLessCore/AppState.swift` | Zustandsautomat + Polling. Das Einzige, was die UI kennt. |
| `apps/macos/Sources/TypeLess/TypeLessApp.swift` | SwiftUI `MenuBarExtra`. Dünn. |
| `apps/macos/Tests/TypeLessCoreTests/FakeSidecarServer.swift` | Test-Helfer: echter Unix-Socket-Server mit vorgegebenen Antworten |
| `apps/macos/Tests/TypeLessCoreTests/*Tests.swift` | Tests je Komponente |
| `scripts/build-app.sh` | Bundle bauen: Struktur, `Info.plist`, ad-hoc-Signatur |

---

### Task 1: Paketgerüst, Testinfrastruktur und Bundle-Skript

**Ziel dieser Task:** Ein lauffähiges Fundament. Am Ende erzeugt `bash scripts/build-app.sh` ein `TypeLess.app`, das in der Menüleiste erscheint (mit Platzhalter-Inhalt), und `swift test` läuft grün.

**Files:**
- Create: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/TypeLessCore/Version.swift`
- Create: `apps/macos/Sources/TypeLess/TypeLessApp.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/VersionTests.swift`
- Create: `scripts/build-app.sh`
- Create: `apps/macos/.gitignore`
- Modify: `apps/macos/README.md` (Platzhaltertext ersetzen)

**Interfaces:**
- Consumes: nichts (erste Task)
- Produces: `TypeLessCore.coreVersion: String` (nur, damit die Testinfrastruktur etwas zu prüfen hat und Task 2 auf einem grünen Gerüst aufsetzt).

- [ ] **Step 1: Paket anlegen**

`apps/macos/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeLess",
    platforms: [.macOS(.v14)],
    targets: [
        // Bibliothek ohne jede UI — deshalb vollständig testbar, ohne ein Fenster zu öffnen.
        .target(name: "TypeLessCore"),
        // Die SwiftUI-Hülle. Bewusst dünn: zeigt nur an, was AppState sagt.
        .executableTarget(name: "TypeLess", dependencies: ["TypeLessCore"]),
        .testTarget(name: "TypeLessCoreTests", dependencies: ["TypeLessCore"]),
    ]
)
```

`apps/macos/Sources/TypeLessCore/Version.swift`:

```swift
/// Version des Engine-Kerns. Dient in M3 zugleich als Beleg, dass die Testinfrastruktur greift.
public let coreVersion = "0.3.0"
```

`apps/macos/.gitignore`:

```
.build/
.swiftpm/
TypeLess.app/
```

- [ ] **Step 2: Test schreiben**

`apps/macos/Tests/TypeLessCoreTests/VersionTests.swift`:

```swift
import Testing
@testable import TypeLessCore

@Test func coreVersionIstGesetzt() {
    #expect(coreVersion == "0.3.0")
}
```

- [ ] **Step 3: Test laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS — „1 test … passed". Belegt, dass swift-testing greift.

- [ ] **Step 4: Platzhalter-App schreiben**

`apps/macos/Sources/TypeLess/TypeLessApp.swift`:

```swift
import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    var body: some Scene {
        MenuBarExtra("TypeLess", systemImage: "mic") {
            Text("TypeLess \(coreVersion)")
            Divider()
            Button("TypeLess beenden") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

- [ ] **Step 5: Bundle-Skript schreiben**

`scripts/build-app.sh`:

```bash
#!/usr/bin/env bash
# Baut TypeLess.app aus dem Swift-Package.
#
# Ein echtes .app-Bundle ist nicht Kosmetik: macOS vergibt Mikrofon- und
# Accessibility-Rechte an eine Bundle-Identität, nicht an ein nacktes Binary. Ohne Bundle
# würden die Rechte dem Terminal erteilt statt TypeLess.
set -euo pipefail

cd "$(dirname "$0")/../apps/macos"

CONFIG="${1:-debug}"
APP="TypeLess.app"
BUNDLE_ID="de.typeless.TypeLess"

echo "== swift build ($CONFIG) =="
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TypeLess"

echo "== Bundle zusammensetzen =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TypeLess"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TypeLess</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>TypeLess</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Kein Dock-Icon, kein Fenster: TypeLess ist ein Hintergrundwerkzeug. -->
    <key>LSUIElement</key><true/>
    <!-- Wird ab M4 gebraucht; muss beim ERSTEN Mikrofonzugriff bereits im Bundle stehen. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>TypeLess nimmt dein Diktat auf und verarbeitet es vollständig lokal auf diesem Mac.</string>
</dict>
</plist>
PLIST

echo "== ad-hoc signieren =="
# Ad-hoc-Signatur (-) reicht für den persönlichen Gebrauch. Achtung: Die Identität ändert
# sich bei jedem Neubau, macOS kann deshalb erneut nach Berechtigungen fragen.
# Ein echtes Zertifikat gibt es erst in M8.
codesign --force --deep --sign - "$APP"

echo "Fertig: apps/macos/$APP"
```

- [ ] **Step 6: Bauen und starten**

Run:
```bash
chmod +x scripts/build-app.sh
bash scripts/build-app.sh
open apps/macos/TypeLess.app
```
Expected: Ein Mikrofon-Symbol erscheint in der Menüleiste, **kein** Dock-Icon. Der Klick zeigt „TypeLess 0.3.0" und „TypeLess beenden".

- [ ] **Step 7: README aktualisieren**

`apps/macos/README.md` ersetzen: Kurzbeschreibung der drei Ziele, `swift test`, `bash ../../scripts/build-app.sh`, und der Hinweis zur Ad-hoc-Signatur (Berechtigungen können nach Neubau erneut abgefragt werden).

- [ ] **Step 8: Commit**

```bash
git add apps/macos scripts/build-app.sh
git commit -m "M3: Swift-Paket, Testinfrastruktur und App-Bundle-Skript"
```

---

### Task 2: HTTP über den Unix-Domain-Socket

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Sidecar/HTTPUnixTransport.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/FakeSidecarServer.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/HTTPUnixTransportTests.swift`

**Interfaces:**
- Consumes: nichts aus Task 1 außer dem Paketgerüst.
- Produces:
  - `struct HTTPResponse: Sendable { let status: Int; let headers: [String: String]; let body: Data }`
  - `struct HTTPUnixTransport: Sendable` mit `init(socketPath: String)` und
    `func send(method: String, path: String, body: Data?, contentType: String?, timeout: Duration) async throws -> HTTPResponse`
  - `enum TransportError: Error, Equatable { case unreachable, timedOut, malformedResponse }`
  - Test-Helfer `final class FakeSidecarServer` mit `init() throws`, `var socketPath: String`,
    `func respond(status: Int, json: String)`, `func stop()`, `var receivedRequests: [String]`

**Wichtige Designentscheidung, die du nicht wegvereinfachen darfst:** Die Anfrage schickt
`Connection: close`, und die Antwort wird **bis zum Verbindungsende** gelesen. Dadurch entfällt
das Parsen von `Content-Length` und `Transfer-Encoding` — die fehleranfälligste Stelle eines
selbstgebauten HTTP-Clients. Wir zahlen dafür eine neue Verbindung pro Anfrage; bei vier
kleinen Aufrufen ist das irrelevant (gemessen: unter 3 ms).

- [ ] **Step 1: Fake-Sidecar (Test-Helfer) schreiben**

`apps/macos/Tests/TypeLessCoreTests/FakeSidecarServer.swift`:

```swift
import Foundation
import Network

/// Ein echter Unix-Domain-Socket-Server für Tests.
///
/// Damit laufen die Client-Tests gegen eine echte Socket-Verbindung — ohne Python, ohne
/// Modelle, in Millisekunden. Die Antwort ist frei vorgebbar, auch die Fehlerfälle.
final class FakeSidecarServer: @unchecked Sendable {
    let socketPath: String
    private let listener: NWListener
    private let lock = NSLock()
    private var status = 200
    private var json = "{}"
    private var requests: [String] = []

    var receivedRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    init() throws {
        socketPath = "/tmp/tl-test-\(UUID().uuidString.prefix(8)).sock"
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: socketPath)
        listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    self.lock.lock(); self.requests.append(text); self.lock.unlock()
                }
                self.lock.lock()
                let (s, j) = (self.status, self.json)
                self.lock.unlock()

                let body = Data(j.utf8)
                let head = """
                HTTP/1.1 \(s) OK\r
                Content-Length: \(body.count)\r
                Content-Type: application/json\r
                Connection: close\r
                \r

                """
                conn.send(content: Data(head.utf8) + body,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    /// Legt die Antwort fest, die der Server ab jetzt liefert.
    func respond(status: Int, json: String) {
        lock.lock(); self.status = status; self.json = json; lock.unlock()
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
```

- [ ] **Step 2: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/HTTPUnixTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

@Test func liefertStatusUndBody() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: #"{"status":"ready"}"#)

    let transport = HTTPUnixTransport(socketPath: server.socketPath)
    let response = try await transport.send(method: "GET", path: "/health",
                                            body: nil, contentType: nil, timeout: .seconds(5))

    #expect(response.status == 200)
    #expect(String(decoding: response.body, as: UTF8.self) == #"{"status":"ready"}"#)
}

@Test func reichtFehlerStatusDurchStattZuWerfen() async throws {
    // 503 ist eine gültige Antwort ("läuft, aber kaputt"), kein Transportfehler.
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 503, json: #"{"detail":"kaputt"}"#)

    let transport = HTTPUnixTransport(socketPath: server.socketPath)
    let response = try await transport.send(method: "POST", path: "/process",
                                            body: Data([1, 2, 3, 4]),
                                            contentType: "application/octet-stream",
                                            timeout: .seconds(5))

    #expect(response.status == 503)
}

@Test func sendetMethodePfadUndBody() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 202, json: "{}")

    let transport = HTTPUnixTransport(socketPath: server.socketPath)
    _ = try await transport.send(method: "POST", path: "/process?mode=diktat",
                                 body: Data([0xAA, 0xBB]), contentType: "application/octet-stream",
                                 timeout: .seconds(5))

    let request = try #require(server.receivedRequests.first)
    #expect(request.hasPrefix("POST /process?mode=diktat HTTP/1.1"))
    #expect(request.contains("Content-Length: 2"))
    #expect(request.contains("Content-Type: application/octet-stream"))
}

@Test func meldetUnreachableWennKeinSocketDaIst() async throws {
    let transport = HTTPUnixTransport(socketPath: "/tmp/gibt-es-nicht-\(UUID().uuidString).sock")

    await #expect(throws: TransportError.unreachable) {
        _ = try await transport.send(method: "GET", path: "/health",
                                     body: nil, contentType: nil, timeout: .seconds(2))
    }
}
```

- [ ] **Step 3: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'HTTPUnixTransport' in scope"

- [ ] **Step 4: Transport implementieren**

`apps/macos/Sources/TypeLessCore/Sidecar/HTTPUnixTransport.swift`:

```swift
import Foundation
import Network

/// Eine HTTP-Antwort in ihrer rohen Form.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}

public enum TransportError: Error, Equatable, Sendable {
    /// Am Socket lauscht niemand — der Sidecar läuft nicht.
    case unreachable
    case timedOut
    case malformedResponse
}

/// HTTP/1.1 über einen Unix-Domain-Socket.
///
/// ``URLSession`` kann keine Unix-Sockets, deshalb dieser schlanke Eigenbau über
/// ``NWConnection``. Er kennt bewusst keine TypeLess-Semantik — nur Methode, Pfad, Bytes.
///
/// Die Anfrage schickt ``Connection: close``, die Antwort wird bis zum Verbindungsende
/// gelesen. Dadurch entfällt das Parsen von ``Content-Length``/``Transfer-Encoding`` — die
/// fehleranfälligste Stelle eines selbstgebauten Clients. Preis: eine Verbindung pro Anfrage,
/// bei vier kleinen Aufrufen irrelevant.
public struct HTTPUnixTransport: Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(
        method: String,
        path: String,
        body: Data?,
        contentType: String?,
        timeout: Duration
    ) async throws -> HTTPResponse {
        let raw = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await roundTrip(method: method, path: path,
                                                body: body, contentType: contentType) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return try Self.parse(raw)
    }

    private func roundTrip(method: String, path: String,
                           body: Data?, contentType: String?) async throws -> Data {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .global())

        var head = "\(method) \(path) HTTP/1.1\r\nHost: sidecar\r\nConnection: close\r\n"
        if let body { head += "Content-Length: \(body.count)\r\n" }
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        if let body { out.append(body) }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: out, completion: .contentProcessed { error in
                if error != nil { c.resume(throwing: TransportError.unreachable) } else { c.resume() }
            })
        }

        var raw = Data()
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, isComplete, error in
                    if error != nil {
                        c.resume(throwing: TransportError.unreachable)
                    } else if isComplete, data?.isEmpty ?? true {
                        c.resume(returning: nil)          // sauberes Verbindungsende
                    } else {
                        c.resume(returning: data ?? Data())
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            raw.append(chunk)
        }
        return raw
    }

    /// Zerlegt die Rohantwort in Status, Header und Body.
    static func parse(_ raw: Data) throws -> HTTPResponse {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw TransportError.malformedResponse
        }
        let headText = String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw TransportError.malformedResponse }

        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw TransportError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPResponse(status: status, headers: headers,
                            body: Data(raw[separator.upperBound...]))
    }
}
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (5 Tests: 1 aus Task 1 + 4 neue)

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "M3: HTTP-Transport über den Unix-Domain-Socket"
```

---

### Task 3: SidecarClient — die vier Endpunkte

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarModels.swift`
- Create: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/SidecarClientTests.swift`

**Interfaces:**
- Consumes: `HTTPUnixTransport`, `HTTPResponse`, `TransportError` (Task 2); `FakeSidecarServer` (Task 2).
- Produces:
  - `enum Mode: String, Sendable, CaseIterable { case diktat, prompt, email, slack, braindump }`
  - `struct HealthState: Sendable, Equatable { let status: String; let sttLoaded, llmLoaded, busy: Bool; let sttModel, llmModel: String; let error: String? }`
  - `struct ProcessResult: Sendable, Equatable { let finalText, rawText, dictionaryText: String; let mode: String; let language: String?; let refined: Bool; let fallbackReason: String?; let timingsMs: [String: Double] }`
  - `enum SidecarError: Error, Equatable, Sendable { case unreachable; case notReady(String); case processingFailed(String); case badRequest(String); case malformedResponse }`
  - `protocol SidecarClient: Sendable` mit `health()`, `preload()`, `process(pcm:mode:language:)`, `unload()`
  - `struct HTTPSidecarClient: SidecarClient` mit `init(socketPath: String)`

**Der Vertrag aus M2, den du exakt abbilden musst:**

| HTTP | Bedeutung | Swift |
|---|---|---|
| `200`, `refined: true` | fertiger Text | `ProcessResult(refined: true, …)` |
| `200`, `refined: false` | Text da, LLM ausgefallen — **kein Fehler!** | `ProcessResult(refined: false, fallbackReason: …)` |
| `503` | Sidecar läuft, ist aber kaputt | `SidecarError.notReady(Grund)` |
| `500` | Verarbeitung gescheitert (STT-Ausfall) | `SidecarError.processingFailed(Detail)` |
| `400` | ungültige Eingabe | `SidecarError.badRequest(Detail)` |
| keine Verbindung | Sidecar antwortet gar nicht | `SidecarError.unreachable` |

`503` und `unreachable` sind **verschiedene Zustände** und müssen es bleiben.

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/SidecarClientTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

private let gesundJSON = """
{"status":"ready","stt_loaded":true,"llm_loaded":false,"busy":false,
 "stt_model":"whisper","llm_model":"qwen","error":null}
"""

@Test func healthWirdUebersetzt() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: gesundJSON)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    let health = try await client.health()

    #expect(health.status == "ready")
    #expect(health.sttLoaded == true)
    #expect(health.llmLoaded == false)
    #expect(health.error == nil)
}

@Test func healthMeldetFehlerzustandMitGrund() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: """
    {"status":"failed","stt_loaded":false,"llm_loaded":false,"busy":false,
     "stt_model":"whisper","llm_model":"qwen","error":"STT-Warm-up fehlgeschlagen: 401"}
    """)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    let health = try await client.health()

    #expect(health.status == "failed")
    #expect(health.error == "STT-Warm-up fehlgeschlagen: 401")
}

@Test func unpolierterTextIstKeinFehler() async throws {
    // Der Kern des M2-Vertrags: LLM ausgefallen -> 200 mit refined=false. Das Diktat ist da.
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: """
    {"final_text":"roher text","raw_text":"roher text","dictionary_text":"roher text",
     "mode":"diktat","language":"de","refined":false,
     "fallback_reason":"LLM konnte nicht geladen werden","timings_ms":{"transcribe":1234.5}}
    """)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    let result = try await client.process(pcm: Data([1, 2, 3, 4]), mode: .diktat, language: nil)

    #expect(result.refined == false)
    #expect(result.finalText == "roher text")
    #expect(result.fallbackReason == "LLM konnte nicht geladen werden")
    #expect(result.timingsMs["transcribe"] == 1234.5)
}

@Test func notReadyIstNichtUnreachable() async throws {
    // 503 = "läuft, aber kaputt". Etwas ganz anderes als "antwortet gar nicht".
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 503, json: #"{"detail":"Sidecar nicht einsatzbereit: STT kaputt"}"#)

    let client = HTTPSidecarClient(socketPath: server.socketPath)

    await #expect(throws: SidecarError.notReady("Sidecar nicht einsatzbereit: STT kaputt")) {
        _ = try await client.process(pcm: Data([1, 2, 3, 4]), mode: .diktat, language: nil)
    }
}

@Test func sttAusfallWirdZuProcessingFailed() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 500, json: #"{"detail":"Verarbeitung fehlgeschlagen: STT kaputt"}"#)

    let client = HTTPSidecarClient(socketPath: server.socketPath)

    await #expect(throws: SidecarError.processingFailed("Verarbeitung fehlgeschlagen: STT kaputt")) {
        _ = try await client.process(pcm: Data([1, 2, 3, 4]), mode: .diktat, language: nil)
    }
}

@Test func fehlenderSidecarIstUnreachable() async throws {
    let client = HTTPSidecarClient(socketPath: "/tmp/gibt-es-nicht-\(UUID().uuidString).sock")

    await #expect(throws: SidecarError.unreachable) {
        _ = try await client.health()
    }
}

@Test func processSchicktModusUndPCM() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: """
    {"final_text":"t","raw_text":"t","dictionary_text":"t","mode":"email","language":null,
     "refined":true,"fallback_reason":null,"timings_ms":{}}
    """)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    _ = try await client.process(pcm: Data([0, 0, 0, 0]), mode: .email, language: "de")

    let request = try #require(server.receivedRequests.first)
    #expect(request.contains("mode=email"))
    #expect(request.contains("language=de"))
    #expect(request.contains("sample_rate=16000"))
    #expect(request.contains("application/octet-stream"))
}

@Test func preloadUndUnloadWerfenNichtBeiErfolg() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 202, json: "{}")

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    try await client.preload()

    server.respond(status: 200, json: gesundJSON)
    try await client.unload()
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'HTTPSidecarClient' in scope"

- [ ] **Step 3: Modelle implementieren**

`apps/macos/Sources/TypeLessCore/Sidecar/SidecarModels.swift`:

```swift
import Foundation

/// Ausgabemodus — Spiegelung von ``Mode`` aus der Engine (M1).
public enum Mode: String, Sendable, CaseIterable {
    case diktat, prompt, email, slack, braindump
}

/// Zustand des Sidecars (Antwort auf ``/health``).
public struct HealthState: Sendable, Equatable {
    public let status: String        // "starting" | "ready" | "failed"
    public let sttLoaded: Bool
    public let llmLoaded: Bool
    public let busy: Bool
    public let sttModel: String
    public let llmModel: String
    /// Klartext-Grund, wenn ``status == "failed"``.
    public let error: String?
}

/// Ergebnis eines Diktats — Spiegelung von ``ProcessResult`` aus der Engine.
public struct ProcessResult: Sendable, Equatable {
    public let finalText: String
    public let rawText: String
    public let dictionaryText: String
    public let mode: String
    public let language: String?
    /// ``false`` heißt: Das LLM ist ausgefallen, der Text ist der wörterbuch-bereinigte
    /// Rohtext. Das ist **kein Fehler** — das Diktat ist da, nur unpoliert.
    public let refined: Bool
    public let fallbackReason: String?
    public let timingsMs: [String: Double]
}

public enum SidecarError: Error, Equatable, Sendable {
    /// Am Socket lauscht niemand — der Sidecar läuft nicht.
    case unreachable
    /// Der Sidecar läuft, ist aber nicht einsatzbereit (STT-Warm-up gescheitert). HTTP 503.
    /// Ausdrücklich etwas **anderes** als ``unreachable``.
    case notReady(String)
    /// Die Verarbeitung selbst ist gescheitert (STT-Ausfall). HTTP 500.
    case processingFailed(String)
    /// Ungültige Anfrage. HTTP 400.
    case badRequest(String)
    case malformedResponse
}

// MARK: - JSON-Formen des Sidecars (snake_case)

struct HealthDTO: Decodable {
    let status: String
    let stt_loaded: Bool
    let llm_loaded: Bool
    let busy: Bool
    let stt_model: String
    let llm_model: String
    let error: String?
}

struct ProcessDTO: Decodable {
    let final_text: String
    let raw_text: String
    let dictionary_text: String
    let mode: String
    let language: String?
    let refined: Bool
    let fallback_reason: String?
    let timings_ms: [String: Double]
}

struct DetailDTO: Decodable {
    let detail: String
}
```

- [ ] **Step 4: Client implementieren**

`apps/macos/Sources/TypeLessCore/Sidecar/SidecarClient.swift`:

```swift
import Foundation

/// Spricht mit dem Sidecar. Vier Methoden, exakt die vier Endpunkte aus M2.
public protocol SidecarClient: Sendable {
    func health() async throws -> HealthState
    func preload() async throws
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult
    func unload() async throws
}

/// Die echte Implementierung: HTTP über den Unix-Domain-Socket.
public struct HTTPSidecarClient: SidecarClient {
    private let transport: HTTPUnixTransport

    /// Die Engine erwartet 16-kHz-Mono-Float32. Die Rate steht nicht in den Rohdaten und muss
    /// deshalb mitgeschickt werden (siehe M2).
    private static let sampleRate = 16_000

    public init(socketPath: String) {
        transport = HTTPUnixTransport(socketPath: socketPath)
    }

    public func health() async throws -> HealthState {
        let response = try await request("GET", "/health", body: nil, contentType: nil,
                                         timeout: .seconds(5))
        let dto: HealthDTO = try decode(response)
        return HealthState(status: dto.status, sttLoaded: dto.stt_loaded, llmLoaded: dto.llm_loaded,
                           busy: dto.busy, sttModel: dto.stt_model, llmModel: dto.llm_model,
                           error: dto.error)
    }

    public func preload() async throws {
        _ = try await request("POST", "/preload", body: nil, contentType: nil, timeout: .seconds(5))
    }

    public func unload() async throws {
        _ = try await request("POST", "/unload", body: nil, contentType: nil, timeout: .seconds(30))
    }

    public func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        var path = "/process?mode=\(mode.rawValue)&sample_rate=\(Self.sampleRate)"
        if let language { path += "&language=\(language)" }

        // Großzügig: Ein langes Diktat plus LLM-Ladezeit kann eine Weile dauern.
        let response = try await request("POST", path, body: pcm,
                                         contentType: "application/octet-stream",
                                         timeout: .seconds(180))
        let dto: ProcessDTO = try decode(response)
        return ProcessResult(finalText: dto.final_text, rawText: dto.raw_text,
                             dictionaryText: dto.dictionary_text, mode: dto.mode,
                             language: dto.language, refined: dto.refined,
                             fallbackReason: dto.fallback_reason, timingsMs: dto.timings_ms)
    }

    // MARK: - Intern

    /// Führt die Anfrage aus und übersetzt HTTP-Fehlerstatus in ``SidecarError``.
    private func request(_ method: String, _ path: String, body: Data?, contentType: String?,
                         timeout: Duration) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(method: method, path: path, body: body,
                                                contentType: contentType, timeout: timeout)
        } catch TransportError.unreachable, TransportError.timedOut {
            throw SidecarError.unreachable
        } catch {
            throw SidecarError.malformedResponse
        }

        switch response.status {
        case 200, 202:
            return response
        case 400:
            throw SidecarError.badRequest(detail(response))
        case 503:
            // "Läuft, aber kaputt" — ausdrücklich nicht unreachable.
            throw SidecarError.notReady(detail(response))
        default:
            throw SidecarError.processingFailed(detail(response))
        }
    }

    private func detail(_ response: HTTPResponse) -> String {
        (try? JSONDecoder().decode(DetailDTO.self, from: response.body))?.detail
            ?? String(decoding: response.body, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw SidecarError.malformedResponse
        }
    }
}
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (13 Tests)

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "M3: SidecarClient (vier Endpunkte, Fehlerabbildung aus dem M2-Vertrag)"
```

---

### Task 4: SidecarLifecycle — übernehmen oder starten

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Sidecar/SidecarLifecycle.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/SidecarLifecycleTests.swift`

**Interfaces:**
- Consumes: `SidecarClient`, `HealthState`, `SidecarError` (Task 3).
- Produces:
  - `enum SidecarOwnership: Sendable, Equatable { case adopted, spawned }`
  - `protocol SidecarLifecycle: Sendable { func start() async throws -> SidecarOwnership; func stop() async }`
  - `protocol ProcessRunner: Sendable` mit `func run(executable: String, arguments: [String], workingDirectory: String) throws -> ProcessHandle` und `protocol ProcessHandle: Sendable { func terminate(); var isRunning: Bool { get } }`
  - `actor DefaultSidecarLifecycle: SidecarLifecycle` mit
    `init(client: SidecarClient, runner: ProcessRunner, engineDirectory: String, uvPath: String, readyTimeout: Duration, pollInterval: Duration)`
  - `enum LifecycleError: Error, Equatable { case engineDirectoryMissing(String); case uvMissing(String); case readyTimeout; case failed(String) }`

**Zentrale Regel:** `stop()` beendet **nur**, was `start()` selbst gestartet hat. Eine übernommene
Instanz bleibt laufen — wer sie gestartet hat, beendet sie. Wer das aufweicht, killt beim
Beenden der App den Sidecar, den der Entwickler im Terminal für das nächste Experiment
laufen hat.

**Warum ein `ProcessRunner`-Protokoll:** Damit die Tests keinen echten Prozess starten müssen.
Die echte Implementierung (`FoundationProcessRunner`) benutzt `Foundation.Process`.

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/SidecarLifecycleTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

// MARK: - Test-Doubles

final class SpyProcessHandle: ProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var terminateCount = 0

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func terminate() {
        lock.lock(); terminateCount += 1; running = false; lock.unlock()
    }
}

final class SpyProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startedCommands: [[String]] = []
    let handle = SpyProcessHandle()

    func run(executable: String, arguments: [String], workingDirectory: String) throws -> ProcessHandle {
        lock.lock(); startedCommands.append([executable] + arguments); lock.unlock()
        return handle
    }
}

/// Client, dessen Antworten der Test Schritt für Schritt vorgibt.
final class ScriptedClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<HealthState, SidecarError>]
    private(set) var healthCalls = 0

    init(_ script: [Result<HealthState, SidecarError>]) { self.script = script }

    func health() async throws -> HealthState {
        lock.lock()
        healthCalls += 1
        let next = script.isEmpty ? Result<HealthState, SidecarError>.failure(.unreachable)
                                  : script.removeFirst()
        lock.unlock()
        return try next.get()
    }

    func preload() async throws {}
    func unload() async throws {}
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        fatalError("in diesen Tests nicht benutzt")
    }
}

func health(_ status: String, error: String? = nil) -> HealthState {
    HealthState(status: status, sttLoaded: status == "ready", llmLoaded: false, busy: false,
                sttModel: "whisper", llmModel: "qwen", error: error)
}

func makeLifecycle(client: SidecarClient, runner: ProcessRunner) -> DefaultSidecarLifecycle {
    DefaultSidecarLifecycle(client: client, runner: runner,
                            engineDirectory: FileManager.default.temporaryDirectory.path,
                            uvPath: "/bin/echo",          // existiert garantiert
                            readyTimeout: .milliseconds(500),
                            pollInterval: .milliseconds(10))
}

// MARK: - Tests

@Test func uebernimmtLaufendeInstanzUndStartetKeinenProzess() async throws {
    let runner = SpyProcessRunner()
    let lifecycle = makeLifecycle(client: ScriptedClient([.success(health("ready"))]), runner: runner)

    let ownership = try await lifecycle.start()

    #expect(ownership == .adopted)
    #expect(runner.startedCommands.isEmpty, "eine laufende Instanz darf nicht neu gestartet werden")
}

@Test func beendetUebernommeneInstanzNicht() async throws {
    // Wer sie gestartet hat, beendet sie. Sonst killt die App den Sidecar,
    // den der Entwickler im Terminal laufen hat.
    let runner = SpyProcessRunner()
    let lifecycle = makeLifecycle(client: ScriptedClient([.success(health("ready"))]), runner: runner)
    _ = try await lifecycle.start()

    await lifecycle.stop()

    #expect(runner.handle.terminateCount == 0)
}

@Test func startetProzessWennNiemandAntwortet() async throws {
    let runner = SpyProcessRunner()
    let client = ScriptedClient([
        .failure(.unreachable),          // erster Blick: niemand da
        .success(health("starting")),    // gestartet, STT lädt
        .success(health("ready")),       // fertig
    ])
    let lifecycle = makeLifecycle(client: client, runner: runner)

    let ownership = try await lifecycle.start()

    #expect(ownership == .spawned)
    #expect(runner.startedCommands.count == 1)
    let command = try #require(runner.startedCommands.first)
    #expect(command.contains("typeless_engine.server"))
}

@Test func beendetSelbstGestartetenProzess() async throws {
    let runner = SpyProcessRunner()
    let client = ScriptedClient([.failure(.unreachable), .success(health("ready"))])
    let lifecycle = makeLifecycle(client: client, runner: runner)
    _ = try await lifecycle.start()

    await lifecycle.stop()

    #expect(runner.handle.terminateCount == 1)
}

@Test func meldetTimeoutWennReadyNichtKommt() async throws {
    // Erst niemand da, dann bleibt der gestartete Sidecar für immer "starting".
    // Nach dem Skript liefert ScriptedClient .unreachable — auch das ist kein "ready",
    // der Timeout muss also greifen.
    let script: [Result<HealthState, SidecarError>] =
        [.failure(.unreachable)] + Array(repeating: .success(health("starting")), count: 20)
    let lifecycle = makeLifecycle(client: ScriptedClient(script), runner: SpyProcessRunner())

    await #expect(throws: LifecycleError.readyTimeout) {
        _ = try await lifecycle.start()
    }
}

@Test func meldetFehlerzustandDesSidecars() async throws {
    let runner = SpyProcessRunner()
    let client = ScriptedClient([
        .failure(.unreachable),
        .success(health("failed", error: "STT-Warm-up fehlgeschlagen: 401")),
    ])
    let lifecycle = makeLifecycle(client: client, runner: runner)

    await #expect(throws: LifecycleError.failed("STT-Warm-up fehlgeschlagen: 401")) {
        _ = try await lifecycle.start()
    }
}

@Test func meldetFehlendesEngineVerzeichnis() async throws {
    let lifecycle = DefaultSidecarLifecycle(
        client: ScriptedClient([.failure(.unreachable)]),
        runner: SpyProcessRunner(),
        engineDirectory: "/gibt/es/nicht",
        uvPath: "/bin/echo",
        readyTimeout: .milliseconds(500),
        pollInterval: .milliseconds(10))

    await #expect(throws: LifecycleError.engineDirectoryMissing("/gibt/es/nicht")) {
        _ = try await lifecycle.start()
    }
}

@Test func meldetFehlendesUv() async throws {
    let lifecycle = DefaultSidecarLifecycle(
        client: ScriptedClient([.failure(.unreachable)]),
        runner: SpyProcessRunner(),
        engineDirectory: FileManager.default.temporaryDirectory.path,
        uvPath: "/gibt/es/nicht/uv",
        readyTimeout: .milliseconds(500),
        pollInterval: .milliseconds(10))

    await #expect(throws: LifecycleError.uvMissing("/gibt/es/nicht/uv")) {
        _ = try await lifecycle.start()
    }
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'DefaultSidecarLifecycle' in scope"

- [ ] **Step 3: Lifecycle implementieren**

`apps/macos/Sources/TypeLessCore/Sidecar/SidecarLifecycle.swift`:

```swift
import Foundation

/// Wer den Sidecar besitzt.
public enum SidecarOwnership: Sendable, Equatable {
    /// Es lief bereits einer — wir haben ihn übernommen und fassen ihn nicht an.
    case adopted
    /// Wir haben ihn gestartet und beenden ihn auch wieder.
    case spawned
}

public enum LifecycleError: Error, Equatable, Sendable {
    case engineDirectoryMissing(String)
    case uvMissing(String)
    case readyTimeout
    /// Der Sidecar ist hochgekommen, meldet aber ``failed`` (z. B. STT-Modell kaputt).
    case failed(String)
}

/// Ein gestarteter Kindprozess.
public protocol ProcessHandle: Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// Startet Prozesse. Als Protokoll, damit Tests keinen echten Prozess starten müssen.
public protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: String) throws -> ProcessHandle
}

/// Bringt den Sidecar hoch.
public protocol SidecarLifecycle: Sendable {
    func start() async throws -> SidecarOwnership
    func stop() async
}

public actor DefaultSidecarLifecycle: SidecarLifecycle {
    private let client: SidecarClient
    private let runner: ProcessRunner
    private let engineDirectory: String
    private let uvPath: String
    private let readyTimeout: Duration
    private let pollInterval: Duration

    /// Nur gesetzt, wenn **wir** den Prozess gestartet haben.
    private var ownProcess: ProcessHandle?

    public init(client: SidecarClient, runner: ProcessRunner, engineDirectory: String,
                uvPath: String, readyTimeout: Duration = .seconds(90),
                pollInterval: Duration = .seconds(1)) {
        self.client = client
        self.runner = runner
        self.engineDirectory = engineDirectory
        self.uvPath = uvPath
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
    }

    public func start() async throws -> SidecarOwnership {
        // 1. Lauscht schon jemand? Dann übernehmen — spart beim Entwickeln das Warm-up.
        if let existing = try? await client.health() {
            if existing.status == "failed" {
                throw LifecycleError.failed(existing.error ?? "unbekannter Fehler")
            }
            if existing.status == "ready" {
                return .adopted
            }
            // "starting": Eine fremde Instanz fährt gerade hoch — abwarten, nicht dazwischenfunken.
            try await waitForReady()
            return .adopted
        }

        // 2. Niemand da: selbst starten.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: engineDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LifecycleError.engineDirectoryMissing(engineDirectory)
        }
        guard FileManager.default.isExecutableFile(atPath: uvPath) else {
            throw LifecycleError.uvMissing(uvPath)
        }

        ownProcess = try runner.run(
            executable: uvPath,
            arguments: ["run", "python", "-m", "typeless_engine.server"],
            workingDirectory: engineDirectory)

        try await waitForReady()
        return .spawned
    }

    /// Beendet **nur**, was wir selbst gestartet haben.
    public func stop() async {
        ownProcess?.terminate()
        ownProcess = nil
    }

    /// Pollt ``/health``, bis ``ready`` gemeldet wird. Ohne feste Wartezeit: Der Timeout ist
    /// die Reißleine, nicht die Taktung.
    private func waitForReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: readyTimeout)

        while ContinuousClock.now < deadline {
            if let state = try? await client.health() {
                switch state.status {
                case "ready":
                    return
                case "failed":
                    throw LifecycleError.failed(state.error ?? "unbekannter Fehler")
                default:
                    break  // "starting" — weiter warten
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
        throw LifecycleError.readyTimeout
    }
}

/// Die echte Implementierung über ``Foundation.Process``.
public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: String, arguments: [String],
                    workingDirectory: String) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        try process.run()
        return FoundationProcessHandle(process: process)
    }
}

struct FoundationProcessHandle: ProcessHandle {
    private let process: Process

    init(process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()   // SIGTERM — der Sidecar fährt sauber herunter (siehe M2)
    }
}
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (21 Tests)

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "M3: SidecarLifecycle (laufende Instanz übernehmen, sonst selbst starten)"
```

---

### Task 5: Berechtigungen und Einstellungen

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Permissions/PermissionsService.swift`
- Create: `apps/macos/Sources/TypeLessCore/Settings/SettingsStore.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: nichts.
- Produces:
  - `enum Permission: Sendable, CaseIterable { case microphone, accessibility, inputMonitoring }` mit `var title: String`
  - `struct PermissionStatus: Sendable, Equatable { let microphone, accessibility, inputMonitoring: Bool }`
  - `protocol PermissionsService: Sendable { func status() -> PermissionStatus; func openSettings(for: Permission) }`
  - `struct SystemPermissionsService: PermissionsService`
  - `protocol SettingsStore: Sendable { var engineDirectory: String { get set }; var socketPath: String { get set }; var uvPath: String { get set } }`
  - `final class UserDefaultsSettingsStore: SettingsStore`
  - `final class InMemorySettingsStore: SettingsStore` (für Tests und Previews)

**Wichtig:** `PermissionsService` fragt **nichts** aktiv an. macOS zeigt seinen Dialog ohnehin
erst beim ersten echten Zugriff (Mikrofon in M4, Accessibility in M5). M3 zeigt nur den
Ist-Zustand und öffnet auf Wunsch die Systemeinstellungen.

- [ ] **Step 1: Test für den SettingsStore schreiben**

`apps/macos/Tests/TypeLessCoreTests/SettingsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

@Test func liefertDefaultsWennNichtsGesetztIst() {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let store = UserDefaultsSettingsStore(defaults: defaults)

    #expect(store.socketPath.hasSuffix("/Library/Application Support/TypeLess/typeless.sock"))
    #expect(store.engineDirectory.hasSuffix("/engine"))
    #expect(store.uvPath.hasSuffix("/uv"))
}

@Test func merktSichGeaenderteWerte() {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let store = UserDefaultsSettingsStore(defaults: defaults)

    store.engineDirectory = "/woanders/engine"

    let wieder = UserDefaultsSettingsStore(defaults: defaults)
    #expect(wieder.engineDirectory == "/woanders/engine")
}

@Test func inMemoryStoreFunktioniertFuerTests() {
    let store = InMemorySettingsStore(engineDirectory: "/a", socketPath: "/b", uvPath: "/c")

    store.engineDirectory = "/x"

    #expect(store.engineDirectory == "/x")
    #expect(store.socketPath == "/b")
}
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'UserDefaultsSettingsStore' in scope"

- [ ] **Step 3: SettingsStore implementieren**

`apps/macos/Sources/TypeLessCore/Settings/SettingsStore.swift`:

```swift
import Foundation

/// Die wenigen Einstellungen, die M3 braucht. Ein Settings-Fenster kommt erst in M7.
public protocol SettingsStore: Sendable {
    var engineDirectory: String { get set }
    var socketPath: String { get set }
    var uvPath: String { get set }
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var engineDirectory: String {
        get { defaults.string(forKey: "engineDirectory") ?? Self.defaultEngineDirectory }
        set { defaults.set(newValue, forKey: "engineDirectory") }
    }

    public var socketPath: String {
        get { defaults.string(forKey: "socketPath") ?? Self.defaultSocketPath }
        set { defaults.set(newValue, forKey: "socketPath") }
    }

    public var uvPath: String {
        get { defaults.string(forKey: "uvPath") ?? Self.defaultUvPath }
        set { defaults.set(newValue, forKey: "uvPath") }
    }

    // MARK: - Defaults

    /// Muss zum Default in ``engine/typeless_engine/config.py`` passen.
    static var defaultSocketPath: String {
        NSHomeDirectory() + "/Library/Application Support/TypeLess/typeless.sock"
    }

    /// Im Dev-Betrieb das Repo. Wird in M8 durch einen gebündelten Sidecar ersetzt.
    static var defaultEngineDirectory: String {
        NSHomeDirectory() + "/Projekte/TypeLess/engine"
    }

    /// uv liegt nach der Standardinstallation hier. Der PATH einer .app-Umgebung enthält
    /// ~/.local/bin nicht — deshalb der absolute Pfad.
    static var defaultUvPath: String {
        NSHomeDirectory() + "/.local/bin/uv"
    }
}

/// Für Tests und Previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    public var engineDirectory: String
    public var socketPath: String
    public var uvPath: String

    public init(engineDirectory: String, socketPath: String, uvPath: String) {
        self.engineDirectory = engineDirectory
        self.socketPath = socketPath
        self.uvPath = uvPath
    }
}
```

- [ ] **Step 4: PermissionsService implementieren**

`apps/macos/Sources/TypeLessCore/Permissions/PermissionsService.swift`:

```swift
import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Die drei Berechtigungen, die TypeLess braucht.
public enum Permission: Sendable, CaseIterable {
    /// Für die Aufnahme (ab M4).
    case microphone
    /// Für das Text-Einfügen an der Cursorposition (ab M5).
    case accessibility
    /// Für den globalen Hotkey (ab M4).
    case inputMonitoring

    public var title: String {
        switch self {
        case .microphone: "Mikrofon"
        case .accessibility: "Bedienungshilfen"
        case .inputMonitoring: "Eingabeüberwachung"
        }
    }

    /// Wofür TypeLess das Recht braucht — für die Anzeige im Menü.
    public var purpose: String {
        switch self {
        case .microphone: "Aufnahme (ab M4)"
        case .accessibility: "Text einfügen (ab M5)"
        case .inputMonitoring: "Globaler Hotkey (ab M4)"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public struct PermissionStatus: Sendable, Equatable {
    public let microphone: Bool
    public let accessibility: Bool
    public let inputMonitoring: Bool

    public init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }
}

/// Liest den Ist-Zustand der Berechtigungen. Fragt **nichts** aktiv an — macOS zeigt seinen
/// Dialog ohnehin erst beim ersten echten Zugriff. M3 zeigt nur an, was fehlt.
public protocol PermissionsService: Sendable {
    func status() -> PermissionStatus
    func openSettings(for permission: Permission)
}

public struct SystemPermissionsService: PermissionsService {
    public init() {}

    public func status() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
    }

    public func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (24 Tests)

Hinweis: `SystemPermissionsService` wird **nicht** durch Unit-Tests abgedeckt — er fragt das
Betriebssystem, und dessen Antwort hängt am Bundle und an den TCC-Datenbanken. Verifiziert wird
er in der Handprobe (Task 7).

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "M3: Berechtigungsstatus und Einstellungen"
```

---

### Task 6: AppState — der Zustandsautomat

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/AppState.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `SidecarClient`, `SidecarLifecycle`, `SidecarOwnership`, `LifecycleError`, `HealthState` (Tasks 3–4); `PermissionsService`, `PermissionStatus` (Task 5).
- Produces:
  - `enum EngineState: Sendable, Equatable { case stopped, starting, ready, failed(String) }`
  - `@MainActor @Observable public final class AppState` mit
    `init(lifecycle: SidecarLifecycle, client: SidecarClient, permissions: PermissionsService, pollIntervalStarting: Duration, pollIntervalReady: Duration)`,
    `var engine: EngineState`, `var permissions: PermissionStatus`,
    `func start() async`, `func restart() async`, `func shutdown() async`,
    `func refreshPermissions()`

**Warum das Polling hier wohnt und nicht im Client:** Der Client bleibt zustandslos und
beantwortet genau eine Frage pro Aufruf. `AppState` entscheidet, *wann* gefragt wird — eng
getaktet während `starting` (damit der Sprung auf „Bereit" sofort sichtbar ist), entspannt im
Betrieb (um ein Wegsterben des Sidecars zu bemerken).

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/AppStateTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

// MARK: - Test-Doubles

final class FakeLifecycle: SidecarLifecycle, @unchecked Sendable {
    private let result: Result<SidecarOwnership, LifecycleError>
    private let lock = NSLock()
    /// Protokolliert die Aufrufe in ihrer Reihenfolge — so lässt sich prüfen, dass ein
    /// Neustart wirklich erst stoppt und dann startet.
    private(set) var calls: [String] = []

    init(_ result: Result<SidecarOwnership, LifecycleError>) { self.result = result }

    func start() async throws -> SidecarOwnership {
        lock.lock(); calls.append("start"); lock.unlock()
        return try result.get()
    }

    func stop() async {
        lock.lock(); calls.append("stop"); lock.unlock()
    }
}

final class StaticClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var state: Result<HealthState, SidecarError>

    init(_ state: Result<HealthState, SidecarError>) { self.state = state }

    func setState(_ new: Result<HealthState, SidecarError>) {
        lock.lock(); state = new; lock.unlock()
    }

    func health() async throws -> HealthState {
        lock.lock(); defer { lock.unlock() }
        return try state.get()
    }

    func preload() async throws {}
    func unload() async throws {}
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        fatalError("in diesen Tests nicht benutzt")
    }
}

struct FakePermissions: PermissionsService {
    let granted: Bool
    func status() -> PermissionStatus {
        PermissionStatus(microphone: granted, accessibility: granted, inputMonitoring: granted)
    }
    func openSettings(for permission: Permission) {}
}

@MainActor
func makeAppState(lifecycle: SidecarLifecycle, client: SidecarClient) -> AppState {
    AppState(lifecycle: lifecycle, client: client, permissions: FakePermissions(granted: true),
             pollIntervalStarting: .milliseconds(10), pollIntervalReady: .milliseconds(10))
}

// MARK: - Tests

@MainActor
@Test func startFuehrtNachReady() async {
    let state = makeAppState(lifecycle: FakeLifecycle(.success(.spawned)),
                             client: StaticClient(.success(health("ready"))))
    #expect(state.engine == .stopped)

    await state.start()

    #expect(state.engine == .ready)
}

@MainActor
@Test func startfehlerLandetInFailedMitKlartext() async {
    let state = makeAppState(
        lifecycle: FakeLifecycle(.failure(.engineDirectoryMissing("/gibt/es/nicht"))),
        client: StaticClient(.failure(.unreachable)))

    await state.start()

    #expect(state.engine == .failed("Engine nicht gefunden: /gibt/es/nicht"))
}

@MainActor
@Test func kaputterSidecarLandetInFailedMitGrundAusDerEngine() async {
    // Der Klartext kommt aus M2 — die App erfindet ihn nicht.
    let state = makeAppState(
        lifecycle: FakeLifecycle(.failure(.failed("STT-Warm-up fehlgeschlagen: 401"))),
        client: StaticClient(.failure(.unreachable)))

    await state.start()

    #expect(state.engine == .failed("STT-Warm-up fehlgeschlagen: 401"))
}

@MainActor
@Test func timeoutLandetInFailed() async {
    let state = makeAppState(lifecycle: FakeLifecycle(.failure(.readyTimeout)),
                             client: StaticClient(.failure(.unreachable)))

    await state.start()

    #expect(state.engine == .failed("Zeitüberschreitung beim Start der Engine"))
}

@MainActor
@Test func neustartStopptErstUndStartetDann() async {
    // `engine` ist bewusst nur lesbar (private(set)) — der Test setzt den Zustand deshalb
    // nicht von außen, sondern prüft die Reihenfolge über den Lifecycle.
    let lifecycle = FakeLifecycle(.success(.spawned))
    let state = makeAppState(lifecycle: lifecycle, client: StaticClient(.success(health("ready"))))
    await state.start()

    await state.restart()

    #expect(state.engine == .ready)
    #expect(lifecycle.calls == ["start", "stop", "start"],
            "der Neustart muss den alten Prozess erst beenden und dann neu starten")
}

@MainActor
@Test func shutdownStopptDenLifecycle() async {
    let lifecycle = FakeLifecycle(.success(.spawned))
    let state = makeAppState(lifecycle: lifecycle, client: StaticClient(.success(health("ready"))))
    await state.start()

    await state.shutdown()

    #expect(lifecycle.calls == ["start", "stop"])
    #expect(state.engine == .stopped)
}

@MainActor
@Test func berechtigungenWerdenGelesen() {
    let state = AppState(lifecycle: FakeLifecycle(.success(.adopted)),
                         client: StaticClient(.success(health("ready"))),
                         permissions: FakePermissions(granted: false),
                         pollIntervalStarting: .milliseconds(10),
                         pollIntervalReady: .milliseconds(10))

    state.refreshPermissions()

    #expect(state.permissions.microphone == false)
    #expect(state.permissions.accessibility == false)
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'AppState' in scope"

- [ ] **Step 3: AppState implementieren**

`apps/macos/Sources/TypeLessCore/AppState.swift`:

```swift
import Foundation
import Observation

/// Zustand der Engine, wie ihn der Nutzer im Menü sieht.
public enum EngineState: Sendable, Equatable {
    case stopped
    /// Der Sidecar läuft, das STT-Modell lädt (~20 s).
    case starting
    case ready
    /// Mit Klartext-Grund — kein bloßes rotes Symbol.
    case failed(String)
}

/// Führt alles zusammen, was die Oberfläche wissen muss. Das **Einzige**, was die SwiftUI-
/// Schicht kennt — und der Vorläufer des ``RecordingCoordinator`` aus M4.
@MainActor
@Observable
public final class AppState {
    public private(set) var engine: EngineState = .stopped
    public private(set) var permissions: PermissionStatus

    private let lifecycle: SidecarLifecycle
    private let client: SidecarClient
    private let permissionsService: PermissionsService
    private let pollIntervalStarting: Duration
    private let pollIntervalReady: Duration

    private var pollTask: Task<Void, Never>?

    public init(lifecycle: SidecarLifecycle,
                client: SidecarClient,
                permissions: PermissionsService,
                pollIntervalStarting: Duration = .seconds(1),
                pollIntervalReady: Duration = .seconds(5)) {
        self.lifecycle = lifecycle
        self.client = client
        permissionsService = permissions
        self.pollIntervalStarting = pollIntervalStarting
        self.pollIntervalReady = pollIntervalReady
        self.permissions = permissions.status()
    }

    // MARK: - Lebenszyklus

    public func start() async {
        engine = .starting
        do {
            _ = try await lifecycle.start()
            engine = .ready
            startPolling()
        } catch let error as LifecycleError {
            engine = .failed(Self.beschreibe(error))
        } catch {
            engine = .failed("Unerwarteter Fehler: \(error)")
        }
    }

    public func restart() async {
        stopPolling()
        await lifecycle.stop()
        await start()
    }

    public func shutdown() async {
        stopPolling()
        await lifecycle.stop()
        engine = .stopped
    }

    public func refreshPermissions() {
        permissions = permissionsService.status()
    }

    public func openSettings(for permission: Permission) {
        permissionsService.openSettings(for: permission)
    }

    // MARK: - Polling

    /// Fragt den Sidecar regelmäßig, wie es ihm geht — damit ein Wegsterben auffällt.
    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Ein Poll-Durchgang. Liefert das Intervall bis zum nächsten.
    private func pollOnce() async -> Duration {
        do {
            let health = try await client.health()
            switch health.status {
            case "ready":
                engine = .ready
                return pollIntervalReady
            case "starting":
                engine = .starting
                return pollIntervalStarting
            default:
                engine = .failed(health.error ?? "Engine meldet einen unbekannten Fehler")
                return pollIntervalReady
            }
        } catch SidecarError.unreachable {
            engine = .failed("Verbindung zur Engine verloren")
            return pollIntervalReady
        } catch {
            engine = .failed("Unerwarteter Fehler: \(error)")
            return pollIntervalReady
        }
    }

    // MARK: - Fehlertexte

    /// Übersetzt die technischen Fehler in etwas, das im Menü stehen kann.
    static func beschreibe(_ error: LifecycleError) -> String {
        switch error {
        case let .engineDirectoryMissing(path):
            "Engine nicht gefunden: \(path)"
        case let .uvMissing(path):
            "uv nicht gefunden: \(path)"
        case .readyTimeout:
            "Zeitüberschreitung beim Start der Engine"
        case let .failed(reason):
            reason        // Klartext aus der Engine (M2) — nicht überschreiben.
        }
    }
}
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (31 Tests)

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "M3: AppState (Zustandsautomat, Polling, Fehlertexte)"
```

---

### Task 7: Die Oberfläche und die Handprobe

**Files:**
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift` (Platzhalter aus Task 1 ersetzen)
- Create: `apps/macos/Sources/TypeLess/MenuContent.swift`
- Modify: `CLAUDE.md` (M3 abhaken)

**Interfaces:**
- Consumes: `AppState`, `EngineState`, `Permission`, `PermissionStatus` (Tasks 5–6); `HTTPSidecarClient` (Task 3); `DefaultSidecarLifecycle`, `FoundationProcessRunner` (Task 4); `UserDefaultsSettingsStore`, `SystemPermissionsService` (Task 5).
- Produces: nichts für spätere Tasks — dies ist die letzte.

- [ ] **Step 1: Menü-Inhalt schreiben**

`apps/macos/Sources/TypeLess/MenuContent.swift`:

```swift
import SwiftUI
import TypeLessCore

/// Der Inhalt des Menüleisten-Menüs. Zeigt nur an, was ``AppState`` sagt — keine Logik.
/// Kein ``@Bindable``: Das Menü schreibt nichts zurück, es liest nur. ``@Observable`` sorgt
/// dafür, dass es sich bei jeder Zustandsänderung neu zeichnet.
struct MenuContent: View {
    let state: AppState

    var body: some View {
        Text(engineText)

        Divider()

        ForEach(Permission.allCases, id: \.self) { permission in
            Button {
                state.openSettings(for: permission)
            } label: {
                let granted = state.permissions.isGranted(permission)
                Text("\(granted ? "✓" : "⚠") \(permission.title) — \(permission.purpose)")
            }
        }

        Divider()

        Button("Engine neu starten") {
            Task { await state.restart() }
        }

        Button("TypeLess beenden") {
            Task {
                await state.shutdown()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Der Zustand in einem Satz — bei einem Fehler mit dem Grund im Klartext.
    private var engineText: String {
        switch state.engine {
        case .stopped: "Engine: gestoppt"
        case .starting: "Engine: startet …"
        case .ready: "Engine: bereit"
        case let .failed(reason): "Engine-Fehler: \(reason)"
        }
    }
}
```

- [ ] **Step 2: App verdrahten**

`apps/macos/Sources/TypeLess/TypeLessApp.swift` (ersetzt den Platzhalter aus Task 1):

```swift
import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    @State private var state: AppState

    init() {
        // Die einzige Stelle, die konkrete Typen kennt (Komposition).
        let settings = UserDefaultsSettingsStore()
        let client = HTTPSidecarClient(socketPath: settings.socketPath)
        let lifecycle = DefaultSidecarLifecycle(
            client: client,
            runner: FoundationProcessRunner(),
            engineDirectory: settings.engineDirectory,
            uvPath: settings.uvPath)

        _state = State(wrappedValue: AppState(lifecycle: lifecycle,
                                              client: client,
                                              permissions: SystemPermissionsService()))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: symbol)
        }
        .menuBarExtraStyle(.menu)
        .task {
            await state.start()
        }
    }

    /// Das Symbol spiegelt den Zustand — man sieht auf einen Blick, ob TypeLess bereit ist.
    private var symbol: String {
        switch state.engine {
        case .ready: "mic.fill"
        case .starting, .stopped: "mic"
        case .failed: "mic.slash"
        }
    }
}
```

- [ ] **Step 3: Bauen und Tests**

Run: `cd apps/macos && swift build && swift test`
Expected: Build erfolgreich, 31 Tests grün.

- [ ] **Step 4: Handprobe — App startet die Engine selbst**

Stelle zunächst sicher, dass **kein** Sidecar läuft:

```bash
pkill -f "typeless_engine.server" || true
bash scripts/build-app.sh
open apps/macos/TypeLess.app
```

Erwartung:
- Ein Mikrofon-Symbol erscheint in der Menüleiste, **kein Dock-Icon**.
- Das Menü zeigt zunächst „Engine: startet …", nach ~20 s „Engine: bereit", und das Symbol
  wechselt zu `mic.fill`.
- Die drei Berechtigungen stehen mit ✓ oder ⚠ da. Ein Klick öffnet die Systemeinstellungen an
  der richtigen Stelle.
- `pgrep -fl typeless_engine.server` zeigt einen laufenden Sidecar.
- „TypeLess beenden" beendet die App **und** den Sidecar (`pgrep` findet danach nichts mehr).

- [ ] **Step 5: Handprobe — App übernimmt eine laufende Engine**

```bash
cd engine && uv run python -m typeless_engine.server &
# warten, bis "Sidecar bereit." im Log steht
open ../apps/macos/TypeLess.app
```

Erwartung:
- Das Menü zeigt **sofort** „Engine: bereit" (kein erneutes 20-s-Warm-up).
- Es läuft weiterhin **genau ein** Sidecar-Prozess (`pgrep -fl typeless_engine.server`).
- „TypeLess beenden" beendet die App, aber **nicht** den übernommenen Sidecar — er läuft
  weiter. (Wer ihn gestartet hat, beendet ihn.)

- [ ] **Step 6: Handprobe — Fehlerfall wird verständlich angezeigt**

```bash
pkill -f "typeless_engine.server" || true
defaults write de.typeless.TypeLess engineDirectory "/gibt/es/nicht"
open apps/macos/TypeLess.app
```

Erwartung: Das Menü zeigt „Engine-Fehler: Engine nicht gefunden: /gibt/es/nicht", das Symbol
ist `mic.slash`. Danach aufräumen:

```bash
defaults delete de.typeless.TypeLess engineDirectory
```

- [ ] **Step 7: CLAUDE.md aktualisieren**

M3 abhaken, die Struktur unter `apps/macos/` beschreiben, `bash scripts/build-app.sh` und
`cd apps/macos && swift test` als Befehle aufnehmen, und den Hinweis zur Ad-hoc-Signatur
festhalten (Berechtigungen können nach einem Neubau erneut abgefragt werden).

- [ ] **Step 8: Commit**

```bash
git add apps/macos CLAUDE.md
git commit -m "M3: MenuBarExtra-Oberfläche, gegen die echte Engine verifiziert"
```

---

## Offene Risiken

- **`.task` auf einer `MenuBarExtra`-Szene:** Ob der Modifier dort zuverlässig genau einmal
  feuert, ist nicht verifiziert. Falls nicht, ist die Alternative ein `NSApplicationDelegate`
  über `@NSApplicationDelegateAdaptor` mit `applicationDidFinishLaunching`. Die Logik in
  `AppState` bleibt davon unberührt — es geht nur darum, *wer* `start()` ruft.
- **Beenden über das Dock/`Cmd+Q`:** `NSApplication.shared.terminate` läuft nicht zwingend
  durch unser `shutdown()`. Falls beim Beenden ein verwaister Sidecar zurückbleibt, muss ein
  `applicationWillTerminate` her, das `stop()` synchron abwartet. In Schritt 4 der Handprobe
  ausdrücklich prüfen.
- **`uv`-Pfad:** Eine `.app` erbt nicht den `PATH` der Shell. Deshalb der absolute Pfad aus dem
  `SettingsStore` (Default `~/.local/bin/uv`). Weicht die Installation ab, meldet die App
  „uv nicht gefunden: ⟨Pfad⟩" — verständlich, aber der Nutzer braucht dann M7 (Settings-UI)
  oder ein `defaults write`.
