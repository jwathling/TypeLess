import AVFoundation
import Foundation
import Testing
@testable import TypeLessCore

/// Attrappe: liefert vorgegebene Werte, ohne je ein Mikrofon anzufassen.
/// Wird von den Koordinator-Tests (Task 4) wiederverwendet.
actor FakeRecorder: AudioRecorder {
    private var samples: [Float]
    private var verloreneHaeppchen: Int
    private var geraeteWechsel: Bool
    private var fehlerBeimStart: AudioRecorderError?
    private(set) var laeuft = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(samples: [Float] = [], verloreneHaeppchen: Int = 0, geraeteWechsel: Bool = false,
         fehlerBeimStart: AudioRecorderError? = nil) {
        self.samples = samples
        self.verloreneHaeppchen = verloreneHaeppchen
        self.geraeteWechsel = geraeteWechsel
        self.fehlerBeimStart = fehlerBeimStart
    }

    func setSamples(_ neue: [Float]) { samples = neue }

    func start() async throws {
        startCount += 1
        // C1 (Review M4, Critical): Bildet denselben Vertrag nach, den `AVAudioEngineRecorder`
        // jetzt einhält (s. dort) — ein `start()`, während bereits aufgenommen wird, darf NICHT
        // still gelingen. Ohne diese Zeile könnte `DictationCoordinatorTests` einen fehlenden
        // Verwerfen-vor-Neustart-Fix in `DictationCoordinator.handlePressed()` nicht bemerken:
        // Die Attrappe würde den zweiten `start()` klaglos schlucken, obwohl real ein Datenleck
        // entstünde (s. `verwaisteAufnahmeWirdVorNeustartVerworfen`).
        guard !laeuft else { throw AudioRecorderError.alreadyRecording }
        if let fehlerBeimStart { throw fehlerBeimStart }
        laeuft = true
    }

    func stop() async throws -> AudioRecording {
        stopCount += 1
        guard laeuft else { throw AudioRecorderError.notRecording }
        laeuft = false
        return AudioRecording(werte: samples, verloreneHaeppchen: verloreneHaeppchen,
                              geraeteWechsel: geraeteWechsel)
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

    /// Löst nur die *aktuell* wartenden Aufrufe einmalig auf — anders als `oeffnen(mit:)` OHNE
    /// das Tor dauerhaft zu öffnen. Ein späterer, neuer Aufruf von `pruefung()` hängt danach
    /// wieder, bis er erneut aufgelöst wird. Damit lässt sich für aufeinanderfolgende
    /// `start()`-Versuche je ein anderes Ergebnis erzwingen (s.
    /// `stopWaehrendStartetBrichtDenStartvorgangAb`), ohne dass ein späterer Versuch aus
    /// Versehen echte Hardware anfasst, weil das Tor noch von einem früheren Versuch offen
    /// stünde.
    func loeseAktuelleAuf(mit ergebnis: Bool) {
        lock.lock()
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
    // endgültig fest, ohne feste Wartezeit. `try?` bewusst statt `try`: Bei einer Mutation soll
    // hier die sorgfältig formulierte `totalCalls == 1`-Diagnose unten sichtbar werden, nicht
    // ein technisches „Caught error: .microphoneDenied" aus diesem `await`.
    _ = try? await zweiter.value

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

// MARK: - Important-Finding (Review zu Task 2): stop() im Fenster .startet muss start() abbrechen

@Test(.timeLimit(.minutes(1)))
func stopWaehrendStartetBrichtDenStartvorgangAb() async throws {
    // Important-Finding (Review zu Task 2): Kommt `stop()` genau im Fenster `.startet` an (Tap
    // noch nicht installiert, Engine noch nicht gestartet), warf es bisher `.notRecording` —
    // und `start()` lief danach unbeirrt weiter: installierte den Tap und startete die Engine,
    // als sei nichts gewesen. Das Mikrofon blieb dadurch endlos offen (heißer
    // Aufnahmezustand); der nächste `start()` tat nichts mehr (Zustand ja schon `.laeuft`), und
    // der nächste `stop()` hätte die gesamte Zwischenzeit als Diktat ausgeliefert. Kein
    // exotischer Fall: Er trifft genau den allerersten Diktatversuch — der Nutzer lässt die
    // Taste los, während noch der macOS-Berechtigungsdialog hängt, und klickt erst danach
    // „Erlauben".
    //
    // Berechtigung wird hier bewusst ERTEILT (nicht verweigert wie im Reentrancy-Test oben):
    // Nur so lässt sich der eigentliche Fehler nachstellen — bei verweigerter Berechtigung
    // bricht schon der bestehende Guard davor ab, ganz ohne den hier geprüften Abbruch, und die
    // Mutationsprobe unten liefe dann nicht rot. Dass dabei in der KAPUTTEN Fassung echte
    // Hardware angefasst würde (s. Mutationsprobe im Bericht), ist hier hingenommen — in der
    // reparierten Fassung, die im Normalbetrieb läuft, bricht `start()` VOR jeder
    // Hardware-Berührung ab, das Gate wird dafür extra einmalig (nicht dauerhaft) aufgelöst.
    let gate = GatedPermissionCheck()
    let recorder = AVAudioEngineRecorder(mikrofonPruefung: { await gate.pruefung() })

    var iterator = gate.started.makeAsyncIterator()

    let erster = Task { try await recorder.start() }
    _ = await iterator.next()
    // Ab hier hängt `start()` garantiert am Tor, und `zustand` ist garantiert `.startet` —
    // gleiche Programmreihenfolge-Begründung wie im Reentrancy-Test oben: Die Reservierung
    // steht im Programmtext strikt vor dem Aufruf von `mikrofonPruefung()`.

    await #expect(throws: AudioRecorderError.notRecording) {
        _ = try await recorder.stop()
    }

    // Berechtigung jetzt nachträglich erteilen — genau der reale Ablauf ("...klickt erst danach
    // 'Erlauben'"). Einmalig aufgelöst (`loeseAktuelleAuf`, nicht `oeffnen`): Das Tor bleibt für
    // künftige Aufrufe geschlossen, ein zweiter Versuch unten hängt also erneut, statt
    // versehentlich ebenfalls auf echte Hardware durchzulaufen.
    gate.loeseAktuelleAuf(mit: true)

    // Der Startvorgang muss sauber abbrechen — NICHT als Erfolg durchlaufen (das wäre ein
    // offenes Mikrofon) und nicht mit einem anderen Fehler aus der Hardware-Initialisierung
    // scheitern (das wäre ein Hinweis, dass der Abbruch zu spät oder gar nicht geprüft wurde).
    // `.notRecording` ist dabei ausschließlich der Fehler des Abbruch-Guards direkt nach dem
    // Gate (s. `start()`) — jeder andere Fehlerwert würde belegen, dass die Ausführung daran
    // vorbeigelaufen und mindestens bis zur Formatverhandlung vorgedrungen ist.
    //
    // Bewusst KEIN `#expect(throws:)` hier, sondern manuelles do/catch mit sofortigem `return`
    // im Fehlerfall: Bleibt der Abbruch aus, ist der Recorder ab hier tatsächlich `.laeuft` (auf
    // echter Hardware) — ein zweiter `start()`-Versuch würde dann beim obersten Guard sofort
    // (und stillschweigend) zurückkehren, OHNE je wieder `mikrofonPruefung()` zu erreichen. Der
    // Wartepunkt `iterator.next()` unten bekäme dafür nie ein Signal und der Test bliebe bis zum
    // `.timeLimit` hängen — genau die Falle, vor der der Auftrag warnt. Der frühe `return` hält
    // den Test in diesem Fall schnell UND rot, statt hängend.
    do {
        try await erster.value
        Issue.record(
            """
            start() hätte nach dem Abbruch mit .notRecording scheitern müssen, lief aber \
            erfolgreich durch — das Mikrofon ist jetzt vermutlich offen (echte Hardware \
            angefasst). Breche hier ab, statt in die Restartbarkeits-Prüfung weiterzulaufen, \
            die sonst am nicht mehr erreichbaren Gate hängen bliebe.
            """
        )
        return
    } catch AudioRecorderError.notRecording {
        // Erwartet — weiter zur Restartbarkeits-Prüfung unten.
    } catch {
        Issue.record(
            "start() scheiterte nach dem Abbruch mit \(error) statt mit .notRecording — Abbruch griff nicht an der erwarteten Stelle"
        )
        return
    }

    // Wieder sauber startbar: Ein zweiter Versuch muss die Berechtigungsprüfung erneut
    // erreichen (`totalCalls` steigt) und darf NICHT sofort wieder mit `.notRecording`
    // scheitern — das würde einen liegen gebliebenen Abbruch-Zustand verraten
    // (`abbruchAngefordert` nicht zurückgesetzt). Berechtigung diesmal verweigern, damit auch
    // dieser zweite Versuch garantiert keine echte Hardware anfasst. Der obige frühe `return`
    // stellt sicher, dass wir nur hier ankommen, wenn der erste Abbruch nachweislich funktioniert
    // hat — `zustand` ist also garantiert `.gestoppt`, und dieser Wartepunkt kann nicht hängen.
    let zweiter = Task { try await recorder.start() }
    _ = await iterator.next()
    gate.loeseAktuelleAuf(mit: false)

    await #expect(throws: AudioRecorderError.microphoneDenied) {
        try await zweiter.value
    }
    #expect(
        gate.totalCalls == 2,
        "der Recorder muss nach dem Abbruch wieder normal startbar sein und die Prüfung erneut erreichen"
    )
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

// MARK: - I2 (Review M4, Important): Geräteumschwenk während der Aufnahme

@Test func geraeteWechselBeobachterErkenntEinenKonfigurationsWechsel() {
    // I2 (Review M4, Important): Denselben Mechanismus wie `AVAudioEngineRecorder.start()`/
    // `stop()` prüfen, OHNE echte Hardware zu brauchen — `AVAudioEngine()` lässt sich gefahrlos
    // konstruieren (s. `echterRecorderLaesstSichErzeugen` oben), der Notification-Name ist an
    // die OBJEKTIDENTITÄT gebunden, nicht an den Laufzustand. Die Engine hier wird NIE
    // gestartet — reine Objektidentität zum Scopen der Notification.
    let engine = AVAudioEngine()
    let beobachter = GeraeteWechselBeobachter()
    beobachter.beobachten(engine)

    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)

    #expect(beobachter.lesenUndZuruecksetzen() == true)
    #expect(beobachter.lesenUndZuruecksetzen() == false,
           "lesenUndZuruecksetzen() muss den Stand zurücksetzen — sonst würde eine künftige Aufnahme den Wechsel EINER VORHERIGEN erben")

    beobachter.nichtMehrBeobachten()
    // Nach nichtMehrBeobachten() darf eine weitere Notification den Beobachter nicht mehr
    // erreichen.
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    #expect(beobachter.lesenUndZuruecksetzen() == false)
}

@Test func geraeteWechselBeobachterIgnoriertNotificationsAndererEngines() {
    // Objektidentität muss echt scopen: Eine Notification einer ANDEREN Engine darf den
    // Beobachter nicht fälschlich auslösen.
    let beobachteteEngine = AVAudioEngine()
    let andereEngine = AVAudioEngine()
    let beobachter = GeraeteWechselBeobachter()
    beobachter.beobachten(beobachteteEngine)

    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: andereEngine)

    #expect(beobachter.lesenUndZuruecksetzen() == false)
    beobachter.nichtMehrBeobachten()
}
