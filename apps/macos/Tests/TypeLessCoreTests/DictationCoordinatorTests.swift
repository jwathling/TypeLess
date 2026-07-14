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

/// Steuerbarer Tastendruck-Zähler (I1, Review M4, Important) — bildet
/// `CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)` nach, ohne
/// echte Tastendrücke zu brauchen. Startet bewusst bei `0` und bleibt dort, bis der Test
/// `druecke()` aufruft — ein REALER `SystemKeyDownCounter` als Default wäre hier gefährlich:
/// Er zählt SYSTEMWEIT, nicht app-bezogen, tippt also z. B. auch die Terminal-Eingabe mit, in
/// der `swift test` gerade läuft — Tests, die ihn nicht explizit steuern, würden dadurch
/// nichtdeterministisch (Fn-als-Modifier-Erkennung würde scheinbar zufällig zuschlagen).
final class FakeKeyDownCounter: KeyDownCounter, @unchecked Sendable {
    private let lock = NSLock()
    private var stand: UInt32 = 0

    func aktuellerStand() -> UInt32 { lock.lock(); defer { lock.unlock() }; return stand }

    /// Simuliert Tastendrücke, während Fn unten ist (Fn-als-Modifier, z. B. Fn+Pfeil).
    func druecke(_ anzahl: UInt32 = 1) {
        lock.lock(); stand += anzahl; lock.unlock()
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

/// Steuerbare Antwort auf „wohin darf eingefügt werden?" (M5).
final class FakeTarget: InsertionTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var app: pid_t?
    private var ziel: Fokusziel

    init(app: pid_t? = 42, ziel: Fokusziel = .beschreibbaresTextfeld) {
        self.app = app
        self.ziel = ziel
    }

    /// Simuliert, dass der Anwender in eine ANDERE App gewechselt ist.
    func wechsleApp(zu neue: pid_t?) { lock.lock(); app = neue; lock.unlock() }
    func setzeZiel(_ neues: Fokusziel) { lock.lock(); ziel = neues; lock.unlock() }

    func vordersteApp() -> pid_t? { lock.lock(); defer { lock.unlock() }; return app }
    func fokusziel() -> Fokusziel { lock.lock(); defer { lock.unlock() }; return ziel }
}

/// Schreibt nur mit, was getippt WORDEN WÄRE — im Test erscheint nirgends echter Text (M5).
final class SpyInserter: TextInserter, @unchecked Sendable {
    private let lock = NSLock()
    private var _getippt: [String] = []
    private let fehler: TextInserterError?

    init(fehler: TextInserterError? = nil) { self.fehler = fehler }

    var getippt: [String] { lock.lock(); defer { lock.unlock() }; return _getippt }

    func insert(_ text: String) throws {
        if let fehler { throw fehler }
        lock.lock(); _getippt.append(text); lock.unlock()
    }
}

@MainActor
func makeCoordinator(hotkey: HotkeyMonitor, recorder: AudioRecorder,
                     client: SidecarClient, pasteboard: Pasteboard,
                     inserter: TextInserter = SpyInserter(),
                     target: InsertionTarget = FakeTarget(),
                     keyDownCounter: KeyDownCounter = FakeKeyDownCounter(),
                     aufnahmeObergrenze: Duration = .seconds(120)) -> DictationCoordinator {
    // Auf Protokolltypen verbreitert (statt der konkreten Attrappen `FakeRecorder`/
    // `DictationClient`/`FakeHotkey`/`SpyPasteboard`): Damit lassen sich auch die torgesteuerten
    // Doubles `GatedRecorder`/`GatedDictationClient` (Findings 1–3, Review zu Task 4) hier
    // durchreichen, ohne einen zweiten, praktisch identischen Hilfsaufbau zu brauchen. Bestehende
    // Aufrufstellen sind unverändert gültig — jede konkrete Attrappe erfüllt ihr Protokoll.
    //
    // `keyDownCounter` Default `FakeKeyDownCounter()` (NICHT `SystemKeyDownCounter()`, s. dort):
    // Ein feststehender Zähler, der nie von selbst steigt — bestehende Tests, die Fn nie als
    // Modifier benutzen, bleiben damit unberührt von I1 (Review M4).
    //
    // M5: `inserter`/`target` Defaults `SpyInserter()`/`FakeTarget()` — NIE die echten
    // `CGEventTextInserter`/`AXInsertionTarget`: Sonst würde ein Testlauf tatsächlich Text in das
    // gerade vorderste Fenster tippen (in der Regel das Terminal, in dem `swift test` läuft) und
    // die Weiche „darf getippt werden?" hinge am Rechtezustand der Maschine.
    DictationCoordinator(hotkey: hotkey, recorder: recorder, client: client, pasteboard: pasteboard,
                         inserter: inserter, target: target,
                         aufnahmeObergrenze: aufnahmeObergrenze,
                         keyDownCounter: keyDownCounter)
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
func loslassenVerarbeitetUndStelltDenTextZu() async throws {
    // M5: Hieß bis M4 `loslassenVerarbeitetUndSchreibtInDieZwischenablage` und prüfte
    // `pasteboard.geschrieben` — das ist seit M5 fachlich falsch: Im Normalfall (dieselbe App,
    // beschreibbares Textfeld) wird DIREKT eingefügt, und die Zwischenablage bleibt unangetastet.
    // Der Test prüft unverändert dasselbe: Nach dem Loslassen kommt der Text beim Anwender an,
    // und der Zustand kehrt nach `.idle` zurück — nur der Weg dorthin ist ein anderer.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let coordinator = makeCoordinator(
        hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
        client: DictationClient(ergebnis: .success(ergebnis("Guten Morgen."))),
        pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(inserter.getippt == ["Guten Morgen."])
    #expect(pasteboard.geschrieben.isEmpty)
    #expect(coordinator.session == .idle)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func diktatWaehrendDieEngineNochAufwaermtErklaertSichVerstaendlich() async throws {
    // Seit der Hotkey sofort beim Programmstart steht (und nicht mehr erst nach ~20 s hinter der
    // aufwärmenden Engine hängt, s. `AppDelegate.applicationDidFinishLaunching`), ist das ein
    // Fall, den der Anwender im Alltag WIRKLICH trifft: App gestartet, sofort Fn gedrückt.
    // Der Rohgrund des Servers („starting“) sagt ihm nichts — die Meldung muss erklären, was zu
    // tun ist. Und wie bei JEDEM Fehlschlag: die Zwischenablage bleibt unangetastet.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .failure(.notReady("starting")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { true } else { false } }

    #expect(coordinator.session == .failed("Engine wärmt noch auf — gleich nochmal versuchen"),
            "der Rohgrund des Servers darf dem Anwender nicht vorgesetzt werden")
    #expect(pasteboard.geschrieben.isEmpty,
            "auch hier gilt: alter Inhalt der Zwischenablage schlägt Leere")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func gescheiterterPreloadVerhindertDasDiktatNicht() async throws {
    // Der Preload ist reine Beschleunigung. /process lädt notfalls selbst nach.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .success(ergebnis("Trotzdem da.")),
                                 preloadFehler: .notReady("LLM lädt noch"))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    // M5: Prüfte bis M4 `pasteboard.geschrieben` — der Text wird jetzt direkt eingefügt. Die
    // Zusicherung des Tests ist unverändert: Ein gescheiterter Preload kostet das Diktat nichts.
    #expect(inserter.getippt == ["Trotzdem da."])
    #expect(pasteboard.geschrieben.isEmpty)

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
func unpolierterTextWirdTrotzdemZugestellt() async throws {
    // M2-Vertrag: refined == false heißt "LLM ausgefallen, Rohtext ist da". KEIN Fehler.
    //
    // M5: Hieß bis M4 `unpolierterTextGehtTrotzdemInDieZwischenablage`. Die Zusicherung ist
    // dieselbe geblieben (ein Diktat darf nie verloren gehen), nur der Weg: Im Normalfall wird
    // direkt eingefügt statt kopiert.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .success(
        ergebnis("roher text", refined: false, fallbackReason: "LLM nicht geladen")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(inserter.getippt == ["roher text"], "ein Diktat darf nie verloren gehen")
    #expect(pasteboard.geschrieben.isEmpty)
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
    let inserter = SpyInserter()
    let client = GatedDictationClient()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: pasteboard, inserter: inserter)
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
    // Der Text wird IMMER zugestellt (unverhandelbar — kein Diktat geht verloren), unabhängig vom
    // Guard. Hier steht der Anwender noch in derselben App (die `FakeTarget`-Vorgabe wechselt
    // nicht), also wird direkt eingefügt. Sobald das eingetroffen ist, ist
    // `beendeVerarbeitung(id:…)` für diese Verarbeitung garantiert durchgelaufen — sie ruft es
    // synchron direkt danach auf (s. `verarbeite`, "Kein `await`"-Kommentar) — ein
    // deterministischer Synchronisationspunkt ohne feste Wartezeit.
    //
    // M5: Bis M4 lief dieser Synchronisationspunkt über `pasteboard.geschrieben` — die
    // Zwischenablage ist im Normalfall jetzt nicht mehr der Zustellweg.
    await warteBis { inserter.getippt.contains("erstes") }

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
    // die Reihenfolge über die Zustellung beweisen, statt nur über den (weniger
    // aussagekräftigen) `.failed`-Text.
    //
    // M5: Die Reihenfolge wurde bis M4 über `pasteboard.geschrieben` bewiesen — beide Diktate
    // gehen jetzt (dieselbe App, beschreibbares Textfeld) den direkten Weg über den `inserter`.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = GatedDictationClient()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard, inserter: inserter)
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
    // Deterministischer Synchronisationspunkt ohne feste Wartezeit: Der Text wird IMMER zugestellt
    // (unverhandelbar), unabhängig davon, ob #1 den Zustand setzen darf. Sobald "ALT" getippt ist,
    // ist `beendeVerarbeitung(id: id1, …)` synchron durchgelaufen.
    await warteBis { inserter.getippt.contains("ALT") }

    // Die eigentliche Prüfung von Finding 3: #2 läuft noch — die Anzeige muss weiterhin
    // ".processing" zeigen, NICHT von der längst überholten #1 auf ".idle" gezogen worden sein.
    #expect(coordinator.session == .processing,
           "die ältere, längst überholte Verarbeitung darf den Zustand nicht setzen, solange die jüngere noch läuft")

    // Jetzt die JÜNGERE (#2) auflösen — sie darf den Zustand setzen.
    client.freigeben(mit: .success(ergebnis("NEU")))
    await warteBis { coordinator.session == .idle }

    #expect(coordinator.session == .idle)
    // Unverhandelbar: Auch das ÄLTERE, längst überholte Diktat darf nie verloren gehen — es wird
    // trotzdem zugestellt, nur der Zustand folgt ihm nicht mehr.
    #expect(inserter.getippt == ["ALT", "NEU"],
           "beide Diktate müssen ankommen, in der Reihenfolge, in der sie fertig wurden")
    #expect(pasteboard.geschrieben.isEmpty)

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
    //
    // M5: Bewiesen wird das jetzt am `inserter` statt an der Zwischenablage — die verspätete
    // Verarbeitung würde ihren Text direkt einfügen (dieselbe App, beschreibbares Textfeld).
    // `inserter`/`target` müssen hier ausdrücklich mitgegeben werden: Dieser Test baut den
    // Koordinator direkt (nicht über `makeCoordinator`), und dessen echte Defaults
    // (`CGEventTextInserter`/`AXInsertionTarget`) würden im Testlauf in das gerade vorderste
    // Fenster tippen.
    let sicherheitsFreigabeVerzoegerung = Duration.milliseconds(1_000)
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = GatedDictationClient()
    let coordinator = DictationCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                           client: client, pasteboard: pasteboard,
                                           inserter: inserter, target: FakeTarget(),
                                           beendenZeitlimit: .milliseconds(50),
                                           beendenPollIntervall: .milliseconds(5),
                                           keyDownCounter: FakeKeyDownCounter())
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
    #expect(inserter.getippt.isEmpty,
           "stop() darf nach Ablauf des Zeitlimits nicht mehr auf das Ergebnis gewartet haben")
    #expect(pasteboard.geschrieben.isEmpty)
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
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .success(ergebnis("zweite Aufnahme")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: pasteboard, inserter: inserter)
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
    // M5: Bis M4 an `pasteboard.geschrieben` geprüft — zugestellt wird jetzt direkt.
    #expect(inserter.getippt == ["zweite Aufnahme"],
           "nur die frische Aufnahme darf beim Anwender ankommen")
    #expect(pasteboard.geschrieben.isEmpty)

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
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    // M5: `inserter`/`target` ausdrücklich mitgeben — dieser Test baut den Koordinator direkt
    // (wegen der kurzen `aufnahmeObergrenze`), und die echten Defaults würden im Testlauf in das
    // vorderste Fenster tippen.
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: pasteboard, inserter: inserter,
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
    #expect(inserter.getippt.isEmpty, "eine abgebrochene Aufnahme darf nirgends getippt werden")

    await coordinator.stop()
}

// MARK: - I1 (Review M4, Important): Fn als Modifier darf die Zwischenablage nicht überschreiben

@MainActor
@Test(.timeLimit(.minutes(1)))
func fnAlsModifierWirdKommentarlosVerworfen() async throws {
    // I1 (Review M4, Important): Hält der Nutzer Fn+Pfeil (oder eine andere Fn-Kombination)
    // länger als die Diktat-Mindestdauer (beim mehrfachen Drücken normal), passieren beide Tore
    // — die Mindestdauer ist überschritten, und das Stille-Gate greift nicht (Raumrauschen/
    // Tastaturklappern liegen über -50 dBFS). Ohne den Zähler würde TypeLess also normal
    // weiterverarbeiten, und Whisper würde aus dem Rauschen halluzinieren. Der Zähler erkennt
    // den Tastendruck, OHNE zu wissen, welche Taste es war (s. `KeyDownCounter`).
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let counter = FakeKeyDownCounter()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: pasteboard, keyDownCounter: counter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    counter.druecke()   // Fn+Pfeil: mindestens eine Zeichentaste, während Fn unten ist
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(client.processCount == 0, "Fn-als-Modifier darf die Engine gar nicht erst behelligen")
    #expect(await recorder.laeuft == false, "das Mikrofon muss trotzdem sauber geschlossen werden")
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage darf nie überschrieben werden")
    #expect(coordinator.session == .idle, "kein Fehler — kommentarlos verworfen")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func normalesDiktatBleibtUnberuehrtWennDerZaehlerWaehrendDerAufnahmeNichtSteigt() async throws {
    // Regressionsschutz zu I1: Steigt der Zähler NICHT (der Normalfall — reines Diktieren ohne
    // Zeichentasten), darf die neue Prüfung ein normales Diktat nicht beeinträchtigen.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .success(ergebnis("normales Diktat")))
    let counter = FakeKeyDownCounter()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard, inserter: inserter,
                                      keyDownCounter: counter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    // M5: Bis M4 an `pasteboard.geschrieben` geprüft — zugestellt wird jetzt direkt.
    #expect(inserter.getippt == ["normales Diktat"])
    #expect(pasteboard.geschrieben.isEmpty)
    #expect(client.processCount == 1)

    await coordinator.stop()
}

// MARK: - I2 (Review M4, Important): Geräteumschwenk während der Aufnahme kürzt sie nicht stillschweigend

@MainActor
@Test(.timeLimit(.minutes(1)))
func geraetewechselWaehrendDerAufnahmeWirdAlsFehlerGemeldetUndNichtVerarbeitet() async throws {
    // I2 (Review M4, Important): Verbinden sich während des Diktats die AirPods (oder wackelt
    // Bluetooth), stoppt AVAudioEngine sich bei einem Konfigurationswechsel SELBST — ab da
    // kommen keine Puffer mehr, aber stop() liefert trotzdem brav, was bis dahin da war:
    // verloreneHaeppchen == 0, nicht stumm, über der Mindestdauer. Ohne diese Prüfung ginge die
    // HALBE Aufnahme unbemerkt an die Engine — der Nutzer hielte die Transkription für schlecht,
    // statt den Abbruch zu bemerken. Dieselbe Behandlung wie verloreneHaeppchen.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = makeCoordinator(
        hotkey: hotkey,
        recorder: FakeRecorder(samples: sprache(), geraeteWechsel: true),
        client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Audiogerät hat gewechselt — bitte erneut versuchen"))
    #expect(client.processCount == 0, "eine unbrauchbar gewordene Aufnahme darf die Engine gar nicht erst behelligen")
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage darf nie überschrieben werden")

    await coordinator.stop()
}

// MARK: - N2 (Re-Review M4, Minor): ein gescheitertes start() darf kein offenes Mikrofon hinterlassen

@MainActor
@Test(.timeLimit(.minutes(1)))
func alreadyRecordingBeimStartSchliesstDasMikrofonUndLegtDasDiktatNichtDauerhaftLahm() async throws {
    // N2 (Re-Review M4, Minor): Wirft `recorder.start()` ein `.alreadyRecording`, lief der
    // Recorder bisher WEITER (der generische `catch` setzte nur `session = .failed`), und ein
    // Watchdog wurde nicht armiert — der startet erst danach. Das ist exakt der C1-Zustand, nur
    // ohne Ausweg: Der nächste Druck sieht `session != .recording`, überspringt den Verwerf-Stop
    // in `handlePressed()`, und `start()` wirft erneut. Mikrofon dauerhaft offen, Diktat dauerhaft
    // tot.
    //
    // Nachgestellt durch einen Recorder, der bereits LÄUFT, ohne dass der Koordinator davon weiß
    // (`session == .idle`) — genau die Lage, in der `handlePressed()` seinen Verwerf-Stop
    // überspringt. `FakeRecorder.start()` wirft dann `.alreadyRecording` (bildet den Vertrag von
    // `AVAudioEngineRecorder` nach, s. dort).
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .success(ergebnis("frisches Diktat")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    try await recorder.start()
    #expect(await recorder.laeuft == true, "Vorbedingung: das Mikrofon ist offen")

    hotkey.send(.pressed)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Aufnahme nicht möglich: alreadyRecording"))
    #expect(await recorder.laeuft == false,
           "ein gescheitertes start() darf unter KEINEM Umstand ein offenes Mikrofon hinterlassen")
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage bleibt bei jedem Fehlschlag unangetastet")

    // Der eigentliche Beweis: KEIN dauerhaft toter Zustand. Der nächste Druck muss wieder ganz
    // normal aufnehmen und ein Diktat abliefern.
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    #expect(coordinator.session == .recording, "nach dem Fehlschlag muss ein Diktat wieder möglich sein")

    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    // M5: Bis M4 an `pasteboard.geschrieben` geprüft — zugestellt wird jetzt direkt.
    #expect(inserter.getippt == ["frisches Diktat"])
    #expect(pasteboard.geschrieben.isEmpty)
    #expect(client.processCount == 1)

    await coordinator.stop()
}

// MARK: - I3 (Review M4, Important): unerwartetes Streamende zeigt einen toten Hotkey an

@MainActor
@Test(.timeLimit(.minutes(1)))
func unerwartetesEndeDesHotkeyStreamsWirdAlsHotkeyAusfallGemeldet() async throws {
    // I3 (Review M4, Important): FnKeyMonitor.start() war als `throws` deklariert, warf aber
    // nie — der echte Fehlerfall (fehlende Eingabeüberwachung) endete nur den Stream, auf einem
    // anderen Thread, ohne je durch den (unerreichbaren) `catch`-Zweig in
    // DictationCoordinator.start() zu laufen. `beendeStreamUnerwartet()` bildet genau das nach:
    // der Stream endet, OHNE dass der Koordinator `stop()` aufgerufen hat.
    let hotkey = FakeHotkey()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(),
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()
    #expect(coordinator.session == .idle)

    hotkey.beendeStreamUnerwartet()

    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Hotkey inaktiv — Eingabeüberwachung fehlt"))

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func zweiterStartBeiLebendemHotkeyMeldetKeinenAusfall() async throws {
    // N1 (Re-Review M4, Important): Die Unterscheidung „erwartetes/unerwartetes Streamende" hing
    // an einem Instanz-Flag (`erwarteteHotkeyBeendigung`). Das war deterministisch falsch — kein
    // Race, alles auf dem MainActor: `start()` rief `stopHotkey()` (Flag `true`, alte Task
    // gecancelt, alter Stream beendet) und setzte das Flag sofort danach, OHNE jeden
    // Suspension-Punkt, wieder auf `false`. Die alte Task kam bis dahin gar nicht zum Zug; lief
    // sie danach aus, sah sie ein `false` und meldete „Hotkey inaktiv — Eingabeüberwachung fehlt",
    // obwohl der neue Hotkey einwandfrei lief. Jetzt hängt die Unterscheidung an der IDENTITÄT der
    // Task (`Task.isCancelled`).
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()
    await coordinator.start()   // zweiter Start bei LEBENDEM Hotkey

    // Der alten Task Gelegenheit geben, ihren Schwanz auszulaufen — genau dort schlug der Fehler
    // zu. `warteBis` ist beschränkt und kehrt in jedem Fall zurück (kein Hängen), auch wenn die
    // Bedingung nie eintritt.
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .idle,
           "ein zweiter start() bei lebendem Hotkey darf keinen Hotkey-Ausfall melden")

    // Und der Hotkey lebt wirklich: Ein Druck kommt weiterhin an.
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    #expect(coordinator.session == .recording, "der neu gestartete Hotkey muss Ereignisse liefern")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func hotkeyDerNieStartetWirdBeimStartAlsAusfallGemeldet() async throws {
    // I3 (Review M4, Important): Fehlt die Berechtigung schon beim ALLERERSTEN Start (der
    // Stream endet, bevor er auch nur ein Ereignis liefert), muss der Koordinator das ebenfalls
    // als toten Hotkey erkennen — nicht erst bei einem SPÄTER unerwartet endenden Stream.
    let hotkey = FakeHotkey(stirbtSofort: true)
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(),
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()

    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Hotkey inaktiv — Eingabeüberwachung fehlt"))

    await coordinator.stop()
}

// MARK: - M5: die vier Bedingungen der Zustellung

@MainActor
@Test(.timeLimit(.minutes(1)))
func normalfallTipptDirektUndLaesstDieZwischenablageInRuhe() async throws {
    // Der Fall, für den M5 gebaut wird — und die wichtigste Zusicherung des Anwenders:
    // "Diktieren und Kopieren dürfen sich nicht gegenseitig stören."
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Guten Morgen.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(inserter.getippt == ["Guten Morgen."], "der Text muss direkt eingefügt werden")
    #expect(pasteboard.geschrieben.isEmpty,
            "die Zwischenablage bleibt im Normalfall UNANGETASTET — Entscheidung des Anwenders")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func appWechselWaehrendDerVerarbeitungVerhindertDasTippen() async throws {
    // Der gefährlichste Fall: Zwischen Loslassen und fertigem Text vergehen ~6 s. Klickt der
    // Anwender in dieser Zeit in ein anderes Fenster, würde ungeprüftes Tippen sein Diktat in
    // einen Slack-Chat oder ein Suchfeld schreiben.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Geheimer Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    // Der Anwender klickt woanders hin, WÄHREND verarbeitet wird.
    target.wechsleApp(zu: 99)
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty, "NIEMALS in ein fremdes Fenster tippen")
    #expect(pasteboard.geschrieben == ["Geheimer Text."],
            "der Text darf nicht verloren gehen — er landet in der Zwischenablage")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func ohneTextfeldImFokusWirdNichtGetippt() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .keinTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty, "ohne Textfeld gibt es keinen Ort zum Tippen")
    #expect(pasteboard.geschrieben == ["Text."])

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func inEinPasswortfeldWirdNiemalsGetippt() async throws {
    // Sicherheitsregel, nicht verhandelbar.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .passwortfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty, "in ein Passwortfeld tippt TypeLess GRUNDSÄTZLICH nicht")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func ohneBedienungshilfenWirdNichtGetippt() async throws {
    // `.unbekannt` heißt: Das Recht fehlt, TypeLess kann es nicht wissen. Dann wird nicht
    // geraten — würde getippt, käme nichts an, und das Diktat wäre spurlos weg.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .unbekannt)
    let client = DictationClient(ergebnis: .success(ergebnis("Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty)
    #expect(pasteboard.geschrieben == ["Text."], "ohne Recht ist die Zwischenablage der einzige Weg")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func scheiterndesTippenVerliertDasDiktatNicht() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter(fehler: .ereignisNichtErzeugbar)
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Wichtiger Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(pasteboard.geschrieben == ["Wichtiger Text."],
            "ein Diktat darf NIE verloren gehen — auch nicht, wenn das Tippen scheitert")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func engineFehlerLaesstDieZwischenablageUnangetastet() async throws {
    // Die M4-Regel, die BLEIBT: Bei einem echten Fehler ist der alte Inhalt der Zwischenablage
    // besser als Leere.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .failure(.unreachable))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { true } else { false } }

    #expect(pasteboard.geschrieben.isEmpty, "bei einem echten Fehler bleibt sie unangetastet")
    #expect(inserter.getippt.isEmpty)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func jedesDiktatPruftSeinenEigenenGemerktenFokus() async throws {
    // Die GEFALLENE M4-Regel. In M4 galt: "Die Zwischenablage bekommt JEDES Ergebnis, auch das
    // einer überholten Verarbeitung." Mit automatischem Einfügen wäre das fatal — ein überholtes
    // Diktat würde in das Fenster tippen, in dem der Anwender INZWISCHEN steht.
    //
    // Neu: Jedes Diktat merkt sich beim Fn-Druck SEINE Ziel-App und prüft beim Zustellen genau
    // diese. Hier: Das erste Diktat wird in App 42 gesprochen; danach wechselt der Anwender in
    // App 99 und diktiert dort erneut. Das erste Ergebnis darf NICHT in App 99 getippt werden.
    //
    // I1 (Review zu Task 4, Important): Dieser Test brauchte ZWEI Diktate — vorher drückte er nur
    // einmal, wechselte die App und ließ los. Damit war er ein Duplikat von
    // `appWechselWaehrendDerVerarbeitungVerhindertDasTippen`, und der eigentliche Unterschied
    // ("EIGENER gemerkter Fokus" statt "Fokus der JÜNGSTEN Verarbeitung") blieb unsichtbar, weil es
    // nur EINE Verarbeitung gab: Ersetzte man die Übergabe in `verarbeite` durch
    // `zielApp: self?.zielAppBeimDruck ?? zielApp` — genau das, was ein späterer "Aufräum"-Refactor
    // täte —, blieb alles grün. Erst mit einer zweiten, JÜNGEREN Verarbeitung (die
    // `zielAppBeimDruck` auf 99 gesetzt hat) unterscheiden sich die beiden Ausdrücke: Der überholte
    // Erste läge dann bei 99 == 99 und tippte in die FREMDE App. Torgesteuerter Client, damit beide
    // Verarbeitungen wirklich gleichzeitig offen sind — Muster wie in
    // `aeltereVerarbeitungUeberschreibtNichtDenZustandDerNochLaufendenJuengeren`.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = GatedDictationClient()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    // Erstes Diktat in App 42 — die Verarbeitung (#1) startet und hängt am Tor.
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    var iterator = client.processGestartet.makeAsyncIterator()
    _ = await iterator.next()

    // Der Anwender wechselt nach App 99 und diktiert DORT erneut, während #1 noch läuft. Damit
    // steht `zielAppBeimDruck` jetzt auf 99 — der überholte Erste darf sich davon nicht
    // beeindrucken lassen.
    target.wechsleApp(zu: 99)
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    _ = await iterator.next()

    // Das ÜBERHOLTE erste Ergebnis zuerst auflösen: Es gehört nach App 42, der Anwender steht aber
    // in App 99.
    client.freigeben(mit: .success(ergebnis("Erstes Diktat.")))
    // Synchronisationspunkt ohne feste Wartezeit, der unter BEIDEN Ausgängen greift (richtig:
    // Zwischenablage; mutiert: getippt) — so kann dieser Test unter der Mutation nicht hängen,
    // sondern wird sichtbar rot.
    await warteBis { !pasteboard.geschrieben.isEmpty || !inserter.getippt.isEmpty }

    #expect(inserter.getippt.isEmpty,
            "das Diktat aus App 42 darf niemals in App 99 getippt werden — auch nicht, weil die JÜNGERE Verarbeitung dort gedrückt wurde")
    #expect(pasteboard.geschrieben == ["Erstes Diktat."],
            "der überholte Text darf nicht verloren gehen — er landet in der Zwischenablage")

    // Gegenprobe: Das ZWEITE Diktat gehört nach App 99, dort steht der Anwender — es wird direkt
    // eingefügt. Das belegt, dass die Zwischenablage oben nicht aus einem anderen Grund kam.
    client.freigeben(mit: .success(ergebnis("Zweites Diktat.")))
    await warteBis { coordinator.session == .idle }

    #expect(inserter.getippt == ["Zweites Diktat."],
            "das zweite Diktat gehört in App 99 — dort steht der Anwender, dort wird getippt")
    #expect(pasteboard.geschrieben == ["Erstes Diktat."], "sonst blieb sie unangetastet")

    await coordinator.stop()
}

// MARK: - M1 (Abschluss-Review M5, Minor): leerer Text ist kein Erfolg

@MainActor
@Test(.timeLimit(.minutes(1)))
func leererTextAusDerEngineWirdGemeldetUndNichtAlsErfolgVerkauft() async throws {
    // M1 (Abschluss-Review M5): Liefert die Engine einen LEEREN Text (der Anwender hat nichts
    // Verständliches gesagt; das Mikrofon nahm nur Rauschen auf, an dem das Stille-Gate nicht
    // anschlug), lief das bis M5 als `.eingefuegt` durch und endete auf `.idle` — der Anwender
    // sah damit exakt dasselbe wie nach einem GEGLÜCKTEN Diktat: nichts. Ohne Overlay und ohne
    // Ton ist das Menüsymbol seine einzige Rückmeldung; sie muss diesen Unterschied machen.
    //
    // Es geht dabei kein Text verloren (es gibt keinen) — deshalb bleibt die Zwischenablage
    // unangetastet, und es wird auch nichts getippt.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let coordinator = makeCoordinator(
        hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
        client: DictationClient(ergebnis: .success(ergebnis(""))),
        pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Nichts erkannt"),
            """
            leerer Text darf NICHT wie ein geglücktes Diktat aussehen (.idle) — der Anwender \
            hat keine andere Rückmeldung als das Menüsymbol
            """)
    #expect(inserter.getippt.isEmpty, "es gibt nichts zu tippen")
    #expect(pasteboard.geschrieben.isEmpty,
            "die Zwischenablage bleibt unangetastet — der alte Inhalt ist besser als Leere")

    await coordinator.stop()
}
