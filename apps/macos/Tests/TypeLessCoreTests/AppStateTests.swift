import Foundation
import Testing
@testable import TypeLessCore

// MARK: - Test-Doubles

final class FakeLifecycle: SidecarLifecycle, @unchecked Sendable {
    private let result: Result<SidecarOwnership, LifecycleError>
    private let lock = NSLock()
    /// Protokolliert die Aufrufe in ihrer Reihenfolge — so lässt sich prüfen, dass ein
    /// Neustart wirklich erst stoppt und dann startet.
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    init(_ result: Result<SidecarOwnership, LifecycleError>) { self.result = result }

    /// Synchron, damit `lock`/`unlock` nicht direkt im `async`-Funktionskörper stehen — unter
    /// Swift 6.3 ist ``NSLock`` dort als `noasync` markiert (Deadlock-Gefahr im kooperativen
    /// Thread-Pool). Gleiche Lösung wie bei ``ScriptedClient`` in SidecarLifecycleTests.swift.
    private func record(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }

    func start() async throws -> SidecarOwnership {
        record("start")
        return try result.get()
    }

    func stop() async {
        record("stop")
    }
}

final class StaticClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var state: Result<HealthState, SidecarError>

    init(_ state: Result<HealthState, SidecarError>) { self.state = state }

    func setState(_ new: Result<HealthState, SidecarError>) {
        lock.lock(); state = new; lock.unlock()
    }

    /// Synchron aus demselben Grund wie ``FakeLifecycle/record(_:)``.
    private func currentState() -> Result<HealthState, SidecarError> {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func health() async throws -> HealthState {
        try currentState().get()
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
