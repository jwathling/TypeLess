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
    func ensureModels() async throws {}
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        fatalError("in diesen Tests nicht benutzt")
    }
}

/// Client, dessen `health()` erst zurückkehrt, wenn der Test ihn über ``release()`` gezielt
/// freigibt — gesteuert über eine Continuation statt einer festen Wartezeit.
///
/// Das ist bewusst *mehr* als ein reiner Verzögerungs-Mechanismus für Test 4 (das Race in
/// `stopPolling()`): Ein erster Anlauf, die Polling-Tests 1–3 mit einem `StaticClient`-artigen
/// Double zu schreiben, das `setState()` einfach vor einem `await` auf ein `AsyncStream`-Signal
/// setzt, erwies sich als **nicht deterministisch** — `client.health()` wird über die
/// `SidecarClient`-Protokollgrenze aufgerufen, die nicht `@MainActor`-isoliert ist. Das bedeutet
/// einen echten Executor-Hop (weg vom MainActor und zurück) bei *jedem* Aufruf, auch wenn der
/// konkrete Test-Double selbst nichts "awaited". Dadurch kann bereits ein Poll unterwegs sein,
/// bevor der Test seinen neuen Zustand gesetzt hat — das erste `AsyncStream`-Signal kann sich
/// also auf einen Aufruf beziehen, der den *alten* Zustand gelesen hat, nicht den neuen. Wenn man
/// sich (wie im ersten Anlauf) beim Debuggen isoliert nur diesen einen Test ansieht, sieht man
/// genau dieses Verhalten reproduzierbar (nicht nur gelegentlich) fehlschlagen.
///
/// ``GatedClient`` löst das robust: `setResult()` und `release()` werden im selben,
/// unterbrechungsfreien Testcode-Abschnitt aufgerufen — der freigegebene Aufruf liest den
/// Ergebniswert erst, *nachdem* `release()` seine Continuation auflöst, und `setResult()` ist zu
/// diesem Zeitpunkt garantiert schon durchgelaufen (kein `await` dazwischen). Damit lässt sich
/// zusätzlich das Race in `stopPolling()` provozieren (ein Poll ist noch "in Flug", während
/// `shutdown()` bereits läuft) und die Zahl gleichzeitig hängender Aufrufe zählen (um eine
/// Überlappung zweier Poll-Tasks nachzuweisen bzw. auszuschließen).
final class GatedClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<HealthState, SidecarError>
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var maxConcurrent = 0
    private var calls = 0

    /// Feuert, sobald ein Aufruf seine Continuation registriert hat — ab diesem Zeitpunkt ist
    /// er über ``release()`` garantiert abholbar (kein Rennen zwischen "Aufruf gestartet" und
    /// "Aufruf abholbar").
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(_ result: Result<HealthState, SidecarError>) {
        self.result = result
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    func setResult(_ new: Result<HealthState, SidecarError>) {
        lock.lock(); result = new; lock.unlock()
    }

    /// Höchste je gleichzeitig beobachtete Zahl wartender Aufrufe — bei sauberer
    /// Poll-Task-Verwaltung darf sie nie über 1 steigen.
    var maxConcurrentCalls: Int { lock.lock(); defer { lock.unlock() }; return maxConcurrent }

    /// Gesamtzahl aller je begonnenen `health()`-Aufrufe — anders als ``maxConcurrentCalls``
    /// (misst nur GLEICHZEITIGES Hängen) zählt das auch Aufrufe, die zeitlich klar
    /// nacheinander liegen. Damit lässt sich belegen, dass nach einem bestimmten Zeitpunkt
    /// KEIN weiterer Aufruf mehr eintrifft — auch nicht verspätet von einer eigentlich schon
    /// als beendet angenommenen Task (s. ``doppelterStartUeberlagertKeinePollTasks()``).
    var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }

    /// Synchron aus demselben Grund wie ``StaticClient/currentState()`` — auch hier stehen
    /// `lock`/`unlock` nicht direkt im `async`-Funktionskörper von ``health()``.
    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        calls += 1
        pending.append(continuation)
        maxConcurrent = max(maxConcurrent, pending.count)
        lock.unlock()
    }

    private func currentResult() -> Result<HealthState, SidecarError> {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Gibt genau einen wartenden Aufruf frei (FIFO — der älteste zuerst).
    func release() {
        lock.lock()
        let continuation = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        continuation?.resume()
    }

    func health() async throws -> HealthState {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            register(continuation)
            startedContinuation.yield()
        }
        return try currentResult().get()
    }

    func preload() async throws {}
    func unload() async throws {}
    func ensureModels() async throws {}
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        fatalError("in diesen Tests nicht benutzt")
    }
}

/// Simples Einmal-Signal für Tests: ``wait()`` hängt, bis ``release()`` gerufen wurde — danach
/// kehrt jeder (auch ein späterer) ``wait()``-Aufruf sofort zurück. Für Task 5 gebraucht, um
/// ``BlockingLifecycle/start()`` gezielt (ohne feste Wartezeit) offen zu halten, während der Test
/// die setup-Achse währenddessen beobachtet.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Synchron aus demselben Grund wie ``FakeLifecycle/record(_:)`` — `lock`/`unlock` dürfen
    /// unter Swift 6.3 nicht direkt im `async`-Funktionskörper stehen.
    private func registerOrResolveImmediately(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registerOrResolveImmediately(continuation)
        }
    }

    /// Nicht `async` — darf deshalb direkt lock/unlock aufrufen (s. Kommentar an
    /// ``registerOrResolveImmediately(_:)``), auch wenn der Aufrufer selbst in einem `async`-
    /// Testkörper steht (die Restriktion betrifft die *lexikalische* Umgebung des Aufrufs, nicht
    /// die Aufrufkette — genau wie bei ``GatedClient/setResult(_:)``).
    func release() {
        lock.lock()
        released = true
        let toResume = waiters
        waiters = []
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
    }
}

/// Lifecycle, dessen `start()` erst zurückkehrt, wenn der Test es über ein ``AsyncGate``
/// freigibt — simuliert `DefaultSidecarLifecycle.start()`s `waitForReady()`-Schleife, die die
/// gesamte Download-Phase blockiert. Genau diese Lücke deckte ``FakeLifecycle`` nicht ab: Dessen
/// `start()` kehrt synchron/sofort zurück, sodass ein `setup`-Poll, der erst NACH `start()`
/// beginnt, den Download-Zustand nie beobachten könnte — der eigentliche Blindspot, den die
/// bisherigen Tests verdeckt haben.
final class BlockingLifecycle: SidecarLifecycle, @unchecked Sendable {
    private let gate: AsyncGate
    private let result: Result<SidecarOwnership, LifecycleError>

    init(gate: AsyncGate, result: Result<SidecarOwnership, LifecycleError> = .success(.spawned)) {
        self.gate = gate
        self.result = result
    }

    func start() async throws -> SidecarOwnership {
        await gate.wait()
        return try result.get()
    }

    func stop() async {}
}

/// Nicht-blockierender Client, der bei **jedem** `health()`-Aufruf ein Signal feuert (wie
/// ``GatedClient/started``, aber OHNE den Aufruf zu gaten). Damit lässt sich deterministisch
/// abwarten, dass die setup-Achse einen Poll **verarbeitet** hat — ohne feste Wartezeit und ohne
/// den Aufruf zu blockieren. Bewusst kein ``GatedClient``: Ein gegateter `health()` würde die
/// setup-Achse beim `shutdown()` verklemmen (``stopSetupPolling()`` wartet auf `value`), und die
/// setup-Achse dieses Tests soll ja gerade FREI durchlaufen, während allein `lifecycle.start()`
/// blockiert.
final class SignalingHealthClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<HealthState, SidecarError>
    let pinged: AsyncStream<Void>
    private let pingedContinuation: AsyncStream<Void>.Continuation

    init(_ result: Result<HealthState, SidecarError>) {
        self.result = result
        (pinged, pingedContinuation) = AsyncStream<Void>.makeStream()
    }

    func setResult(_ new: Result<HealthState, SidecarError>) {
        lock.lock(); result = new; lock.unlock()
    }

    /// Synchron aus demselben Grund wie ``StaticClient/currentState()``.
    private func currentResult() -> Result<HealthState, SidecarError> {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func health() async throws -> HealthState {
        pingedContinuation.yield()   // feuert am EINTRITT — vor der Rückgabe
        return try currentResult().get()
    }

    func preload() async throws {}
    func unload() async throws {}
    func ensureModels() async throws {}
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
    @discardableResult func requestInputMonitoring() -> Bool { granted }
    @discardableResult func requestAccessibility() -> Bool { granted }
}

/// Zählt mit, ob die Eingabeüberwachung wirklich ANGEFORDERT wurde — und beginnt so, wie es beim
/// Anwender in der Handprobe zu M4 war: Recht fehlt. Erst die Anfrage erteilt es (so, als hätte
/// der Anwender im Systemdialog auf „Erlauben" geklickt).
final class ZaehlendePermissions: PermissionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var erteilt = false
    private(set) var anfragen = 0
    private(set) var axAnfragen = 0

    func status() -> PermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return PermissionStatus(microphone: erteilt, accessibility: erteilt,
                                inputMonitoring: erteilt)
    }

    func openSettings(for permission: Permission) {}

    @discardableResult
    func requestInputMonitoring() -> Bool {
        lock.lock(); defer { lock.unlock() }
        anfragen += 1
        erteilt = true
        return true
    }

    @discardableResult
    func requestAccessibility() -> Bool {
        lock.lock(); defer { lock.unlock() }
        axAnfragen += 1
        erteilt = true
        return true
    }
}

/// Für Finding I1 (Review): anders als ``FakePermissions`` kann sich der Zustand während einer
/// laufenden Sitzung ändern — genau wie beim echten ``SystemPermissionsService``, wenn der
/// Nutzer ein Recht in den Systemeinstellungen erteilt, während TypeLess bereits läuft.
final class MutablePermissions: PermissionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool

    init(granted: Bool) { self.granted = granted }

    func setGranted(_ value: Bool) { lock.lock(); granted = value; lock.unlock() }

    func status() -> PermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return PermissionStatus(microphone: granted, accessibility: granted, inputMonitoring: granted)
    }

    func openSettings(for permission: Permission) {}
    @discardableResult func requestInputMonitoring() -> Bool { status().inputMonitoring }
    @discardableResult func requestAccessibility() -> Bool { status().accessibility }
}

@MainActor
func makeAppState(lifecycle: SidecarLifecycle, client: SidecarClient) -> AppState {
    // `setupInterval` bewusst RIESIG: Die setup-Achse (Task 5) pollt `client.health()` — dieselbe
    // Methode, die der `GatedClient` in mehreren Tests hier absichtlich blockiert, um den
    // Engine-Poll allein zu steuern. Da die Achse „erst schlafen, dann fragen" arbeitet
    // (s. `AppState.startSetupPolling()`), schläft sie mit diesem Intervall über die gesamte
    // (Millisekunden-)Laufzeit dieser Tests und ruft `health()` NIE — der `shutdown()`-`cancel()`
    // beendet sie mitten im Schlaf, bevor sie den geteilten Gate-Client anfassen kann. So bleibt
    // die sorgfältige Aufruf-Buchführung dieser Tests (`totalCalls`, `maxConcurrentCalls`, die
    // FIFO-`release()`-Reihenfolge) von der zweiten Achse unberührt. Tests, die die setup-Achse
    // selbst prüfen, bauen `AppState` direkt mit einem kleinen `setupInterval`.
    AppState(lifecycle: lifecycle, client: client, permissions: FakePermissions(granted: true),
             pollIntervalStarting: .milliseconds(10), pollIntervalReady: .milliseconds(10),
             setupInterval: .seconds(3600))
}

/// Wie ``health(_:error:)`` aus SidecarLifecycleTests.swift, aber mit einem frei wählbaren
/// ``ModelsStatus`` — für die Tests des Einrichtungs-Fensters (M8-Verteilung Teil 2b).
func healthMitModels(state: String, downloaded: Int = 0, total: Int = 0,
                     error: String? = nil) -> HealthState {
    HealthState(status: "ready", sttLoaded: true, llmLoaded: false, busy: false,
               sttModel: "whisper", llmModel: "qwen", error: nil,
               models: ModelsStatus(state: state, downloadedBytes: downloaded, totalBytes: total,
                                    error: error))
}

/// Zählt die Aufrufe von ``ensureModels()`` — für den Beleg, dass „Erneut versuchen" den
/// Modell-Bootstrap tatsächlich anstößt.
final class CountingFakeSidecarClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _ensureModelsCalls = 0
    var ensureModelsCalls: Int { lock.lock(); defer { lock.unlock() }; return _ensureModelsCalls }

    /// Synchron aus demselben Grund wie ``FakeLifecycle/record(_:)`` — `lock`/`unlock` dürfen
    /// unter Swift 6.3 nicht direkt im `async`-Funktionskörper stehen.
    private func recordEnsureModelsCall() {
        lock.lock(); _ensureModelsCalls += 1; lock.unlock()
    }

    func health() async throws -> HealthState { TypeLessCoreTests.health("ready") }
    func preload() async throws {}
    func unload() async throws {}
    func ensureModels() async throws {
        recordEnsureModelsCall()
    }
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        fatalError("in diesen Tests nicht benutzt")
    }
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

// MARK: - Polling (bislang ungetestet, s. Review zu Task 6)

@MainActor
@Test(.timeLimit(.minutes(1)))
func timeoutBeimPollingKipptZustandNicht() async {
    // Ein Timeout beim Polling heißt "Verbindung stand, Sidecar gerade beschäftigt" — nicht
    // "Verbindung verloren". `engine` muss `.ready` bleiben.
    let client = GatedClient(.success(health("ready")))
    let state = makeAppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client)
    await state.start()
    #expect(state.engine == .ready)

    var iterator = client.started.makeAsyncIterator()
    _ = await iterator.next()               // laufende Sitzung: erster Poll ist in Flug
    client.setResult(.failure(.timedOut))
    client.release()                        // löst ihn mit dem Timeout-Ergebnis auf

    // Der nächste Poll ist erst in Flug, wenn der vorige vollständig verarbeitet (inklusive
    // seines `engine`-Schreibzugriffs) wurde — die Schleife in `startPolling()` ist streng
    // sequenziell. Zu diesem Zeitpunkt zu prüfen ist also deterministisch, keine feste
    // Wartezeit nötig.
    _ = await iterator.next()
    #expect(state.engine == .ready, "ein Timeout beim Polling darf den Zustand nicht kippen")

    // Und ein zweiter Durchlauf mit Timeout zeigt: Der Zustand bleibt dauerhaft stabil, kippt
    // nicht erst verzögert.
    client.release()
    _ = await iterator.next()
    #expect(state.engine == .ready)

    // Der dritte Poll hängt jetzt noch (ungated) — freigeben, sonst blockiert shutdown()
    // ewig in stopPolling(), das auf das Ende der Poll-Task wartet.
    client.release()
    await state.shutdown()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func sidecarStirbtWaehrendPollingWirdZuFailed() async {
    // Gegentest zu timeoutBeimPollingKipptZustandNicht(): `unreachable` muss den Zustand sehr
    // wohl kippen — sonst wäre jener Test nur grün, weil das Polling faktisch wirkungslos ist.
    let client = GatedClient(.success(health("ready")))
    let state = makeAppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client)
    await state.start()
    #expect(state.engine == .ready)

    var iterator = client.started.makeAsyncIterator()
    _ = await iterator.next()
    client.setResult(.failure(.unreachable))
    client.release()

    _ = await iterator.next()               // vorheriger Poll ist fertig verarbeitet
    #expect(state.engine == .failed("Verbindung zur Engine verloren"))

    client.release()
    await state.shutdown()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func engineMeldetFailedStatusWirdMitKlartextUebernommen() async {
    // `HealthState.status == "failed"` muss mit dem Klartext-Grund AUS DER ENGINE kippen —
    // nicht mit einem generischen Text.
    let client = GatedClient(.success(health("ready")))
    let state = makeAppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client)
    await state.start()
    #expect(state.engine == .ready)

    var iterator = client.started.makeAsyncIterator()
    _ = await iterator.next()
    client.setResult(.success(health("failed", error: "STT-Warm-up fehlgeschlagen: 401")))
    client.release()

    _ = await iterator.next()
    #expect(state.engine == .failed("STT-Warm-up fehlgeschlagen: 401"),
            "der Klartext-Grund aus der Engine, kein generischer Text")

    client.release()
    await state.shutdown()
}

// Task 5 (Fix für den Handprobe-Befund zu M8-Verteilung Teil 2b): `setup` kommt seit diesem Task
// NICHT mehr aus dem Engine-Poll (der lief nur nach einem ERFOLGREICHEN `lifecycle.start()` —
// genau die Zeitspanne, die den Download blockierend verdeckt), sondern aus einer eigenen,
// unabhängigen setup-Achse (`startSetupPolling()`). Diese Mutationsprobe ist der eigentliche
// Beweis: `setup` muss `.downloading` werden, WÄHREND `lifecycle.start()` noch läuft — mit der
// alten Struktur (setup nur in `pollOnce()`, das erst nach `lifecycle.start()` startet) kann das
// strukturell nie passieren, ganz gleich wie das Timing ausfällt. `BlockingLifecycle` macht genau
// dieses Fenster beobachtbar, das `FakeLifecycle` (kehrt sofort zurück) bisher verdeckt hat.
//
// Deterministisch OHNE feste Wartezeit — nach dem Vorbild der `GatedClient`-Tests, nur mit dem
// nicht-blockierenden `SignalingHealthClient`: Die setup-Achse ist streng sequenziell
// (`sleep` → `health()` → `setup = …`), also belegt das Eintreffen des ZWEITEN `health()`-Pings,
// dass der erste Poll bereits vollständig in `setup` verarbeitet wurde. `lifecycle.start()` bleibt
// bis `gate.release()` blockiert, daher stammen beide Pings zwangsläufig aus der setup-Achse
// (der Engine-Poll startet erst NACH `lifecycle.start()`).
//
// Vor dem Fix (setup-Achse existiert noch nicht): ROT — es fällt nie ein `health()`-Ping (nur der
// Engine-Poll fragt, und der startet nie, weil `lifecycle.start()` blockiert), `pinged.next()`
// liefert nichts, der Test läuft in sein `.timeLimit`. Nach dem Fix: GRÜN in Millisekunden.
@MainActor
@Test(.timeLimit(.minutes(1)))
func setupWirdWaehrendBlockierendemStartSichtbar() async {
    let gate = AsyncGate()
    let lifecycle = BlockingLifecycle(gate: gate)
    let client = SignalingHealthClient(.success(healthMitModels(state: "downloading",
                                                                downloaded: 1500, total: 3900)))
    let state = AppState(lifecycle: lifecycle, client: client, permissions: FakePermissions(granted: true),
                         pollIntervalStarting: .milliseconds(10), pollIntervalReady: .milliseconds(10),
                         permissionsInterval: .milliseconds(10), setupInterval: .milliseconds(1))

    let startTask = Task { await state.start() }   // start() blockiert in lifecycle.start()

    var pinged = client.pinged.makeAsyncIterator()
    _ = await pinged.next()   // erster setup-health()-Poll hat begonnen
    _ = await pinged.next()   // zweiter Poll => der erste wurde bereits in `setup` verarbeitet

    #expect(state.setup == .downloading(fraction: 1500.0 / 3900.0, downloadedBytes: 1500, totalBytes: 3900),
            "die setup-Achse muss den Download-Fortschritt zeigen, WÄHREND lifecycle.start() noch läuft")
    #expect(state.setup != .hidden, "Fenster wäre jetzt offen — WÄHREND start() noch läuft")
    #expect(state.engine == .starting, "lifecycle.start() ist noch nicht zurück")

    gate.release()                               // Download „fertig" → lifecycle.start() kehrt zurück
    await startTask.value

    await state.shutdown()
}

// Ersetzt den früheren `pollSetztSetupAusModelsBlock()`-Test (Task 3): Der prüfte, dass
// `pollOnce()` `setup` setzt — das tut `pollOnce()` seit Task 5 nicht mehr (ein Schreiber, s.
// `pollOnce()`-Kommentar). Diese Fassung prüft dieselbe fachliche Aussage — „setup spiegelt den
// models-Block" — samt dem `.hidden`→`.downloading`-Übergang, aber gegen die tatsächlich
// zuständige, unabhängige setup-Achse. Bewusst mit `StaticClient` (nicht-blockierend) +
// `warteBisMitEchterZeit`, exakt wie die beiden Rechte-Achsen-Tests oben: ein gemeinsames Gate
// würde die Achsen künstlich koppeln, was der Fix gerade entkoppelt hat. `warteBisMitEchterZeit`
// kehrt zurück, sobald die Bedingung gilt (im GRÜN-Fall Millisekunden) — keine feste Wartezeit.
// `FakeLifecycle` kehrt sofort zurück, also läuft hier auch der Engine-Poll — der `setup` seit dem
// Fix nicht mehr anfasst; dieser Test ist zugleich die Wache dafür.
@MainActor
@Test(.timeLimit(.minutes(1)))
func setupAchseSpiegeltDenModelsBlock() async {
    let client = StaticClient(.success(health("ready")))
    let state = AppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client,
                         permissions: FakePermissions(granted: true),
                         pollIntervalStarting: .milliseconds(10), pollIntervalReady: .milliseconds(10),
                         permissionsInterval: .milliseconds(10), setupInterval: .milliseconds(1))
    await state.start()
    #expect(state.engine == .ready)
    #expect(state.setup == .hidden, "vor jedem Modell-Poll bleibt das Einrichtungs-Fenster versteckt")

    client.setState(.success(healthMitModels(state: "downloading", downloaded: 1950, total: 3900)))

    await warteBisMitEchterZeit(obergrenze: .seconds(2)) {
        state.setup == .downloading(fraction: 0.5, downloadedBytes: 1950, totalBytes: 3900)
    }
    #expect(state.setup == .downloading(fraction: 0.5, downloadedBytes: 1950, totalBytes: 3900),
            "die setup-Achse übernimmt den models-Block unabhängig vom Engine-Poll")

    await state.shutdown()
}

@MainActor
@Test func retryRuftEnsureModels() async {
    let client = CountingFakeSidecarClient()
    let state = makeAppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client)

    await state.retryModelDownload()

    #expect(client.ensureModelsCalls == 1)
}

// Finding I1 (Review M3): `refreshPermissions()` wurde außerhalb der Tests nie aufgerufen —
// `permissions` blieb für die gesamte Laufzeit der App auf dem Stand aus `init`. Erteilt der
// Nutzer ein fehlendes Recht in den Systemeinstellungen, während TypeLess bereits läuft, blieb
// das Menü trotzdem dauerhaft bei ⚠ stehen. Dieser Test belegt, dass eine Änderung des
// Berechtigungsstatus während einer laufenden Sitzung tatsächlich in `AppState.permissions`
// ankommt — ohne dass irgendjemand `refreshPermissions()` von außen aufruft.
//
// M2 (Abschluss-Review M5): Die Auffrischung hing bis M5 am Engine-Poll und war damit an dessen
// Gating messbar; seit sie auf einer eigenen Task läuft (s. `startPermissionsPolling()`), wird
// hier auf ihren eigenen Takt gewartet — mit ECHTER Zeit, aber gedeckelt: Läuft die Obergrenze
// ab, wird der Test sichtbar ROT, er hängt nicht.
@MainActor
@Test(.timeLimit(.minutes(1)))
func berechtigungsAenderungWaehrendDerSitzungKommtInAppStateAn() async {
    let permissions = MutablePermissions(granted: false)
    let state = AppState(lifecycle: FakeLifecycle(.success(.spawned)),
                         client: StaticClient(.success(health("ready"))),
                         permissions: permissions,
                         pollIntervalStarting: .milliseconds(10), pollIntervalReady: .milliseconds(10),
                         permissionsInterval: .milliseconds(5))
    await state.start()
    #expect(state.permissions.microphone == false)

    // Der Nutzer erteilt das Recht jetzt, während die Sitzung bereits läuft — niemand ruft
    // refreshPermissions() explizit auf.
    permissions.setGranted(true)

    await warteBisMitEchterZeit { state.permissions.microphone }

    #expect(state.permissions.microphone == true,
            "eine während der Sitzung erteilte Berechtigung muss von selbst in AppState ankommen")
    #expect(state.permissions.accessibility == true)
    #expect(state.permissions.inputMonitoring == true)

    await state.shutdown()
}

// M2 (Abschluss-Review M5): Die Rechte-Anzeige fror ein, wenn die Engine NICHT startete.
// `startPolling()` — und damit bis M5 die einzige Stelle, die im laufenden Betrieb
// `refreshPermissions()` rief — läuft nur nach einem ERFOLGREICHEN `lifecycle.start()`. Kam die
// Engine nicht hoch (fehlendes Engine-Verzeichnis: ein real getesteter Fall), wurde `permissions`
// nie wieder gelesen. Erteilte der Anwender jetzt die Bedienungshilfen, blieb die Warnung „Text
// landet in der Zwischenablage" DAUERHAFT stehen, obwohl das Recht längst da war — dieselbe
// Fehlerklasse wie Finding I1 aus Review M3, nur an einer neuen Anzeige.
@MainActor
@Test(.timeLimit(.minutes(1)))
func rechteWerdenAuchDannAufgefrischtWennDieEngineGarNichtStartet() async {
    let permissions = MutablePermissions(granted: false)
    let state = AppState(lifecycle: FakeLifecycle(.failure(.engineDirectoryMissing("/gibt/es/nicht"))),
                         client: StaticClient(.failure(.unreachable)),
                         permissions: permissions,
                         pollIntervalStarting: .milliseconds(10), pollIntervalReady: .milliseconds(10),
                         permissionsInterval: .milliseconds(5))

    await state.start()

    #expect(state.engine == .failed("Engine nicht gefunden: /gibt/es/nicht"),
            "Vorbedingung: die Engine steht NICHT — also läuft kein Engine-Poll")
    #expect(state.einfuegenBrauchtBedienungshilfen)

    // Der Anwender legt jetzt den Schalter in den Systemeinstellungen um.
    permissions.setGranted(true)

    await warteBisMitEchterZeit { !state.einfuegenBrauchtBedienungshilfen }

    #expect(!state.einfuegenBrauchtBedienungshilfen,
            """
            auch ohne laufende Engine muss eine erteilte Berechtigung ankommen — sonst behauptet \
            das Menü für immer „Bedienungshilfen fehlen", obwohl sie da sind
            """)
    #expect(!state.hotkeyBrauchtEingabeueberwachung)

    // Und die Rechte-Achse darf den Engine-Zustand nicht anfassen: Der Klartext-Grund des
    // Startfehlers muss unverändert stehen bleiben.
    #expect(state.engine == .failed("Engine nicht gefunden: /gibt/es/nicht"),
            "die Rechte-Auffrischung darf den Engine-Zustand nicht überschreiben")

    await state.shutdown()
}

// Empirischer Beleg für den in Task 6 behobenen Race: `stopPolling()` muss auf das
// tatsächliche Ende der laufenden Poll-Task warten (`await pollTask?.value`), sonst kann
// `shutdown()` mit `lifecycle.stop()` fortfahren, während der letzte Poll noch unterwegs ist —
// und dessen verspätet eintreffender `engine`-Schreibzugriff den von `shutdown()` frisch
// gesetzten Zustand wieder überschreiben. Dieser Test öffnet das Zeitfenster gezielt über einen
// `GatedClient` — ohne ihn bleibt es (wie der Reviewer empirisch belegt hat) unerreichbar, weil
// `StaticClient` synchron und instantan antwortet.
//
// Eine erste Fassung dieses Tests prüfte nur den *Endzustand* (`engine == .stopped`) nach einem
// racenden `shutdown()`. Das erwies sich als selbst flaky (siehe Report): `lifecycle.stop()`
// läuft über eine nicht-`@MainActor`-isolierte Protokollgrenze und hopt damit zwangsläufig vom
// MainActor herunter und zurück — dadurch bekommt der freigegebene Poll manchmal doch noch eine
// Chance, VOR dem `engine = .stopped` von `shutdown()` zu schreiben, auch im fehlerhaften Fall
// (Mutationsprobe traf nur 8/10). Robuster ist die Prüfung der eigentlichen Struktur-Invariante:
// **`lifecycle.stop()` darf niemals erreicht werden, solange der Poll noch nicht freigegeben
// ist.** Das lässt sich ohne feste Wartezeit und ohne Race prüfen — mit korrektem Code ist
// `lifecycle.stop()` an dieser Stelle *strukturell unerreichbar* (er wartet ja auf
// `pollTask?.value`), ganz gleich wie viele Gelegenheiten (`Task.yield()`) man ihm gibt. Mehr
// Yields können also nie einen falschen Alarm auslösen, sondern höchstens einen echten Bug
// später statt früher fangen.
@MainActor
@Test(.timeLimit(.minutes(1)))
func stopPollingWartetAufLaufendenPollBevorZustandGesetztWird() async {
    let client = GatedClient(.success(health("ready")))
    let lifecycle = FakeLifecycle(.success(.spawned))
    let state = makeAppState(lifecycle: lifecycle, client: client)
    await state.start()
    #expect(state.engine == .ready)

    // Ohne feste Wartezeit sicherstellen, dass der von startPolling() ausgelöste erste Poll
    // tatsächlich in Flug ist, bevor shutdown() dazwischenfunkt.
    var iterator = client.started.makeAsyncIterator()
    _ = await iterator.next()

    // shutdown() ruft stopPolling() auf, die (mit dem Race-Fix) auf das Ende des hängenden
    // Polls wartet — deshalb als eigene Task, damit wir daneben freigeben können.
    let shutdownTask = Task { await state.shutdown() }

    // Kooperative Yields statt fester Wartezeit: Sie geben shutdown() jede realistische Chance,
    // (fehlerhaft) bis zu `lifecycle.stop()` durchzulaufen, BEVOR wir den Poll freigeben. Bei
    // korrektem Code kann das nicht passieren, egal wie oft wir yielden — der Test kann also
    // durch mehr Yields nie fälschlich rot werden, nur zuverlässiger einen echten Bug fangen.
    for _ in 0 ..< 200 { await Task.yield() }
    let lifecycleStopVorZeitigErreicht = lifecycle.calls.contains("stop")

    // Erst jetzt den hängenden Poll freigeben — er liefert (ggf. verspätet) "ready".
    client.release()
    await shutdownTask.value

    #expect(!lifecycleStopVorZeitigErreicht,
            "stopPolling() darf lifecycle.stop() erst NACH dem Ende der Poll-Task erreichen")
    #expect(state.engine == .stopped,
            "ein verspätet eintreffender Poll darf den Endzustand von shutdown() nicht überschreiben")
}

// `maxConcurrentCalls` allein reicht nicht aus, um zu belegen, dass ein zweiter start() die
// ALTE Poll-Task wirklich beendet: Es misst nur, ob je zwei Aufrufe GLEICHZEITIG hingen — das
// Messfenster schließt sich, sobald sich der neue Poll mit seinem ersten Aufruf meldet. Eine
// alte, im Fehlerfall weiterlaufende Task steckt zu diesem Zeitpunkt aber typischerweise noch
// im `Task.sleep` nach ihrem freigegebenen Aufruf und hat ihren nächsten `health()`-Aufruf noch
// gar nicht registriert — die Überlappung existiert real, liegt aber außerhalb des
// Messfensters, und der Test bliebe grün, selbst wenn `startPolling()` den alten Poll nie
// abbräche (empirisch belegt, s. Report zu Task 6).
//
// Deshalb zusätzlich: Nach dem zweiten start() wird bewusst NICHTS mehr freigegeben — weder der
// neue Poll (der käme sonst selbst zu einem weiteren Aufruf) noch sonst irgendwer. Jeder
// `health()`-Aufruf, der über die zwei unvermeidlichen (den ursprünglichen ersten Poll und den
// ersten Aufruf des neuen Polls) hinausgeht, kann also nur von einer eigentlich schon beendet
// geglaubten ALTEN Task stammen. Geprüft wird das über `client.totalCalls` — bewusst NICHT als
// Vorher/Nachher-Differenz um eine einzelne `iterator.next()`-Messung herum (ein früher Anlauf
// tat das und war dadurch selbst flaky: Wessen Aufruf `iterator.next()` als "der neue Poll"
// auffasst, hängt vom Scheduling ab — bei knappem Timing kann der verräterische dritte Aufruf
// der alten Task schon VOR dieser Messung passiert und damit fälschlich im "Vorher"-Wert
// mitgezählt sein, was den Fehler verdeckt hätte). Robuster: Erst 500 `Task.yield()`s geben
// jeder anstehenden (auch fehlerhaften) Aktivität reichlich Gelegenheit, sich zu zeigen — ganz
// gleich, in welcher Reihenfolge sie eintrifft —, DANACH wird gegen die einzig korrekte Zahl
// geprüft: genau 2. Bei korrektem Code ist die alte Task durch `stopPolling()` längst beendet
// und kann strukturell keinen weiteren Aufruf mehr absetzen — beliebig viele Yields können also
// nie einen Fehlalarm auslösen. Bei fehlerhaftem Code (fehlendes `stopPolling()` in
// `startPolling()`) setzt sie zuverlässig einen dritten Aufruf ab, der (da wir nichts mehr
// freigeben) dort hängen bleibt und die Zahl auf 3 hebt.
//
// Damit dieser dritte Aufruf ohne feste Wartezeit im Test sichtbar wird, laufen die
// Poll-Intervalle in diesem Test (anders als über `makeAppState()`) nahe Null: Die
// `Task.sleep(for:)`-Pause zwischen zwei Polls wird dadurch zu einem reinen Scheduler-Hop, den
// die `Task.yield()`-Schleife zuverlässig überbrücken kann, statt auf echte Zeit angewiesen zu
// sein.
@MainActor
@Test(.timeLimit(.minutes(1)))
func doppelterStartUeberlagertKeinePollTasks() async {
    let client = GatedClient(.success(health("ready")))
    let state = AppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client,
                          permissions: FakePermissions(granted: true),
                          pollIntervalStarting: .zero, pollIntervalReady: .zero,
                          // setup-Achse stummschalten — s. Begründung in `makeAppState`. Ohne das
                          // fiele ihr `health()` in die Aufruf-Buchführung (`totalCalls == 2`) ein.
                          setupInterval: .seconds(3600))
    await state.start()

    var iterator = client.started.makeAsyncIterator()
    _ = await iterator.next()   // der erste Poll ist in Flug

    // Ein zweiter start()-Aufruf (z. B. doppelter Hotkey-Druck), während der erste Poll noch
    // hängt: startPolling() muss den alten Poll erst sauber beenden, bevor ein neuer beginnt.
    let secondStart = Task { await state.start() }

    // Gibt den alten (inzwischen abgebrochenen) Poll frei, damit seine Task auslaufen kann —
    // ohne das würde der zweite start() für immer in stopPolling() hängen.
    client.release()
    await secondStart.value

    _ = await iterator.next()   // der neue Poll-Task meldet sich mit seinem ersten Aufruf

    #expect(client.maxConcurrentCalls == 1,
            "zwei start()-Aufrufe dürfen nie zwei Polls gleichzeitig laufen lassen")

    // Ab hier bewusst KEIN weiterer client.release() mehr, bevor die Schleife unten fertig ist —
    // s. Kommentar oben, warum erst NACH den Yields gemessen wird, nicht davor/danach verglichen.
    for _ in 0 ..< 500 { await Task.yield() }

    #expect(client.totalCalls == 2,
            """
            nach dem zweiten start() dürfen insgesamt nur zwei health()-Aufrufe je stattgefunden \
            haben (der ursprüngliche erste Poll und der erste Aufruf des neuen Polls) — ein \
            dritter kann nur von einer eigentlich schon beendet geglaubten ALTEN Poll-Task \
            stammen
            """)

    client.release()
    await state.shutdown()
}

// MARK: - Eingabeüberwachung (Handprobe M4)

@MainActor
@Test(.timeLimit(.minutes(1)))
func eingabeueberwachungWirdAktivAngefordertUndNichtNurGeprueft() async throws {
    // Das Fehlerbild, das das gekostet hat: Ein `CGEventTap` lässt sich auch OHNE
    // Eingabeüberwachung anlegen — `tapCreate` liefert klaglos einen Tap, es gibt keinen Fehler.
    // Der Tap sieht im Hintergrund nur nie ein Ereignis. Ist TypeLess dagegen die AKTIVE App
    // (offenes Menü!), sieht er die Tastendrücke sehr wohl. Ergebnis beim Anwender: „Diktieren
    // geht nur, solange ich das Menü offen habe."
    //
    // TypeLess PRÜFTE das Recht bloß und forderte es nie an — also fragte macOS auch nie und
    // trug TypeLess unter Umständen nicht einmal in die Liste ein, in der man den Schalter
    // umlegen könnte. Dieser Test ist die Wache davor, dass die Anfrage je wieder verschwindet.
    let permissions = ZaehlendePermissions()
    let state = AppState(lifecycle: FakeLifecycle(.success(.adopted)),
                         client: StaticClient(.success(health("ready"))),
                         permissions: permissions,
                         pollIntervalStarting: .milliseconds(10),
                         pollIntervalReady: .milliseconds(10))

    #expect(state.hotkeyBrauchtEingabeueberwachung,
            "vor der Anfrage fehlt das Recht — das Menü darf dann nicht „Bereit“ behaupten")

    state.requestInputMonitoring()

    #expect(permissions.anfragen == 1, "das Recht muss ANGEFORDERT werden, nicht nur geprüft")
    #expect(!state.hotkeyBrauchtEingabeueberwachung,
            "nach erteiltem Recht muss die Anzeige das sofort widerspiegeln")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func bedienungshilfenWerdenAktivAngefordertUndNichtNurGeprueft() async throws {
    // Dieselbe Falle wie bei der Eingabeüberwachung in M4: `CGEvent.post` braucht das Recht
    // "Bedienungshilfen". Fehlt es, passiert beim Einfügen schlicht NICHTS — kein Fehler, kein
    // Hinweis. Wird das Recht nur GEPRÜFT und nie ANGEFORDERT, fragt macOS den Anwender nie.
    let permissions = ZaehlendePermissions()
    let state = AppState(lifecycle: FakeLifecycle(.success(.adopted)),
                         client: StaticClient(.success(health("ready"))),
                         permissions: permissions,
                         pollIntervalStarting: .milliseconds(10),
                         pollIntervalReady: .milliseconds(10))

    #expect(state.einfuegenBrauchtBedienungshilfen,
            "vor der Anfrage fehlt das Recht — das Menü muss das sagen können")

    state.requestAccessibility()

    #expect(permissions.axAnfragen == 1, "das Recht muss ANGEFORDERT werden, nicht nur geprüft")
    #expect(!state.einfuegenBrauchtBedienungshilfen,
            "nach erteiltem Recht muss die Anzeige das sofort widerspiegeln")
}
