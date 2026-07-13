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
func makeCoordinator(hotkey: FakeHotkey, recorder: FakeRecorder,
                     client: DictationClient, pasteboard: SpyPasteboard) -> DictationCoordinator {
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
func erneutesDrueckenWaehrendDerVerarbeitungStartetSofortEineNeueAufnahme() async throws {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis("erstes")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)

    // Sobald die Verarbeitung läuft, drücken wir erneut.
    var iterator = client.processGestartet.makeAsyncIterator()
    _ = await iterator.next()
    hotkey.send(.pressed)

    await warteBis { coordinator.session == .recording }
    #expect(coordinator.session == .recording, "der Nutzer wird nie ausgebremst")
    #expect(await recorder.startCount == 2)

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
