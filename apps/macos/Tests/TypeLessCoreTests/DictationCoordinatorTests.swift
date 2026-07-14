import Foundation
import Testing
@testable import TypeLessCore

// MARK: - Attrappen

final class SpyPasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var texte: [String] = []

    var geschrieben: [String] {
        lock.lock(); defer { lock.unlock() }
        return texte
    }

    func write(_ text: String) {
        lock.lock(); texte.append(text); lock.unlock()
    }
}

/// Client, dessen `process`-Antwort der Test vorgibt und dessen Aufrufe er zählt.
final class DictationClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var ergebnis: Result<ProcessResult, SidecarError>
    private var preloadFehler: SidecarError?
    private(set) var preloadCount = 0
    private(set) var processCount = 0
    /// Meldet, sobald `process` aufgerufen wurde — damit Tests ohne Wartezeit synchronisieren.
    let processGestartet: AsyncStream<Void>
    private let processGestartetC: AsyncStream<Void>.Continuation

    init(ergebnis: Result<ProcessResult, SidecarError>, preloadFehler: SidecarError? = nil) {
        self.ergebnis = ergebnis
        self.preloadFehler = preloadFehler
        (processGestartet, processGestartetC) = AsyncStream<Void>.makeStream()
    }

    private func naechstes() throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        return try ergebnis.get()
    }

    func health() async throws -> HealthState {
        HealthState(status: "ready", sttLoaded: true, llmLoaded: true, busy: false,
                    sttModel: "w", llmModel: "q", error: nil)
    }

    func preload() async throws {
        // Synchron ausgelagert, damit lock()/unlock() nicht direkt im async-Funktionskörper
        // stehen — unter Swift 6.3 ist NSLock dort als `noasync` markiert (Deadlock-Gefahr im
        // kooperativen Thread-Pool). Gleiche Lösung wie bei `FakeLifecycle.record(_:)` in
        // AppStateTests.swift.
        let fehler = vermerkePreload()
        if let fehler { throw fehler }
    }

    func unload() async throws {}

    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        vermerkeProcess()
        processGestartetC.yield()
        return try naechstes()
    }

    private func vermerkePreload() -> SidecarError? {
        lock.lock(); defer { lock.unlock() }
        preloadCount += 1
        return preloadFehler
    }

    private func vermerkeProcess() {
        lock.lock(); defer { lock.unlock() }
        processCount += 1
    }
}

/// Recorder-Attrappe, deren `start()` hängt, bis der Test sie über `freigeben()` auflöst — nötig
/// für Finding 1 (Review zu Task 4, Critical): `stop()` trifft ein, während `handlePressed()`
/// noch in `recorder.start()` hängt (z. B. weil macOS gerade den Berechtigungsdialog zeigt).
/// Gleiches Muster wie `GatedPermissionCheck` in `AudioRecorderTests.swift`: eine gewöhnliche
/// Klasse mit `NSLock`, kein Actor — `freigeben()` bleibt so ein ganz normaler synchroner
/// Aufruf aus dem Test heraus, ohne Fragen zur Actor-Isolation von `let`-Eigenschaften.
/// `lock.lock()/unlock()` stehen bewusst nie direkt im Körper einer `async`-Funktion (unter
/// Swift 6.3 als `noasync` markiert) — entweder in einer synchronen Hilfsmethode oder in der
/// synchronen Closure von `withCheckedContinuation`, gleiches Muster wie bei `DictationClient`
/// oben und `GatedPermissionCheck`.
final class GatedRecorder: AudioRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var samples: [Float]
    private var zustandLaeuft = false
    private var zustandStartCount = 0
    private var zustandStopCount = 0

    var laeuft: Bool { lock.lock(); defer { lock.unlock() }; return zustandLaeuft }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return zustandStartCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return zustandStopCount }

    /// Feuert, sobald ein `start()`-Aufruf seine Continuation registriert hat — ab diesem
    /// Zeitpunkt ist er über `freigeben()` garantiert abholbar.
    let startGestartet: AsyncStream<Void>
    private let startGestartetC: AsyncStream<Void>.Continuation

    init(samples: [Float] = []) {
        self.samples = samples
        (startGestartet, startGestartetC) = AsyncStream<Void>.makeStream()
    }

    func start() async throws {
        vermerkeStart()
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock(); pending.append(k); lock.unlock()
            startGestartetC.yield()
        }
        setzeLaeuft(true)
    }

    func stop() async throws -> AudioRecording {
        guard beendeUndLiesObLaeuft() else { throw AudioRecorderError.notRecording }
        return AudioRecording(werte: samples, verloreneHaeppchen: 0)
    }

    /// Löst genau einen wartenden `start()`-Aufruf auf. Bewusst nicht `async`: Der Test ruft ihn
    /// synchron auf, ohne selbst eine Task-Grenze zu queren.
    func freigeben() {
        lock.lock()
        let k = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        k?.resume()
    }

    private func vermerkeStart() {
        lock.lock(); zustandStartCount += 1; lock.unlock()
    }

    private func setzeLaeuft(_ wert: Bool) {
        lock.lock(); zustandLaeuft = wert; lock.unlock()
    }

    private func beendeUndLiesObLaeuft() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        zustandStopCount += 1
        let war = zustandLaeuft
        zustandLaeuft = false
        return war
    }
}

/// Client, dessen `process()`-Aufrufe so lange hängen, bis der Test sie über `freigeben(mit:)`
/// gezielt (FIFO — der älteste zuerst) auflöst. Nötig für Finding 2 (Review zu Task 4: der
/// bestehende Test zu Regel 6 bewies nichts, weil `DictationClient.process()` sofort auflöste —
/// die alte Verarbeitung war schon fertig, bevor der zweite Tastendruck verarbeitet wurde) und
/// für Finding 3 (zwei echt gleichzeitig laufende Verarbeitungen, deren Reihenfolge der Test
/// gezielt steuern muss). Gleiches Muster wie `GatedClient` in `AppStateTests.swift`.
final class GatedDictationClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Result<ProcessResult, SidecarError>, Never>] = []
    private(set) var processCount = 0

    /// Feuert, sobald ein `process()`-Aufruf seine Continuation registriert hat.
    let processGestartet: AsyncStream<Void>
    private let processGestartetC: AsyncStream<Void>.Continuation

    init() {
        (processGestartet, processGestartetC) = AsyncStream<Void>.makeStream()
    }

    func health() async throws -> HealthState {
        HealthState(status: "ready", sttLoaded: true, llmLoaded: true, busy: false,
                    sttModel: "w", llmModel: "q", error: nil)
    }

    func preload() async throws {}
    func unload() async throws {}

    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        vermerkeProcess()
        let ergebnis = await withCheckedContinuation {
            (k: CheckedContinuation<Result<ProcessResult, SidecarError>, Never>) in
            lock.lock(); pending.append(k); lock.unlock()
            processGestartetC.yield()
        }
        return try ergebnis.get()
    }

    private func vermerkeProcess() {
        lock.lock(); processCount += 1; lock.unlock()
    }

    /// Löst genau einen wartenden Aufruf auf (FIFO — der älteste zuerst).
    func freigeben(mit ergebnis: Result<ProcessResult, SidecarError>) {
        lock.lock()
        let k = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        k?.resume(returning: ergebnis)
    }
}

func ergebnis(_ text: String, refined: Bool = true,
              fallbackReason: String? = nil) -> ProcessResult {
    ProcessResult(finalText: text, rawText: text, dictionaryText: text, mode: "diktat",
                  language: "de", refined: refined, fallbackReason: fallbackReason,
                  timingsMs: [:])
}

/// Sprache: 1 s bei 16 kHz, deutlich über der Stilleschwelle.
func sprache(sekunden: Double = 1.0) -> [Float] {
    let n = Int(16_000 * sekunden)
    return (0..<n).map { Float(sin(Double($0) * 0.1)) * 0.2 }
}

/// Stille: 1 s bei 16 kHz, faktisch tonlos.
func stille(sekunden: Double = 1.0) -> [Float] {
    [Float](repeating: 0.0001, count: Int(16_000 * sekunden))
}

@MainActor
func makeCoordinator(hotkey: HotkeyMonitor, recorder: AudioRecorder,
                     client: SidecarClient, pasteboard: Pasteboard) -> DictationCoordinator {
    // Auf Protokolltypen verbreitert (statt der konkreten Attrappen `FakeRecorder`/
    // `DictationClient`/`FakeHotkey`/`SpyPasteboard`): Damit lassen sich auch die torgesteuerten
    // Doubles `GatedRecorder`/`GatedDictationClient` (Findings 1–3, Review zu Task 4) hier
    // durchreichen, ohne einen zweiten, praktisch identischen Hilfsaufbau zu brauchen. Bestehende
    // Aufrufstellen sind unverändert gültig — jede konkrete Attrappe erfüllt ihr Protokoll.
    DictationCoordinator(hotkey: hotkey, recorder: recorder, client: client, pasteboard: pasteboard)
}

/// Wartet ohne feste Wartezeit, bis eine Bedingung eintritt.
@MainActor
func warteBis(_ bedingung: () -> Bool) async {
    for _ in 0..<10_000 {
        if bedingung() { return }
        await Task.yield()
    }
}

/// Wie `warteBis`, aber für Bedingungen, die auf ECHTE Zeit warten müssen (C1, Review M4: der
/// Aufnahme-Watchdog basiert auf `Task.sleep`) — reines `Task.yield()`-Pollen hat keine Garantie,
/// in endlicher WALLTIME lange genug zu warten (10 000 Yields können, je nach Systemlast, in
/// Mikrosekunden durch sein). Trotzdem keine EINZELNE feste Wartezeit: gepollt mit kurzen
/// Intervallen bis zu einer echten Obergrenze — exakt dasselbe Muster wie
/// `DictationCoordinator.warteAufVerarbeitungenMitZeitlimit` in der Produktion. Die Obergrenze
/// hier ist reine Sicherheitsbremse (weit über jeder realistischen Wartezeit) — läuft sie ab,
/// gibt die Funktion einfach auf (kein Hängenbleiben), und die nachfolgenden `#expect`s werden
/// sichtbar rot statt den Test ewig zu blockieren.
@MainActor
func warteBisMitEchterZeit(obergrenze: Duration = .seconds(5), _ bedingung: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: obergrenze)
    while !bedingung(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Tests

@MainActor
@Test(.timeLimit(.minutes(1)))
func druckStartetAufnahmeUndPreload() async throws {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis("Hallo")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }

    #expect(coordinator.session == .recording)
    #expect(await recorder.startCount == 1)
    // Der Preload läuft nebenläufig — er lädt das Sprachmodell, während der Nutzer noch spricht.
    await warteBis { client.preloadCount == 1 }
    #expect(client.preloadCount == 1)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func loslassenVerarbeitetUndSchreibtInDieZwischenablage() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let coordinator = makeCoordinator(
        hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
        client: DictationClient(ergebnis: .success(ergebnis("Guten Morgen."))),
        pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(pasteboard.geschrieben == ["Guten Morgen."])
    #expect(coordinator.session == .idle)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func gescheiterterPreloadVerhindertDasDiktatNicht() async throws {
    // Der Preload ist reine Beschleunigung. /process lädt notfalls selbst nach.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("Trotzdem da.")),
                                 preloadFehler: .notReady("LLM lädt noch"))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(pasteboard.geschrieben == ["Trotzdem da."])

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func zuKurzesAntippenWirdKommentarlosVerworfen() async throws {
    // 100 ms bei 16 kHz = 1600 Werte, unter der Schwelle von 4800.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = makeCoordinator(hotkey: hotkey,
                                      recorder: FakeRecorder(samples: sprache(sekunden: 0.1)),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(client.processCount == 0, "ein Versehen darf die Engine gar nicht erst behelligen")
    #expect(pasteboard.geschrieben.isEmpty)
    #expect(coordinator.session == .idle, "ein Versehen ist kein Fehler")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func stilleMeldetMikrofonproblemUndLaesstDieZwischenablageInRuhe() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: stille()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Kein Ton aufgenommen — Mikrofon prüfen"))
    #expect(client.processCount == 0)
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage darf nie überschrieben werden")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func unpolierterTextGehtTrotzdemInDieZwischenablage() async throws {
    // M2-Vertrag: refined == false heißt "LLM ausgefallen, Rohtext ist da". KEIN Fehler.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(
        ergebnis("roher text", refined: false, fallbackReason: "LLM nicht geladen")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(pasteboard.geschrieben == ["roher text"], "ein Diktat darf nie verloren gehen")
    #expect(coordinator.session == .idle, "unpoliert ist kein Fehler")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func fehlerLaesstDieZwischenablageUnangetastet() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .failure(.processingFailed("STT kaputt")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(pasteboard.geschrieben.isEmpty,
            "ohne Ton und Overlay ist der alte Inhalt besser als Leere")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func erneutesDrueckenStartetSofortEineNeueAufnahmeUndVerspaeteteVerarbeitungUeberschreibtSieNicht() async throws {
    // Regel 6 (Brief) + Finding 2 (Review zu Task 4, Important): Die ursprüngliche Fassung
    // dieses Tests bewies nur die halbe Regel — "neue Aufnahme startet sofort". Die andere
    // Hälfte ("die alte Verarbeitung darf `.recording` NICHT überschreiben") blieb unbelegt:
    // `DictationClient.process()` löste sofort auf, die alte Verarbeitung war also längst durch
    // `beendeVerarbeitung()` gelaufen, bevor der zweite Tastendruck überhaupt verarbeitet wurde
    // — der Guard in `beendeVerarbeitung` kam gar nie in die Verlegenheit, etwas zu verhindern.
    // Der Reviewer belegte das, indem er den Guard entfernte: Der Test blieb grün.
    //
    // Hier deshalb ein torgesteuerter Client: Die erste Verarbeitung hängt, bis der Test sie
    // AUSDRÜCKLICH NACH dem zweiten Tastendruck auflöst — erst dann kann der Guard überhaupt
    // etwas zu tun bekommen.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let pasteboard = SpyPasteboard()
    let client = GatedDictationClient()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)

    // Sobald die (erste) Verarbeitung läuft — und dort hängt —, drücken wir erneut.
    var iterator = client.processGestartet.makeAsyncIterator()
    _ = await iterator.next()
    hotkey.send(.pressed)

    await warteBis { coordinator.session == .recording }
    #expect(coordinator.session == .recording, "der Nutzer wird nie ausgebremst")
    #expect(await recorder.startCount == 2)

    // Erst jetzt die alte, längst überholte Verarbeitung auflösen — NACHDEM die neue Aufnahme
    // bereits läuft. Das ist der eigentliche Test von Regel 6.
    client.freigeben(mit: .success(ergebnis("erstes")))
    // Die Zwischenablage wird IMMER beschrieben (unverhandelbar — kein Diktat geht verloren),
    // unabhängig vom Guard. Sobald das eingetroffen ist, ist `beendeVerarbeitung(id:...)` für
    // diese Verarbeitung garantiert durchgelaufen — sie ruft es synchron direkt danach auf (s.
    // `verarbeite`, "Kein `await`"-Kommentar) — ein deterministischer Synchronisationspunkt
    // ohne feste Wartezeit.
    await warteBis { pasteboard.geschrieben.contains("erstes") }

    #expect(coordinator.session == .recording,
           "eine verspätet eintreffende alte Verarbeitung darf die laufende neue Aufnahme nicht überschreiben")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func verweigertesMikrofonWirdGemeldet() async throws {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(fehlerBeimStart: .microphoneDenied)
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Mikrofonzugriff verweigert"))

    await coordinator.stop()
}

// MARK: - Ergänzung: verlorene Häppchen (AudioRecording.verloreneHaeppchen)

@MainActor
@Test(.timeLimit(.minutes(1)))
func verloreneHaeppchenWerdenAlsFehlerGemeldetUndNichtVerarbeitet() async throws {
    // AudioRecorder.stop() liefert seit Task 2 nicht mehr nur [Float], sondern zählt zusätzlich
    // Häppchen, deren Umrechnung fehlschlug (AudioRecording.verloreneHaeppchen). Ohne Auswertung
    // hier würde ein Diktat still um Wörter kürzer, ohne dass der Nutzer es je bemerkt — genau
    // der Zustand, den der Zähler verhindern soll. Deshalb: kein stiller Durchlauf zur Engine,
    // sondern ein regulärer Fehlschlag wie jeder andere, mit unangetasteter Zwischenablage.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = makeCoordinator(
        hotkey: hotkey,
        recorder: FakeRecorder(samples: sprache(), verloreneHaeppchen: 2),
        client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Teile der Aufnahme gingen verloren — bitte erneut versuchen"))
    #expect(client.processCount == 0, "eine lückenhafte Aufnahme darf die Engine gar nicht erst behelligen")
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage darf nie überschrieben werden")

    await coordinator.stop()
}

// MARK: - Ergänzung: stop() darf keine Aufnahme offen lassen

@MainActor
@Test(.timeLimit(.minutes(1)))
func beendenWaehrendDerAufnahmeSchliesstDasMikrofonWiederAb() async throws {
    // Wird der Koordinator beendet, während gerade aufgenommen wird (z. B. App-Exit mitten im
    // Diktat), kommt kein `.released` mehr an, das die Aufnahme regulär beenden würde. Ohne
    // ausdrückliches recorder.stop() in DictationCoordinator.stop() bliebe das Mikrofon für
    // immer offen — dieselbe Fehlerklasse wie das "Mikrofon endlos offen"-Finding aus Task 2.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }

    await coordinator.stop()

    #expect(await recorder.stopCount == 1, "eine offene Aufnahme muss beim Beenden gestoppt werden")
    #expect(await recorder.laeuft == false, "das Mikrofon darf nach stop() nicht mehr aktiv sein")
    #expect(coordinator.session == .idle)
}

// MARK: - Finding 1 (Review zu Task 4, Critical): stop() muss auf handlePressed() warten

@MainActor
@Test(.timeLimit(.minutes(1)))
func stopWaehrendHandlePressedNochInRecorderStartHaengtSchliesstDasMikrofonTrotzdem() async throws {
    // Finding 1 (Review zu Task 4, Critical): Kommt `stop()` an, während `handlePressed()`
    // noch in `recorder.start()` hängt (z. B. weil macOS gerade den Berechtigungsdialog
    // zeigt), war `session` zu diesem Zeitpunkt noch `.idle` — der alte
    // `if session == .recording`-Guard in `stop()` griff also nicht, und `stopHotkey()` bricht
    // die Hotkey-Task nur KOOPERATIV ab: `handlePressed()` lief nach dem Suspend fertig durch,
    // aktivierte den Recorder und setzte `session` auf `.recording` — NACHDEM `stop()` längst
    // zurückgekehrt war. Niemand rief danach je wieder `recorder.stop()` auf: das Mikrofon
    // blieb offen.
    let hotkey = FakeHotkey()
    let recorder = GatedRecorder(samples: sprache())
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    var iterator = recorder.startGestartet.makeAsyncIterator()
    _ = await iterator.next()
    // Ab hier hängt `handlePressed()` garantiert in `recorder.start()`, und `session` ist
    // garantiert noch `.idle` — `session = .recording` steht im Programmtext strikt NACH dem
    // Aufruf von `recorder.start()`, der noch nicht zurückgekehrt ist.
    #expect(coordinator.session == .idle)

    // `stop()` als eigene Task: Sie muss laut Fix jetzt auf die Hotkey-Task warten, darf also
    // erst zurückkehren, NACHDEM wir unten das Tor öffnen.
    let stopTask = Task { await coordinator.stop() }

    // Berechtigung jetzt (verspätet) erteilen — genau der reale Ablauf ("...klickt erst danach
    // 'Erlauben'").
    recorder.freigeben()

    await stopTask.value

    #expect(recorder.laeuft == false,
            "das Mikrofon darf nach stop() unter KEINEM Umstand mehr aktiv sein")
    #expect(recorder.stopCount == 1,
            "eine verspätet aktivierte Aufnahme muss stop() nachträglich erreichen")
    #expect(coordinator.session == .idle)
}

// MARK: - Finding 3 (Review zu Task 4, Important): nur die jüngste Verarbeitung setzt den Zustand

@MainActor
@Test(.timeLimit(.minutes(1)))
func aeltereVerarbeitungUeberschreibtNichtDenZustandDerNochLaufendenJuengeren() async throws {
    // Finding 3 (Review zu Task 4, Important): Laufen zwei Verarbeitungen nebeneinander
    // (realistisch: der Nutzer tippt ungeduldig erneut, weil er ohne Overlay und ohne Ton
    // 3–6 s lang keinerlei Rückmeldung hat), darf die ZUERST fertige (ältere) den Zustand
    // nicht setzen, während die jüngere noch läuft — sonst zeigt das Menüleisten-Symbol (die
    // einzige Rückmeldung dieser App) den Fehler eines längst abgehakten Diktats, oder
    // verschluckt einen echten späteren Fehlschlag, weil der Zustand schon auf `.idle` steht.
    // Beide Ergebnisse hier bewusst ERFOLGREICH (nicht einer davon ein Fehler): So lässt sich
    // die Reihenfolge über die Zwischenablage beweisen, statt nur über den (weniger
    // aussagekräftigen) `.failed`-Text.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = GatedDictationClient()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    // Erstes Diktat: press → release → Verarbeitung #1 (älter) startet und hängt am Gate.
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    var iterator = client.processGestartet.makeAsyncIterator()
    _ = await iterator.next()

    // Zweites Diktat, während #1 noch hängt: press → release → Verarbeitung #2 (jünger)
    // startet und hängt ebenfalls am Gate. `verarbeitungen` enthält jetzt echt ZWEI parallel
    // laufende Verarbeitungen — der Fall, den Finding 3 beschreibt.
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    _ = await iterator.next()

    // Die ÄLTERE (#1) zuerst auflösen — bevor die jüngere (#2) fertig ist.
    client.freigeben(mit: .success(ergebnis("ALT")))
    // Deterministischer Synchronisationspunkt ohne feste Wartezeit: Die Zwischenablage wird
    // IMMER beschrieben (unverhandelbar), unabhängig davon, ob #1 den Zustand setzen darf.
    // Sobald "ALT" dort steht, ist `beendeVerarbeitung(id: id1, …)` synchron durchgelaufen.
    await warteBis { pasteboard.geschrieben.contains("ALT") }

    // Die eigentliche Prüfung von Finding 3: #2 läuft noch — die Anzeige muss weiterhin
    // ".processing" zeigen, NICHT von der längst überholten #1 auf ".idle" gezogen worden sein.
    #expect(coordinator.session == .processing,
           "die ältere, längst überholte Verarbeitung darf den Zustand nicht setzen, solange die jüngere noch läuft")

    // Jetzt die JÜNGERE (#2) auflösen — sie darf den Zustand setzen.
    client.freigeben(mit: .success(ergebnis("NEU")))
    await warteBis { coordinator.session == .idle }

    #expect(coordinator.session == .idle)
    // Unverhandelbar: Auch das ÄLTERE, längst überholte Diktat darf nie verloren gehen — sein
    // Ergebnis landet trotzdem in der Zwischenablage, nur der Zustand folgt ihm nicht mehr.
    #expect(pasteboard.geschrieben == ["ALT", "NEU"],
           "beide Diktate müssen ankommen, in der Reihenfolge, in der sie fertig wurden")

    await coordinator.stop()
}

// MARK: - Finding 4 (Review zu Task 4, Minor): stop() gibt beim Beenden eine Obergrenze nicht auf

@MainActor
@Test(.timeLimit(.minutes(1)))
func stopGibtBeiEinerHaengendenVerarbeitungNachDemZeitlimitAufOhneSieAbzubrechen() async throws {
    // Finding 4 (Review zu Task 4, Minor): Ohne Obergrenze würde `stop()` bis zum eigenen
    // Timeout des Sidecars warten (180 s in der echten `HTTPSidecarClient`) — beim Beenden der
    // App ein spürbarer Hänger, den macOS irgendwann mit „Beenden erzwingen" quittiert.
    //
    // Damit dieser Test unter einer Mutation (Zeitlimit entfernt → `stop()` wartet wieder
    // unbegrenzt auf `task.value`) ROT statt HÄNGEND wird — dieselbe Falle, vor der der Auftrag
    // warnt (s. auch `AudioRecorderTests.swift`) —, hängt das Gate hier NICHT vom Rückkehren
    // von `stop()` ab: Eine eigene, unabhängige Sicherheitsfreigabe löst es nach
    // `sicherheitsFreigabeVerzoegerung` auf — deutlich SPÄTER als das injizierte
    // `beendenZeitlimit`, aber immer noch weit innerhalb von `.timeLimit`. Kehrt `stop()` (wie
    // vorgesehen) schon vorher zurück, sind Zwischenablage und Zustand zu diesem Zeitpunkt
    // beweisbar noch unberührt — die Prüfungen unten greifen. Bliebe `stop()` dagegen (unter
    // Mutation) hängen, bis die Sicherheitsfreigabe feuert, kehrt es zwar irgendwann zurück,
    // aber die Zwischenablage ist dann schon beschrieben — die Prüfung unten schlägt sichtbar
    // fehl, statt dass der Test ewig hängt.
    let sicherheitsFreigabeVerzoegerung = Duration.milliseconds(1_000)
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = GatedDictationClient()
    let coordinator = DictationCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                           client: client, pasteboard: pasteboard,
                                           beendenZeitlimit: .milliseconds(50),
                                           beendenPollIntervall: .milliseconds(5))
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)

    var iterator = client.processGestartet.makeAsyncIterator()
    _ = await iterator.next()
    // Ab hier hängt die Verarbeitung garantiert — wir lösen sie hier absichtlich nicht selbst
    // auf, sondern erst über die unten gestartete, zeitversetzte Sicherheitsfreigabe. Genau das
    // Szenario "Sidecar antwortet nicht".

    Task {
        try? await Task.sleep(for: sicherheitsFreigabeVerzoegerung)
        client.freigeben(mit: .success(ergebnis("verspätet")))
    }

    await coordinator.stop()

    #expect(coordinator.session == .idle, "stop() muss trotz hängender Verarbeitung zurückkehren")
    #expect(pasteboard.geschrieben.isEmpty,
           "stop() darf nach Ablauf des Zeitlimits nicht mehr auf das Ergebnis gewartet haben")
}

// MARK: - C1 (Review M4, Critical): verlorenes .released darf das Mikrofon nicht für immer offen lassen

@MainActor
@Test(.timeLimit(.minutes(1)))
func verwaisteAufnahmeWirdVorNeustartVerworfen() async throws {
    // C1 (Review M4, Critical): Schaltet macOS den CGEventTap kurz ab (`.tapDisabledByTimeout`,
    // s. `FnKeyMonitor.handle`) und fällt GENAU das Loslassen in dieses Fenster, kommt nie ein
    // `.released` an — `session` bleibt auf `.recording` hängen, während der Recorder
    // tatsächlich noch aufnimmt. Hier nachgestellt durch zwei `.pressed` OHNE ein
    // dazwischenliegendes `.released`: aus Sicht des Koordinators exakt dasselbe Bild wie ein
    // verlorenes Ereignis. `handlePressed()` muss die verwaiste Aufnahme JETZT zuerst verwerfen,
    // bevor es neu startet — sonst würde (auf dem echten Recorder) dieselbe Aufnahme unbemerkt
    // weiterlaufen, und das spätere `stop()` läge die GESAMTE Zwischenzeit als Diktat vor.
    //
    // `FakeRecorder.start()` wirft jetzt `.alreadyRecording`, wenn es aufgerufen wird, während
    // `laeuft == true` ist (bildet den Vertrag von `AVAudioEngineRecorder.start()` nach, s.
    // dort) — OHNE den Fix in `handlePressed()` bricht der zweite Tastendruck deshalb mit
    // `.failed(...)` ab, statt (wie mit Fix) eine frische Aufnahme zu starten. Das macht die
    // Mutationsprobe beweiskräftig, ohne echte Hardware zu brauchen.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("zweite Aufnahme")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    #expect(await recorder.startCount == 1)

    // Das "verlorene" .released kommt hier nie an — stattdessen drückt der Nutzer erneut.
    hotkey.send(.pressed)
    hotkey.send(.released)
    await warteBis {
        if case .failed = coordinator.session { return true }
        return coordinator.session == .idle
    }

    #expect(coordinator.session == .idle,
           "die verwaiste Aufnahme muss verworfen und danach eine frische gestartet worden sein")
    #expect(await recorder.startCount == 2, "nach dem Verwerfen muss sofort neu gestartet werden")
    #expect(client.processCount == 1, "genau EINE Verarbeitung — die der frischen Aufnahme")
    #expect(pasteboard.geschrieben == ["zweite Aufnahme"],
           "nur die frische Aufnahme darf in der Zwischenablage landen")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func wachhundBrichtEineNieLosgelasseneAufnahmeNachDerObergrenzeSelbsttaetigAb() async throws {
    // C1 (Review M4, Critical): Ohne diesen Watchdog gibt es aus einem hängen gebliebenen
    // `.recording` KEINEN Weg mehr zurück außer einem erneuten Tastendruck (s.
    // `verwaisteAufnahmeWirdVorNeustartVerworfen`). Die Spec hatte dafür ursprünglich
    // `case recording(since:)` vorgesehen — hier stattdessen ein injizierbares, für den Test
    // winzig gehaltenes Zeitlimit, damit der Test nicht 120 echte Sekunden braucht.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = DictationCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                           pasteboard: pasteboard,
                                           aufnahmeObergrenze: .milliseconds(30))
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }

    // Absichtlich KEIN .released — genau das Szenario, das den Watchdog braucht.
    await warteBisMitEchterZeit {
        if case .failed = coordinator.session { return true }
        return false
    }

    #expect(coordinator.session == .failed("Aufnahme abgebrochen — Taste nicht losgelassen?"))
    #expect(await recorder.laeuft == false, "das Mikrofon muss nach dem Abbruch wieder zu sein")
    #expect(client.processCount == 0, "eine abgebrochene Aufnahme darf die Engine nie erreichen")
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage darf nie überschrieben werden")

    await coordinator.stop()
}
