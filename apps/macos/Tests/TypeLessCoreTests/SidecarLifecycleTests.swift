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
