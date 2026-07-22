import Foundation
import Testing
@testable import TypeLessCore

// MARK: - Test-Doubles

final class SpyProcessHandle: ProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var terminateCount = 0
    var forceTerminateCount = 0

    /// Ob `terminate()` den Prozess sofort beendet (Default — reicht für alle Tests, denen es
    /// nur um *ob* und *wie oft* terminiert wurde, geht) oder ob der Test selbst über
    /// ``simulateExit()`` steuert, wann er wirklich stirbt.
    ///
    /// Für C1 (Review) ist genau das der Punkt: In Wirklichkeit beendet SIGTERM einen Prozess
    /// nicht synchron — der Reviewer hat gemessen, dass `/health` 0,05 s nach dem Signal noch
    /// "ready" meldet. Mit `instantExit == true` (dem alten, unveränderten Verhalten dieses
    /// Doubles) wäre dieses Zeitfenster im Test unsichtbar, weil der Prozess sofort tot ist —
    /// genau das hat die C1-Lücke bislang vor jedem Test verborgen.
    private let instantExit: Bool

    /// Feuert, sobald `terminate()` aufgerufen wurde — für Tests, die ohne feste Wartezeit
    /// beobachten wollen, dass SIGTERM bereits verschickt wurde.
    let terminateCalled: AsyncStream<Void>
    private let terminateCalledContinuation: AsyncStream<Void>.Continuation

    init(instantExit: Bool = true) {
        self.instantExit = instantExit
        (terminateCalled, terminateCalledContinuation) = AsyncStream<Void>.makeStream()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func terminate() {
        lock.lock()
        terminateCount += 1
        if instantExit { running = false }
        lock.unlock()
        terminateCalledContinuation.yield()
    }

    func forceTerminate() {
        lock.lock(); forceTerminateCount += 1; running = false; lock.unlock()
    }

    /// Simuliert das tatsächliche Prozessende — vom Test gezielt ausgelöst, wenn `instantExit`
    /// `false` ist.
    func simulateExit() {
        lock.lock(); running = false; lock.unlock()
    }
}

final class SpyProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startedCommands: [[String]] = []
    private(set) var startedEnvironments: [[String: String]] = []
    private(set) var startedWorkingDirectories: [String] = []
    let handle: SpyProcessHandle

    /// Feuert, sobald ``run(executable:arguments:workingDirectory:environment:)`` aufgerufen
    /// wurde — für Tests, die ohne feste Wartezeit sicherstellen müssen, dass der Prozess
    /// tatsächlich gestartet wurde, bevor sie z. B. die aufrufende Task abbrechen.
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(instantExit: Bool = true) {
        handle = SpyProcessHandle(instantExit: instantExit)
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    func run(executable: String, arguments: [String], workingDirectory: String,
             environment: [String: String]) throws -> ProcessHandle {
        lock.lock()
        startedCommands.append([executable] + arguments)
        startedEnvironments.append(environment)
        startedWorkingDirectories.append(workingDirectory)
        lock.unlock()
        startedContinuation.yield()
        return handle
    }
}

/// Client, dessen Antworten der Test Schritt für Schritt vorgibt.
final class ScriptedClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<HealthState, SidecarError>]
    private var healthCallCount = 0

    init(_ script: [Result<HealthState, SidecarError>]) { self.script = script }

    var healthCalls: Int { lock.lock(); defer { lock.unlock() }; return healthCallCount }

    /// Synchron, damit ``lock``/``unlock`` nicht direkt im `async`-Funktionskörper stehen —
    /// unter Swift 6.3 ist ``NSLock`` dort als `noasync` markiert (Deadlock-Gefahr im
    /// kooperativen Thread-Pool). Die eigentliche Kritische Sektion bleibt synchron und kurz.
    private func nextResult() -> Result<HealthState, SidecarError> {
        lock.lock()
        defer { lock.unlock() }
        healthCallCount += 1
        return script.isEmpty ? .failure(.unreachable) : script.removeFirst()
    }

    func health() async throws -> HealthState {
        try nextResult().get()
    }

    func preload() async throws {}
    func unload() async throws {}
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        fatalError("in diesen Tests nicht benutzt")
    }
}

func health(_ status: String, error: String? = nil) -> HealthState {
    HealthState(status: status, sttLoaded: status == "ready", llmLoaded: false, busy: false,
                sttModel: "whisper", llmModel: "qwen", error: error,
                models: ModelsStatus(state: "ready", downloadedBytes: 0, totalBytes: 0, error: nil))
}

/// Baut ein `EngineLaunch` mit den bisherigen Test-Default-Werten (Entwicklungs-Start:
/// `/bin/echo run python -m typeless_engine.server` im Temp-Verzeichnis) — für Tests, denen es
/// nicht auf den konkreten Startbefehl ankommt, nur auf die übrige Lifecycle-Logik.
func makeLaunch(executable: String = "/bin/echo",           // existiert garantiert
                workingDirectory: String = FileManager.default.temporaryDirectory.path,
                socketPath: String = "/tmp/typeless-test.sock") -> EngineLaunch {
    EngineLaunch(executable: executable,
                arguments: ["run", "python", "-m", "typeless_engine.server"],
                workingDirectory: workingDirectory,
                environment: ["TYPELESS_SOCKET_PATH": socketPath])
}

func makeLifecycle(client: SidecarClient, runner: ProcessRunner,
                    socketPath: String = "/tmp/typeless-test.sock") -> DefaultSidecarLifecycle {
    DefaultSidecarLifecycle(client: client, runner: runner,
                            launch: makeLaunch(socketPath: socketPath),
                            readyTimeout: .milliseconds(500),
                            pollInterval: .milliseconds(10),
                            terminateTimeout: .milliseconds(200),
                            terminatePollInterval: .milliseconds(5))
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

// `meldetFehlendesEngineVerzeichnis` (Prüfung von `engineDirectory` vor dem Spawn) entfällt hier:
// Diese Validierung wandert mit `EngineLaunch` aus `DefaultSidecarLifecycle` heraus — im
// gebündelten Fall stellt das Anlegen unter Application Support (Task 3, Composition-Root) die
// Existenz sicher, im Dev-Fall das vorhandene Repo. `LifecycleError.engineDirectoryMissing` bleibt
// als Fall bestehen (s. `AppState`-Fehlerabbildung), wird aber im Start-Zweig nicht mehr geworfen.

@Test func meldetFehlendesUv() async throws {
    let lifecycle = DefaultSidecarLifecycle(
        client: ScriptedClient([.failure(.unreachable)]),
        runner: SpyProcessRunner(),
        launch: makeLaunch(executable: "/gibt/es/nicht/uv"),
        readyTimeout: .milliseconds(500),
        pollInterval: .milliseconds(10))

    await #expect(throws: LifecycleError.uvMissing("/gibt/es/nicht/uv")) {
        _ = try await lifecycle.start()
    }
}

// Step 1 (Task 2 Brief): Belegt, dass `start()` im Spawn-Zweig ausschließlich die Werte aus
// `launch` verwendet (nicht mehr eigene `engineDirectory`/`uvPath`-Felder) — Exekutable,
// Argumente, Arbeitsverzeichnis und Umgebung wandern unverändert bis zu `runner.run()` durch.
// Abweichend vom Brief-Beispiel wird als Exekutable `/bin/echo` verwendet (real vorhanden) statt
// des dort nur illustrativen `/App/Contents/Resources/engine/uv` — `start()` prüft die
// Exekutable-Eigenschaft echt über `FileManager.isExecutableFile`, ein nicht existierender Pfad
// würde vor dem Spawn mit `uvMissing` scheitern statt den Spawn-Zweig zu erreichen.
@Test func startVerwendetEngineLaunchWerte() async throws {
    let launch = EngineLaunch(
        executable: "/bin/echo",
        arguments: ["run", "--frozen", "--project", "/App/Contents/Resources/engine",
                    "--extra", "mlx", "--extra", "server", "python", "-m", "typeless_engine.server"],
        workingDirectory: "/AS/TypeLess",
        environment: ["TYPELESS_SOCKET_PATH": "/sock/typeless.sock",
                      "UV_PROJECT_ENVIRONMENT": "/AS/TypeLess/runtime"])
    let runner = SpyProcessRunner()
    let client = ScriptedClient([.failure(.unreachable), .success(health("ready"))])
    let lifecycle = DefaultSidecarLifecycle(
        client: client, runner: runner, launch: launch,
        readyTimeout: .seconds(1), pollInterval: .milliseconds(5))

    let ownership = try await lifecycle.start()

    #expect(ownership == .spawned)
    let command = try #require(runner.startedCommands.first)
    #expect(command.first == "/bin/echo")
    #expect(Array(command.dropFirst()) == launch.arguments)
    #expect(runner.startedWorkingDirectories.first == "/AS/TypeLess")
    #expect(runner.startedEnvironments.first?["UV_PROJECT_ENVIRONMENT"] == "/AS/TypeLess/runtime")
}

// Finding 1 (Review, Task 4): Scheitert `waitForReady()` im Spawn-Zweig, blieb der selbst
// gestartete Prozess bislang als Zombie zurück — der Sidecar lädt MLX-Modelle in den Speicher,
// auf einem 16-GB-Mac kein kosmetisches Problem. `start()` muss ihn terminieren, bevor der
// Fehler weitergereicht wird.
@Test(.timeLimit(.minutes(1)))
func terminiertSelbstGestartetenProzessBeiTimeout() async throws {
    let runner = SpyProcessRunner()
    let script: [Result<HealthState, SidecarError>] =
        [.failure(.unreachable)] + Array(repeating: .success(health("starting")), count: 20)
    let lifecycle = makeLifecycle(client: ScriptedClient(script), runner: runner)

    await #expect(throws: LifecycleError.readyTimeout) {
        _ = try await lifecycle.start()
    }

    #expect(runner.handle.terminateCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func terminiertSelbstGestartetenProzessBeiFehlerzustand() async throws {
    let runner = SpyProcessRunner()
    let client = ScriptedClient([
        .failure(.unreachable),
        .success(health("failed", error: "STT-Warm-up fehlgeschlagen: 401")),
    ])
    let lifecycle = makeLifecycle(client: client, runner: runner)

    await #expect(throws: LifecycleError.failed("STT-Warm-up fehlgeschlagen: 401")) {
        _ = try await lifecycle.start()
    }

    #expect(runner.handle.terminateCount == 1)
}

// Gegenprobe zur eisernen Regel: Eine übernommene Instanz wird nie terminiert — auch dann nicht,
// wenn das Warten auf ihre Bereitschaft (Adopt-Zweig, fremde Instanz fährt gerade hoch)
// fehlschlägt. Dieser Test würde eine zu weit gefasste Behebung von Finding 1 fangen, die den
// Adopt-Zweig versehentlich mit demselben Aufräumcode umschließt.
@Test(.timeLimit(.minutes(1)))
func terminiertUebernommeneInstanzNichtBeiFehlerWaehrendDesWartens() async throws {
    let runner = SpyProcessRunner()
    let client = ScriptedClient([
        .success(health("starting")),
        .success(health("starting")),
        .success(health("failed", error: "STT-Warm-up fehlgeschlagen: 401")),
    ])
    let lifecycle = makeLifecycle(client: client, runner: runner)

    await #expect(throws: LifecycleError.failed("STT-Warm-up fehlgeschlagen: 401")) {
        _ = try await lifecycle.start()
    }

    #expect(runner.startedCommands.isEmpty, "eine fremde, hochfahrende Instanz darf nie einen eigenen Prozess starten")
    #expect(runner.handle.terminateCount == 0)
}

// Finding 2 (Review, Task 4): `waitForReady()` verschluckte jeden Fehler aus `client.health()`
// und `Task.sleep`, auch einen kooperativen Task-Abbruch — die Schleife drehte stattdessen als
// Busy-Spin bis zum vollen `readyTimeout` und meldete danach fälschlich `readyTimeout`. Ein
// Abbruch während des Spawn-Zweigs muss als `CancellationError` ankommen und den selbst
// gestarteten Prozess beenden (sonst greift Finding 1 auf diesem Weg wieder).
@Test(.timeLimit(.minutes(1)))
func abbruchWaehrendSpawnLiefertCancellationErrorUndBeendetProzess() async throws {
    let runner = SpyProcessRunner()
    // Nach dem ersten Skript-Eintrag liefert ScriptedClient per Fallback immer `.unreachable` —
    // der Sidecar bleibt also dauerhaft "nicht erreichbar", bis der Abbruch greift.
    let client = ScriptedClient([.failure(.unreachable)])
    let lifecycle = makeLifecycle(client: client, runner: runner)

    let task = Task { try await lifecycle.start() }

    // Ohne feste Wartezeit sicherstellen, dass der Prozess tatsächlich gestartet wurde, bevor
    // abgebrochen wird.
    var iterator = runner.started.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(runner.handle.terminateCount == 1)
}

// Finding I2 (Review): Der Client verbindet auf `settings.socketPath`, dem gespawnten
// Kindprozess wurde dieser Pfad aber nie mitgegeben — er las stattdessen seinen eigenen
// Default aus `engine/typeless_engine/config.py`. Weichen beide Pfade voneinander ab, startet
// die App eine kerngesunde Engine, die auf einem anderen Socket lauscht, und meldet nach dem
// vollen `readyTimeout` fälschlich "Zeitüberschreitung beim Start" — bei laufender Engine.
@Test func reichtSocketPfadAlsUmgebungsvariableAnDenGespawntenProzessDurch() async throws {
    let runner = SpyProcessRunner()
    let client = ScriptedClient([.failure(.unreachable), .success(health("ready"))])
    let lifecycle = makeLifecycle(client: client, runner: runner, socketPath: "/tmp/custom-typeless.sock")

    _ = try await lifecycle.start()

    let environment = try #require(runner.startedEnvironments.first)
    #expect(environment["TYPELESS_SOCKET_PATH"] == "/tmp/custom-typeless.sock")
}

// Finding C1 (Review): `stop()` schickte bisher nur SIGTERM und kehrte sofort zurück, ohne auf
// das tatsächliche Prozessende zu warten. In Wirklichkeit beendet SIGTERM einen Prozess nicht
// synchron — der Reviewer hat gemessen: 0,05 s danach antwortet `/health` noch mit "ready",
// erst nach ~0,22 s ist der Prozess tot. Kehrt `stop()` in diesem Fenster zurück, hält ein
// direkt anschließendes `start()` den sterbenden Prozess für gesund und adoptiert ihn, statt
// selbst einen neuen zu starten. Dieser Test bildet das Fenster nach, indem `terminate()` auf
// dem Test-Double den Prozess NICHT sofort beendet — der Test selbst löst das Ende gezielt über
// `simulateExit()` aus — und belegt strukturell, dass `stop()` nicht zurückkehrt, solange der
// Prozess laut `isRunning` noch lebt.
@Test(.timeLimit(.minutes(1)))
func stopWartetAufTatsaechlichesProzessendeBevorSieZurueckkehrt() async throws {
    let runner = SpyProcessRunner(instantExit: false)
    let client = ScriptedClient([.failure(.unreachable), .success(health("ready"))])
    let lifecycle = makeLifecycle(client: client, runner: runner)
    _ = try await lifecycle.start()

    let stopReturned = Flag()
    let stopTask = Task {
        await lifecycle.stop()
        stopReturned.set()
    }

    // Ohne feste Wartezeit sicherstellen, dass SIGTERM tatsächlich verschickt wurde, bevor wir
    // behaupten, `stop()` sei noch nicht zurück.
    var terminateIterator = runner.handle.terminateCalled.makeAsyncIterator()
    _ = await terminateIterator.next()
    #expect(runner.handle.terminateCount == 1)

    // Kooperative Yields statt fester Wartezeit: Sie geben `stop()` jede realistische Chance,
    // (fehlerhaft) vorzeitig zurückzukehren, BEVOR wir den Prozess sterben lassen. Bei
    // korrektem Code kann `stopReturned` hier nicht gesetzt sein, egal wie oft wir yielden.
    for _ in 0 ..< 200 { await Task.yield() }
    #expect(!stopReturned.isSet,
            "stop() darf nicht zurückkehren, solange der Prozess laut isRunning noch lebt")
    #expect(runner.handle.isRunning, "Testaufbau: der Prozess muss zu diesem Zeitpunkt noch laufen")

    // Erst jetzt das tatsächliche Prozessende simulieren.
    runner.handle.simulateExit()
    await stopTask.value

    #expect(stopReturned.isSet)
    #expect(runner.handle.forceTerminateCount == 0,
            "ein Prozess, der rechtzeitig auf SIGTERM reagiert, braucht kein SIGKILL")
}

/// Threadsicheres Flag für Tests, die ohne feste Wartezeit belegen wollen, dass ein bestimmtes
/// Ereignis (noch) nicht eingetreten ist.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
