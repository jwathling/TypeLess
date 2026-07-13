import Foundation
import Testing
@testable import TypeLessCore

/// Attrappe: liefert vorgegebene Werte, ohne je ein Mikrofon anzufassen.
/// Wird von den Koordinator-Tests (Task 4) wiederverwendet.
actor FakeRecorder: AudioRecorder {
    private var samples: [Float]
    private var fehlerBeimStart: AudioRecorderError?
    private(set) var laeuft = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(samples: [Float] = [], fehlerBeimStart: AudioRecorderError? = nil) {
        self.samples = samples
        self.fehlerBeimStart = fehlerBeimStart
    }

    func setSamples(_ neue: [Float]) { samples = neue }

    func start() async throws {
        startCount += 1
        if let fehlerBeimStart { throw fehlerBeimStart }
        laeuft = true
    }

    func stop() async throws -> AudioRecording {
        stopCount += 1
        guard laeuft else { throw AudioRecorderError.notRecording }
        laeuft = false
        return AudioRecording(werte: samples)
    }
}

@Test func stopOhneStartScheitertSauber() async throws {
    let recorder = FakeRecorder()

    await #expect(throws: AudioRecorderError.notRecording) {
        _ = try await recorder.stop()
    }
}

@Test func liefertDieAufgenommenenWerte() async throws {
    let recorder = FakeRecorder(samples: [0.1, 0.2, 0.3])

    try await recorder.start()
    let ergebnis = try await recorder.stop()

    #expect(ergebnis.werte == [0.1, 0.2, 0.3])
    #expect(ergebnis.verloreneHaeppchen == 0)
    #expect(await recorder.startCount == 1)
    #expect(await recorder.stopCount == 1)
}

@Test func echterRecorderLaesstSichErzeugen() {
    // Mehr geht ohne Mikrofon-Berechtigung nicht — die Handprobe in Task 5 ist der echte Test.
    _ = AVAudioEngineRecorder()
}

// MARK: - Review-Finding 1: Actor-Reentrancy in start()

/// Steuerbare Mikrofon-Berechtigungsprüfung für Finding 1 (Review zu Task 2): hängt jeden
/// Aufruf in einer eigenen Continuation, bis der Test ihn über `release(mit:)` gezielt auflöst.
/// So lässt sich das exakte Reentrancy-Fenster aus `AVAudioEngineRecorder.start()`
/// deterministisch erzwingen, ohne echtes Mikrofon und ohne feste Wartezeiten — gleiches Muster
/// wie `GatedClient` in `AppStateTests`.
final class GatedPermissionCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Bool, Never>] = []
    private var calls = 0
    private var offen: Bool?

    /// Feuert, sobald ein Aufruf seine Continuation registriert hat.
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    /// Gesamtzahl aller je begonnenen Prüfungen — der eigentliche Beleg für Finding 1: Bleibt
    /// sie bei zwei gleichzeitigen `start()`-Aufrufen bei `1`, hat nur einer die Reservierung
    /// passiert.
    var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func pruefung() async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            lock.lock()
            calls += 1
            if let offen {
                // Tor steht offen: sofort beantworten, statt zu hängen (s. `oeffnen(mit:)`).
                lock.unlock()
                k.resume(returning: offen)
            } else {
                pending.append(k)
                lock.unlock()
            }
            startedContinuation.yield()
        }
    }

    /// Öffnet das Tor dauerhaft: löst alle wartenden Aufrufe auf und beantwortet **jeden
    /// weiteren** Aufruf sofort.
    ///
    /// Wichtig für die Aussagekraft des Tests: Ohne dieses dauerhafte Öffnen würde die kaputte
    /// (nicht reservierende) Fassung von `start()` den zweiten Aufruf für immer am Tor hängen
    /// lassen — der Test bliebe dann *hängen*, statt sauber rot zu werden (das `.timeLimit` von
    /// Swift Testing bricht eine in einer nie aufgelösten Continuation feststeckende Task nicht
    /// ab). Mit offenem Tor läuft der zweite Aufruf in jedem Fall zu Ende, und `totalCalls`
    /// belegt hinterher deterministisch, ob er die Prüfung überhaupt je erreicht hat.
    func oeffnen(mit ergebnis: Bool) {
        lock.lock()
        offen = ergebnis
        let wartende = pending
        pending = []
        lock.unlock()
        for k in wartende { k.resume(returning: ergebnis) }
    }
}

@Test(.timeLimit(.minutes(1)))
func gleichzeitigeStartAufrufeGreifenNurEinmalAufDieBerechtigungZu() async throws {
    // Finding 1 (Review zu Task 2): Zwischen Prüfung und Reservierung des Zustands in
    // `start()` darf kein Suspension-Punkt liegen — sonst könnte ein zweiter, überlappender
    // `start()`-Aufruf denselben obersten Guard passieren und am Ende zweimal
    // `installTap(onBus: 0, …)` auf demselben Bus aufrufen, was `AVAudioEngine` mit einem
    // Laufzeitabbruch quittiert. Das lässt sich nicht mit echter Hardware nachstellen (kein
    // Mikrofon im Testlauf) — deshalb hier die injizierte Berechtigungsprüfung: Sie ist genau
    // der `await`, der laut Finding das Reentrancy-Fenster öffnet, wenn man ihn vor der
    // Reservierung aufruft. Reagiert `start()` korrekt, kann trotz zweier gleichzeitiger
    // Aufrufe nur EINER je bei dieser Prüfung ankommen — der zweite kehrt beim obersten Guard
    // sofort zurück (bestehendes Verhalten für „läuft schon").
    let gate = GatedPermissionCheck()
    let recorder = AVAudioEngineRecorder(mikrofonPruefung: { await gate.pruefung() })

    var iterator = gate.started.makeAsyncIterator()

    let erster = Task { try await recorder.start() }
    _ = await iterator.next()
    // Ab hier hängt der erste Aufruf garantiert am Tor, und `zustand` ist garantiert `.startet`:
    // Die Reservierung in `start()` steht im Programmtext strikt VOR dem Aufruf von
    // `mikrofonPruefung()`, der gerade erst seine Continuation registriert hat — kein
    // Scheduling-Zufall, sondern reine Programmreihenfolge innerhalb desselben (bis hierhin
    // ununterbrochenen) Actor-Jobs. Genau in diesem Fenster setzt Finding 1 an.
    let zweiter = Task { try await recorder.start() }

    // Tor dauerhaft öffnen und bewusst VERWEIGERN: Damit kann kein Aufruf mehr hängen bleiben
    // (auch nicht der zweite in der kaputten Fassung — s. `oeffnen(mit:)`), und keiner läuft je
    // bis `installTap` weiter, das echte Hardware anfassen würde.
    gate.oeffnen(mit: false)

    await #expect(throws: AudioRecorderError.microphoneDenied) {
        try await erster.value
    }
    // Beide Tasks sind hier nachweislich durch — was der zweite Aufruf getan hat, steht damit
    // endgültig fest, ohne feste Wartezeit.
    try await zweiter.value

    #expect(
        gate.totalCalls == 1,
        """
        ein zweiter, überlappender start() darf die Berechtigungsprüfung nicht erneut erreichen \
        — sonst hätten beide Aufrufe den obersten Guard passiert und liefen beide bis \
        installTap(onBus: 0, …) auf demselben Bus weiter (Laufzeitabbruch)
        """
    )

    // Der Recorder muss nach einem gescheiterten start() wieder startbar sein (kein dauerhaft
    // in `.startet` verklemmter Zustand) — ein späterer Aufruf muss die Prüfung erneut erreichen.
    await #expect(throws: AudioRecorderError.microphoneDenied) {
        try await recorder.start()
    }
    #expect(gate.totalCalls == 2, "nach einem gescheiterten start() muss der Recorder wieder startbar sein")
}

// MARK: - Review-Finding 3: Umrechnungsfehler dürfen nicht stillschweigend verschwinden

@Test func sammlerZaehltWerteUndFehlerThreadsicherUnterEchterNebenlaeufigkeit() async {
    // Finding 3 (Review zu Task 2): `append`/`fehlerVermerken` müssen threadsicher sein, weil
    // der Audio-Callback auf einem eigenen Echtzeit-Thread parallel zum Actor läuft. `Sammler`
    // selbst braucht dafür keine echte Hardware — hier mit echter Nebenläufigkeit (mehrere
    // Tasks im kooperativen Thread-Pool) statt eines einzelnen sequenziellen Aufrufs geprüft,
    // damit der Lock tatsächlich etwas zu tun hat.
    let sammler = AVAudioEngineRecorder.Sammler()
    let durchlaeufe = 500

    await withTaskGroup(of: Void.self) { gruppe in
        for i in 0..<durchlaeufe {
            gruppe.addTask {
                if i.isMultiple(of: 2) {
                    sammler.append([Float(i)])
                } else {
                    sammler.fehlerVermerken()
                }
            }
        }
    }

    let (werte, haeppchenFehler) = sammler.leeren()
    #expect(werte.count == durchlaeufe / 2, "keine verlorenen oder doppelt gezählten Werte unter echter Nebenläufigkeit")
    #expect(haeppchenFehler == durchlaeufe / 2, "keine verlorenen oder doppelt gezählten Fehler unter echter Nebenläufigkeit")

    // `leeren()` setzt beide Zähler zurück — ein zweiter Aufruf muss leer sein.
    let (werteDanach, fehlerDanach) = sammler.leeren()
    #expect(werteDanach.isEmpty)
    #expect(fehlerDanach == 0)
}
