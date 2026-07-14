import Foundation
import Observation

/// Der Zustand des Diktats — **getrennt** vom Zustand der Engine (``EngineState``).
///
/// Beides in einen Typ zu pressen wäre ein Fehler: Das ``/health``-Polling schreibt alle 5 s in
/// den Engine-Zustand und würde die Aufnahmeanzeige überschreiben.
public enum SessionState: Sendable, Equatable {
    case idle
    case recording
    case processing
    /// Der letzte Fehlschlag, im Klartext — sichtbar bis zum nächsten Diktat.
    case failed(String)
}

/// Führt Hotkey, Aufnahme, Engine und Zwischenablage zusammen.
///
/// Ablauf: Fn gedrückt → Aufnahme startet, `/preload` läuft nebenher an. Fn losgelassen →
/// Aufnahme stoppt, wird geprüft und (wenn brauchbar) an die Engine geschickt; das Ergebnis
/// landet in der Zwischenablage.
///
/// **Verbindlich (Entscheidung des Anwenders):** Es gibt kein Overlay und keine Tonsignale.
/// Deshalb bleibt bei **jedem** Fehlschlag die Zwischenablage unangetastet — dann liefert ⌘V
/// wenigstens den alten Inhalt statt Leere.
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var session: SessionState = .idle

    private let hotkey: HotkeyMonitor
    private let recorder: AudioRecorder
    private let client: SidecarClient
    private let pasteboard: Pasteboard

    /// 300 ms bei 16 kHz. Darunter war es ein versehentliches Antippen, kein Diktat.
    private let minimumSampleCount: Int

    private var hotkeyTask: Task<Void, Never>?
    /// Laufende Verarbeitungen. Der Nutzer darf sofort neu aufnehmen — die alte Verarbeitung
    /// läuft dann im Hintergrund weiter und schreibt ihr Ergebnis, wenn sie fertig ist.
    private var verarbeitungen: [UUID: Task<Void, Never>] = [:]
    /// Kennung der zuletzt gestarteten Verarbeitung (Finding 3, Review zu Task 4). Läuft mehr
    /// als eine Verarbeitung gleichzeitig — realistisch, wenn der Nutzer ungeduldig erneut
    /// drückt, weil er ohne Overlay und ohne Ton 3–6 s lang keinerlei Rückmeldung hat —, darf
    /// nur die JÜNGSTE davon `session` setzen (s. `beendeVerarbeitung`). Sonst könnte die
    /// zuerst fertige (ältere) den Zustand einer noch laufenden jüngeren überschreiben: Das
    /// Menüleisten-Symbol ist die einzige Rückmeldung dieser App und muss stimmen.
    private var juengsteVerarbeitung: UUID?

    /// Obergrenze für das Warten auf offene Verarbeitungen in `stop()` (Finding 4, Review zu
    /// Task 4, Minor). S. Kommentar bei `warteAufVerarbeitungenMitZeitlimit`.
    private let beendenZeitlimit: Duration
    private let beendenPollIntervall: Duration

    /// C1 (Review M4, Critical): Obergrenze für eine einzelne Aufnahme. Verliert der Koordinator
    /// ein `.released`-Ereignis (macOS schaltet den CGEventTap kurz ab, `FnKeyMonitor` macht ihn
    /// zwar selbst wieder scharf, aber das Ereignis IN diesem Fenster ist weg), bleibt `session`
    /// sonst für immer auf `.recording` hängen — es gibt ohne diesen Watchdog KEINEN Weg mehr
    /// zurück, außer der Nutzer drückt erneut (s. `handlePressed()`, verwaiste Aufnahme wird dann
    /// verworfen). 120 s sind großzügig genug für jedes echte Diktat, aber kurz genug, dass ein
    /// wirklich verlorenes `.released` nicht auf unbestimmte Zeit ein offenes Mikrofon bedeutet.
    private let aufnahmeObergrenze: Duration
    /// Wacht über die aktuell laufende Aufnahme — `nil`, solange nicht aufgenommen wird. Wird bei
    /// jedem Verlassen von `.recording` (regulär über `handleReleased()`, beim Verwerfen einer
    /// verwaisten Aufnahme in `handlePressed()` oder beim Beenden in `stop()`) sofort abgebrochen,
    /// s. `beendeAufnahmeWatchdog()`.
    private var aufnahmeWatchdog: Task<Void, Never>?

    /// I1 (Review M4, Important): reiner Tastendruck-Zähler, s. ``KeyDownCounter`` für die
    /// vollständige Begründung. Als Protokoll injiziert, damit Tests ihn ohne echte
    /// Tastendrücke steuern können.
    private let keyDownCounter: KeyDownCounter
    /// Zählerstand beim letzten `.pressed` — der Vergleich in `handleReleased()` entscheidet,
    /// ob der Nutzer zwischendurch eine Zeichentaste gedrückt hat (Fn als Modifier statt als
    /// Diktier-Taste).
    private var zaehlerBeimDruck: UInt32 = 0

    /// I3 (Review M4, Important): Unterscheidet ein ERWARTETES Streamende (`stopHotkey()` hat es
    /// selbst ausgelöst) von einem UNERWARTETEN (der Hotkey ist tot). Der reale `FnKeyMonitor`
    /// wirft bei fehlender Berechtigung „Eingabeüberwachung" NICHT synchron — der Fehler passiert
    /// auf dem Hotkey-Thread und endet dort nur in `continuation.finish()` (s. Kommentar dort).
    /// Ohne diese Unterscheidung sieht `start()` in beiden Fällen denselben normal endenden
    /// Stream und kann einen toten Hotkey nicht von einem absichtlich gestoppten unterscheiden.
    /// Läuft stets auf dem MainActor (wie der Rest des Koordinators) — kein Lock nötig.
    private var erwarteteHotkeyBeendigung = false

    public init(hotkey: HotkeyMonitor,
                recorder: AudioRecorder,
                client: SidecarClient,
                pasteboard: Pasteboard,
                minimumSampleCount: Int = 4_800,
                beendenZeitlimit: Duration = .seconds(10),
                beendenPollIntervall: Duration = .milliseconds(20),
                aufnahmeObergrenze: Duration = .seconds(120),
                keyDownCounter: KeyDownCounter = SystemKeyDownCounter()) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.client = client
        self.pasteboard = pasteboard
        self.minimumSampleCount = minimumSampleCount
        self.beendenZeitlimit = beendenZeitlimit
        self.beendenPollIntervall = beendenPollIntervall
        self.aufnahmeObergrenze = aufnahmeObergrenze
        self.keyDownCounter = keyDownCounter
    }

    // MARK: - Lebenszyklus

    public func start() async {
        stopHotkey()
        // Erst NACH `stopHotkey()` zurücksetzen — das setzt es (absichtlich) selbst auf `true`.
        erwarteteHotkeyBeendigung = false

        let stream = hotkey.start()
        hotkeyTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .pressed: await self.handlePressed()
                case .released: await self.handleReleased()
                }
            }
            // I3 (Review M4, Important): Der Stream ist zu Ende. `FnKeyMonitor.start()` wirft
            // real NIE synchron (s. `HotkeyMonitor`-Kommentar) — der einzige Fehlerfall (fehlende
            // Eingabeüberwachung, `CGEvent.tapCreate` liefert nil) endet HIER, als leerer Stream,
            // auf einem anderen Thread. Ohne diese Auswertung stünde im Menü „Bereit", obwohl der
            // Hotkey tot ist. Endet der Stream, OHNE dass `stopHotkey()` ihn absichtlich beendet
            // hat, ist der Hotkey tot — das deckt auch den Fall ab, dass er später (nach
            // erfolgreichem Start) unerwartet endet.
            guard let self, !self.erwarteteHotkeyBeendigung else { return }
            self.session = .failed("Hotkey inaktiv — Eingabeüberwachung fehlt")
        }
    }

    public func stop() async {
        // Referenz VOR `stopHotkey()` sichern, das `hotkeyTask` auf `nil` setzt — sonst gäbe es
        // unten nichts mehr, worauf sich warten ließe.
        let bisherigeHotkeyTask = hotkeyTask
        stopHotkey()

        // Auf das Ende der Hotkey-Task WARTEN, nicht nur `cancel()` rufen (Finding 1, Review zu
        // Task 4, Critical): `cancel()` ist rein kooperativ — es setzt nur ein Flag, unterbricht
        // aber keinen bereits hängenden `await` (z. B. `recorder.start()`, das gerade auf den
        // macOS-Berechtigungsdialog wartet). Kam dieses `stop()` genau in dem Fenster an, in dem
        // `handlePressed()` noch dort hing, war `session` zu diesem Zeitpunkt noch `.idle` — der
        // Guard unten griff also nicht, und `handlePressed()` lief NACH diesem `stop()` fertig
        // durch: aktivierte den Recorder und setzte `session` auf `.recording`. Niemand rief
        // danach je wieder `recorder.stop()` auf — das Mikrofon blieb für immer offen (belegt in
        // `stopWaehrendHandlePressedNochInRecorderStartHaengtSchliesstDasMikrofonTrotzdem`). Mit
        // diesem `await` ist ein bereits angestoßenes `handlePressed()`/`handleReleased()`
        // garantiert durchgelaufen, BEVOR unten geprüft wird, ob noch eine Aufnahme offen ist.
        //
        // Dieses Warten hat bewusst KEINE Obergrenze — anders als das auf die Verarbeitungen
        // weiter unten. Es kann nur in einem Fall überhaupt lange dauern: Der Nutzer beendet die
        // App, während der macOS-Mikrofondialog offen steht (nur beim allerersten Diktat). Dann
        // wartet das Beenden, bis er den Dialog beantwortet — unschön, aber deutlich harmloser
        // als die Alternative: ein Mikrofon, das nach dem Beenden weiterläuft.
        await bisherigeHotkeyTask?.value

        // Eine noch laufende Aufnahme darf hier nicht einfach ignoriert werden: Ohne dieses
        // `stop()` bliebe das Mikrofon nach dem Beenden des Koordinators für immer offen — es
        // kommt ja kein `.released`-Ereignis mehr an, das die Aufnahme regulär beenden würde
        // (derselbe Fehlerklasse wie das "Mikrofon endlos offen"-Finding aus Task 2). Das
        // Ergebnis wird bewusst verworfen: Wir beenden gerade den Koordinator, es gibt niemanden
        // mehr, der ein Diktat entgegennehmen würde.
        if session == .recording {
            beendeAufnahmeWatchdog()
            _ = try? await recorder.stop()
        }

        // Laufende Verarbeitungen zu Ende bringen: Ein fertig gesprochenes Diktat wegzuwerfen
        // wäre das Schlimmste, was wir tun könnten — aber unbegrenzt zu warten wäre beim Beenden
        // der App genauso schlimm (Finding 4, Review zu Task 4, Minor s. Kommentar dort).
        await warteAufVerarbeitungenMitZeitlimit()
        verarbeitungen.removeAll()
        session = .idle
    }

    private func stopHotkey() {
        // I3 (Review M4, Important): markiert das gleich folgende Streamende als ERWARTET —
        // s. Kommentar bei `erwarteteHotkeyBeendigung` und in `start()`.
        erwarteteHotkeyBeendigung = true
        hotkeyTask?.cancel()
        hotkeyTask = nil
        hotkey.stop()
    }

    // MARK: - Aufnahme-Watchdog (C1, Review M4, Critical)

    /// Startet den Watchdog für die gerade begonnene Aufnahme. `aufnahmeWatchdog?.cancel()`
    /// entwertet dabei automatisch einen eventuell noch übrig gebliebenen älteren Watchdog —
    /// es kann nie mehr als eine Aufnahme gleichzeitig geben (s. `handlePressed()`), also auch
    /// nie mehr als ein gültiger Watchdog.
    private func starteAufnahmeWatchdog() {
        aufnahmeWatchdog?.cancel()
        aufnahmeWatchdog = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.aufnahmeObergrenze)
            } catch {
                // Abgebrochen (`beendeAufnahmeWatchdog()`) — die Aufnahme wurde regulär beendet,
                // bevor die Obergrenze erreicht wurde. Nichts zu tun.
                return
            }
            await self.aufnahmeWegenUeberschreitungAbbrechen()
        }
    }

    /// Entwertet den Watchdog der gerade laufenden (oder gerade beendeten) Aufnahme. Muss bei
    /// JEDEM Verlassen von `.recording` aufgerufen werden — sonst würde ein längst überholter
    /// Watchdog später noch feuern (harmlos dank des Guards in
    /// `aufnahmeWegenUeberschreitungAbbrechen()`, aber unnötig).
    private func beendeAufnahmeWatchdog() {
        aufnahmeWatchdog?.cancel()
        aufnahmeWatchdog = nil
    }

    /// Feuert nach `aufnahmeObergrenze`, wenn niemand die Taste losgelassen hat — ohne diesen
    /// Watchdog gäbe es aus einem hängen gebliebenen `.recording` (s. `handlePressed()`) KEINEN
    /// Weg mehr zurück außer einem erneuten Tastendruck. `guard session == .recording` ist reine
    /// Verteidigung: Normalerweise ist der Watchdog längst über `beendeAufnahmeWatchdog()`
    /// abgebrochen, bevor er hier ankommt, sobald die Aufnahme regulär endet.
    private func aufnahmeWegenUeberschreitungAbbrechen() async {
        guard session == .recording else { return }
        _ = try? await recorder.stop()
        session = .failed("Aufnahme abgebrochen — Taste nicht losgelassen?")
    }

    // MARK: - Tastendruck

    private func handlePressed() async {
        // I1 (Review M4, Important): Zählerstand so früh wie möglich lesen — so nah wie möglich
        // am tatsächlichen Tastendruck. Der Vergleich mit dem Stand beim Loslassen entscheidet
        // in `handleReleased()`, ob Fn als Modifier benutzt wurde (s. `KeyDownCounter`).
        zaehlerBeimDruck = keyDownCounter.aktuellerStand()

        // C1 (Review M4, Critical): Verliert der Koordinator ein `.released` (macOS schaltet den
        // CGEventTap kurz ab — `FnKeyMonitor` macht ihn selbst wieder scharf, aber das Ereignis,
        // das GENAU in dieses Fenster fiel, ist unwiederbringlich weg), bleibt `session` auf
        // `.recording` hängen, während der Recorder TATSÄCHLICH noch aufnimmt. Ein erneuter
        // Tastendruck darf dann NICHT einfach `recorder.start()` aufrufen — das würde (ohne den
        // zusätzlichen Guard in `AVAudioEngineRecorder.start()`, s. dort) entweder still
        // fehlschlagen oder, schlimmer, dieselbe Aufnahme unbemerkt weiterlaufen lassen: Der
        // nächste `stop()` läge dann die GESAMTE Zwischenzeit (Telefonate, Raumgespräche) als
        // Diktat vor. Deshalb: eine verwaiste Aufnahme zuerst wegwerfen, dann sauber neu starten.
        if session == .recording {
            beendeAufnahmeWatchdog()
            _ = try? await recorder.stop()
        }

        do {
            try await recorder.start()
        } catch AudioRecorderError.microphoneDenied {
            session = .failed("Mikrofonzugriff verweigert")
            return
        } catch {
            session = .failed("Aufnahme nicht möglich: \(error)")
            return
        }

        // Hier steht bewusst KEINE `guard !Task.isCancelled`-Prüfung: Für die Garantie „nach
        // `stop()` läuft kein Mikrofon mehr" ist sie nicht nötig. Das `await` in `stop()` deckt
        // beide möglichen Verzahnungen ab — ob `handlePressed()` vor oder nach dem `cancel()`
        // zurückkehrt, `stop()` sieht in jedem Fall den endgültigen `session`-Wert, weil es
        // genau darauf wartet.

        // Beschleunigung, kein Muss: Das Sprachmodell lädt, während der Nutzer noch spricht.
        // Scheitert das, lädt `/process` notfalls selbst nach — ein Diktat darf daran nie
        // scheitern. Deshalb wird der Fehler bewusst verworfen.
        Task { [client] in try? await client.preload() }

        session = .recording
        starteAufnahmeWatchdog()
    }

    private func handleReleased() async {
        guard session == .recording else { return }
        beendeAufnahmeWatchdog()

        // I1 (Review M4, Important): Zählerstand beim Loslassen lesen, VOR `recorder.stop()` —
        // die Reihenfolge relativ zum `await` unten spielt keine Rolle (der Zähler zählt
        // Tastendrücke, nicht Zeit), aber so bleibt die Lesung so nah wie möglich am
        // tatsächlichen Loslassen.
        let zaehlerBeimLoslassen = keyDownCounter.aktuellerStand()

        let recording: AudioRecording
        do {
            recording = try await recorder.stop()
        } catch {
            session = .failed("Aufnahme fehlgeschlagen: \(error)")
            return
        }

        // I1 (Review M4, Important): Ist der Zähler seit dem Druck gestiegen, hat der Nutzer
        // mindestens eine Zeichentaste gedrückt, während Fn unten war — Fn+Pfeil, Fn+Entf, …:
        // Fn wurde als MODIFIER benutzt, nicht zum Diktieren. TypeLess nimmt dabei trotzdem auf
        // (der Tap ist reines `.listenOnly` und verschluckt nichts), aber der Mitschnitt ist nur
        // Rauschen/Tastaturklappern, aus dem Whisper halluziniert — bei einer Kombination, die
        // länger als die Mindestdauer gehalten wird (beim mehrfachen Drücken normal), greift
        // auch das Stille-Gate nicht (Raumrauschen/Tastaturklappern liegen über -50 dBFS).
        // Kommentarlos verwerfen: kein Fehler, die Zwischenablage bleibt unangetastet, die
        // Engine wird gar nicht erst bemüht.
        guard zaehlerBeimLoslassen == zaehlerBeimDruck else {
            session = .idle
            return
        }

        let samples = recording.werte

        // Versehentliches Antippen: kommentarlos verwerfen. Kein Fehler, keine Anzeige.
        guard samples.count >= minimumSampleCount else {
            session = .idle
            return
        }

        // `verloreneHaeppchen` zählt Mikrofon-Häppchen, deren Umrechnung fehlschlug und die
        // deshalb NICHT in `samples` stecken (s. ``AudioRecording``). Ohne diese Prüfung würde
        // ein Diktat still um Wörter kürzer — der Zähler existiert genau dafür, dass das nicht
        // mehr unbemerkt passiert. Deshalb geht so eine Aufnahme nicht mehr an die Engine,
        // sondern wird als Fehlschlag gemeldet wie jeder andere auch.
        guard recording.verloreneHaeppchen == 0 else {
            session = .failed("Teile der Aufnahme gingen verloren — bitte erneut versuchen")
            return
        }

        // I2 (Review M4, Important): AVAudioEngine stoppt sich bei einem Konfigurationswechsel
        // (AirPods verbinden sich, Bluetooth wackelt) WÄHREND der Aufnahme SELBST — ab da kommen
        // keine Puffer mehr, aber `stop()` liefert trotzdem brav, was bis dahin da war:
        // `verloreneHaeppchen == 0`, nicht stumm, über der Mindestdauer. Ohne diese Prüfung ginge
        // die HALBE Aufnahme unbemerkt an die Engine — der Nutzer hielte die Transkription für
        // schlecht, statt den Abbruch zu bemerken. Dieselbe Behandlung wie `verloreneHaeppchen`.
        guard !recording.geraeteWechsel else {
            session = .failed("Audiogerät hat gewechselt — bitte erneut versuchen")
            return
        }

        // Der einzige Fehlerfall, den der Nutzer ohne Overlay und ohne Ton sonst erst beim
        // Einfügen bemerkt — nach 30 Sekunden Sprechen in ein stummes Mikrofon.
        guard !SilenceDetector.isSilent(samples) else {
            session = .failed("Kein Ton aufgenommen — Mikrofon prüfen")
            return
        }

        session = .processing
        verarbeite(samples)
    }

    // MARK: - Verarbeitung

    private func verarbeite(_ samples: [Float]) {
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        // Die Task über eine Kennung verwalten, nicht über sich selbst: Eine lokale Variable,
        // die ihre eigene Closure einfängt, ist unter strict concurrency nicht erlaubt.
        let id = UUID()
        // Diese Verarbeitung ist ab jetzt die jüngste — s. `beendeVerarbeitung` und Kommentar bei
        // `juengsteVerarbeitung` (Finding 3, Review zu Task 4).
        juengsteVerarbeitung = id

        // `pasteboard` bewusst STARK gefangen, `self` dagegen SCHWACH (Finding 4, Review zu
        // Task 4, Minor — sonst leicht als Versehen "korrigiert"): Der Koordinator kann
        // verschwinden, während diese Verarbeitung noch läuft — z. B. wenn `stop()` nach
        // `beendenZeitlimit` aufgibt, ohne diese Task abzubrechen (s. dort). Läuft der PROZESS
        // danach weiter, schreibt diese Task ihr Ergebnis trotzdem noch in die Zwischenablage,
        // sobald sie fertig ist — dafür ist die starke Referenz da.
        //
        // Klargestellt (M4-Abschluss-Review, „Zusätzlich, klein"): Das ist KEINE Garantie fürs
        // Beenden der App selbst. `applicationShouldTerminate` (`TypeLessApp.swift`) ruft direkt
        // nach `dictation.stop()` `state.shutdown()` auf und lässt AppKit danach den Prozess
        // beenden — eine zu diesem Zeitpunkt noch offene Verarbeitung geht dann tatsächlich
        // verloren, das starke Fangen von `pasteboard` hin oder her (es gibt schlicht keinen
        // laufenden Prozess mehr, der noch etwas schreiben könnte). `beendenZeitlimit` erkauft
        // sich also nur, dass `stop()` nicht spürbar hängt — nicht, dass ein spätes Diktat noch
        // ankommt.
        //
        // `self` dagegen schwach: `session` hat ohne einen noch existierenden Koordinator keinen
        // Sinn mehr (niemand liest ihn mehr) — ihn stark zu fangen würde den Koordinator nur
        // künstlich am Leben halten. `client` bleibt ebenfalls stark, schon weil er für den
        // `await`-Aufruf unten gebraucht wird.
        let task = Task { [weak self, client, pasteboard] in
            do {
                let ergebnis = try await client.process(pcm: pcm, mode: .diktat, language: nil)

                // `refined: false` heißt: Das LLM ist ausgefallen, der Text ist trotzdem da.
                // Das ist KEIN Fehler (M2-Vertrag) — ein Diktat geht nie verloren. Das gilt auch
                // dann, wenn diese Verarbeitung längst nicht mehr die jüngste ist (Finding 3):
                // Der Text landet in JEDEM Fall in der Zwischenablage — nur `session` folgt ihm
                // ggf. nicht mehr (s. `beendeVerarbeitung`).
                pasteboard.write(ergebnis.finalText)
                // Kein `await`: Diese Task übernimmt bei ihrer Erzeugung die MainActor-Isolation
                // von `verarbeite(_:)` — wir sind hier bereits auf dem MainActor, der Aufruf ist
                // synchron (`beendeVerarbeitung` ist bewusst nicht `async`).
                self?.beendeVerarbeitung(id: id, fehler: nil)
            } catch {
                // Zwischenablage bleibt unangetastet: Der alte Inhalt ist besser als Leere.
                self?.beendeVerarbeitung(id: id, fehler: Self.beschreibe(error))
            }
        }
        verarbeitungen[id] = task
    }

    /// Setzt den Zustand nach einer Verarbeitung — aber **nur**, wenn sie erstens noch die
    /// JÜNGSTE ist (Finding 3, Review zu Task 4) und zweitens der Nutzer nicht inzwischen schon
    /// wieder aufnimmt. Beide Prüfungen sind unabhängig voneinander nötig:
    /// - Ohne die Kennungs-Prüfung könnte eine ältere, längst überholte Verarbeitung, die zufällig
    ///   VOR einer noch laufenden jüngeren fertig wird, deren Ergebnis vorwegnehmen — das Menü
    ///   zeigte dann z. B. den Fehler eines längst abgehakten Diktats, während das eigentliche
    ///   (jüngere) noch läuft, oder verschluckte umgekehrt einen echten späteren Fehlschlag, weil
    ///   der Zustand von der älteren schon auf `.idle` gesetzt wurde.
    /// - Ohne die `session == .processing`-Prüfung würde ein spät eintreffendes Ergebnis eine
    ///   inzwischen neu gestartete Aufnahme wegblenden (Regel 6).
    /// In beiden Fällen gilt unverändert: Die Zwischenablage bekommt das Ergebnis TROTZDEM (s.
    /// `verarbeite`) — nur die Zustandsanzeige folgt einer nicht mehr aktuellen Verarbeitung
    /// nicht mehr.
    private func beendeVerarbeitung(id: UUID, fehler: String?) {
        verarbeitungen[id] = nil
        guard id == juengsteVerarbeitung else { return }
        guard session == .processing else { return }
        session = fehler.map { .failed($0) } ?? .idle
    }

    /// Wartet auf alle offenen Verarbeitungen — aber höchstens bis `beendenZeitlimit` (Finding 4,
    /// Review zu Task 4, Minor). Ohne Obergrenze könnte das bis zum eigenen Timeout des Sidecars
    /// blockieren (180 s, s. `HTTPSidecarClient.processTimeout`) — macOS quittiert eine App, die
    /// sich beim Beenden nicht meldet, irgendwann mit „Beenden erzwingen". 10 s (Default) sind
    /// großzügig genug für ein normal antwortendes Diktat (laut M1-Messwerten typisch 3–6 s),
    /// aber kurz genug, dass Beenden nicht spürbar hängt.
    ///
    /// Gepollt statt auf `task.value` gewartet — gleiches Muster wie
    /// `SidecarLifecycle.waitUntilExited`, s. dort: Ein `Task<Void, Never>` respektiert keine
    /// Stornierung von außen (`.value` kehrt nicht vorzeitig zurück), ein `withTaskGroup` würde
    /// beim Verlassen seines Scopes deshalb trotzdem auf jede noch hängende Verarbeitung warten
    /// und die Obergrenze wirkungslos machen. Da nach dem Aufruf dieser Funktion garantiert keine
    /// neue Verarbeitung mehr hinzukommt (der Hotkey ist zu diesem Zeitpunkt in `stop()` schon
    /// beendet), kann `verarbeitungen` währenddessen nur noch kleiner werden — ein einfacher
    /// Blick auf `isEmpty` reicht.
    ///
    /// Läuft die Zeit ab, gibt NUR diese Wartefunktion auf — die Verarbeitungen selbst werden
    /// NICHT abgebrochen und laufen im Hintergrund weiter; LÄUFT DER PROZESS DANACH WEITER,
    /// landet ihr Ergebnis trotzdem noch in der Zwischenablage, sobald sie fertig sind (s.
    /// `verarbeite`, starkes Fangen von `pasteboard`).
    ///
    /// Klargestellt (M4-Abschluss-Review, „Zusätzlich, klein"): In DIESER App ist das keine
    /// Garantie, dass ein spätes Diktat noch ankommt — `applicationShouldTerminate`
    /// (`TypeLessApp.swift`) ruft direkt nach `dictation.stop()` `state.shutdown()` auf und lässt
    /// AppKit anschließend den Prozess beenden. Eine Verarbeitung, die zu diesem Zeitpunkt noch
    /// offen ist, geht dann tatsächlich verloren — es gibt keinen laufenden Prozess mehr, der sie
    /// noch zu Ende bringen könnte. Der einzige Zweck dieser Obergrenze ist, dass `stop()` selbst
    /// beim Beenden nicht spürbar hängt (Finding 4, Review zu Task 4, Minor) — nicht, ein fertig
    /// gesprochenes Diktat über das Ende des Prozesses hinweg zu retten.
    private func warteAufVerarbeitungenMitZeitlimit() async {
        guard !verarbeitungen.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: beendenZeitlimit)
        while !verarbeitungen.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: beendenPollIntervall)
        }
    }

    static func beschreibe(_ error: Error) -> String {
        guard let error = error as? SidecarError else { return "Unerwarteter Fehler: \(error)" }
        switch error {
        case .unreachable: return "Engine nicht erreichbar"
        case .timedOut: return "Die Engine antwortet gerade nicht"
        case let .notReady(grund): return grund
        case let .processingFailed(grund): return grund
        case let .badRequest(grund): return grund
        case .malformedResponse: return "Unverständliche Antwort der Engine"
        }
    }
}
