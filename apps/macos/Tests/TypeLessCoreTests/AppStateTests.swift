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

    /// Synchron aus demselben Grund wie ``StaticClient/currentState()`` — auch hier stehen
    /// `lock`/`unlock` nicht direkt im `async`-Funktionskörper von ``health()``.
    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
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

@MainActor
@Test(.timeLimit(.minutes(1)))
func doppelterStartUeberlagertKeinePollTasks() async {
    let client = GatedClient(.success(health("ready")))
    let state = makeAppState(lifecycle: FakeLifecycle(.success(.spawned)), client: client)
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

    client.release()
    await state.shutdown()
}
