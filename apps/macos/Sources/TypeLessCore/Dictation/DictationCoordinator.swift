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
    /// Der Text ist fertig, konnte aber nicht sicher direkt eingefügt werden — er liegt in der
    /// Zwischenablage, ⌘V holt ihn.
    ///
    /// **Kein Fehler.** Alles hat funktioniert; nur eine der fünf Bedingungen fürs direkte
    /// Einfügen war nicht erfüllt (andere App im Vordergrund, **anderes Textfeld als beim
    /// Fn-Druck**, kein Textfeld im Fokus, Passwortfeld, oder TypeLess kann es nicht wissen —
    /// fehlende Bedienungshilfen bzw. aktives Secure Event Input). Ein eigener Fall und
    /// **nicht** `.failed`,
    /// weil das Menü sonst ein Warnzeichen zeigte, wo nichts schiefging — und weil der Anwender
    /// genau wissen soll, dass jetzt ⌘V dran ist.
    case inZwischenablage
    /// Der letzte Fehlschlag, im Klartext — sichtbar bis zum nächsten Diktat.
    case failed(String)
}

/// Führt Hotkey, Aufnahme, Engine und Zustellung zusammen.
///
/// Ablauf: Fn gedrückt → Aufnahme startet, `/preload` läuft nebenher an. Fn losgelassen →
/// Aufnahme stoppt, wird geprüft und (wenn brauchbar) an die Engine geschickt.
///
/// **Die oberste Regel von M5:** Der fertige Text wird **entweder** an der Cursorposition
/// eingefügt — **oder** er liegt in der Zwischenablage. Ein drittes Ergebnis gibt es nicht
/// (s. ``stelleZu(_:zielApp:zielFokus:target:inserter:pasteboard:)``).
///
/// **Verbindlich (Entscheidung des Anwenders):** kein Ton; ein Overlay zeigt den Verlauf.
/// Deshalb bleibt bei **jedem** Fehlschlag die Zwischenablage unangetastet — dann liefert ⌘V
/// wenigstens den alten Inhalt statt Leere. Und wurde direkt eingefügt, bleibt sie ebenfalls
/// unangetastet: „Diktieren und Kopieren dürfen sich nicht gegenseitig stören."
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var session: SessionState = .idle

    /// Was das Overlay gerade anzeigt (s. ``OverlayZustand``). Getrennt von ``session``: Das
    /// Overlay zeigt den Live-Pegel und den erkannten Text, die der ``SessionState`` nicht trägt,
    /// und einen kurzen „Eingefügt ✓"-Moment, den ``session`` zu `.idle` zusammenfasst.
    public private(set) var overlay: OverlayZustand = .aus

    private let hotkey: HotkeyMonitor
    private let recorder: AudioRecorder
    private let client: SidecarClient
    private let pasteboard: Pasteboard
    private let inserter: TextInserter
    private let target: InsertionTarget

    /// Die App, die beim Fn-Druck vorne war — das ZIEL dieses Diktats.
    ///
    /// Wird bei **jedem** `.pressed` neu gelesen und mit dem jeweiligen Diktat mitgereicht (s.
    /// `verarbeite`). Entscheidend ist, dass jede Verarbeitung ihren EIGENEN Wert prüft und nicht
    /// den der jüngsten: Zwischen Loslassen und fertigem Text vergehen ~6 s, in denen der
    /// Anwender längst woanders sein kann.
    private var zielAppBeimDruck: pid_t?

    /// Das Textfeld, in dem beim Fn-Druck der Cursor stand — das ZIEL dieses Diktats, genauer als
    /// die App allein.
    ///
    /// **Warum das nötig ist (Abschluss-Review M5):** Die Ziel-App allein reicht nicht. Der
    /// Anwender diktiert in ein Textfeld im Browser, drückt in den ~6 s Wartezeit ⌘L und steht in
    /// der Adressleiste: gleiche Prozesskennung, beschreibbares Textfeld, kein Passwortfeld — alle
    /// bisherigen Bedingungen erfüllt, und das Diktat landete in der Adressleiste. Dasselbe in Mail
    /// zwischen Rumpf und Betreff. Entscheidung des Anwenders: „Wenn ich diktiere, muss ich mit dem
    /// Cursor schon in irgendein Textfeld von irgendeiner Anwendung geklickt haben. Dort soll der
    /// Text dann eingefügt werden."
    ///
    /// Wird — genau wie ``zielAppBeimDruck`` — bei jedem `.pressed` neu gelesen und als **Wert**
    /// mit dem jeweiligen Diktat mitgereicht (s. `verarbeite`), nicht als Zustand geprüft: Jede
    /// Verarbeitung prüft IHR eigenes gemerktes Feld, nicht das der jüngsten (die gefallene
    /// M4-Regel, s. Kommentar bei `stelleZu`).
    ///
    /// **Bewusst akzeptierter Preis:** Manche Apps bauen ihre AX-Elemente im Hintergrund neu, ohne
    /// dass der Anwender etwas tut — dann weicht TypeLess gelegentlich unnötig auf die
    /// Zwischenablage aus, obwohl der Cursor gar nicht bewegt wurde. Das ist der harmlosere Fehler;
    /// der umgekehrte (Diktat in der Adressleiste) ist der ärgerlichere.
    private var fokusBeimDruck: Fokuskennung?

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

    /// Läuft, solange aufgenommen wird, und pollt ``AudioRecorder/aktuellerPegel()`` in
    /// ``pegelIntervall``-Abständen, um ``overlay`` mit dem echten Live-Pegel zu treiben (Task 3,
    /// Diktat-Overlay). `nil`, solange gerade nicht aufgenommen wird.
    private var pegelTask: Task<Void, Never>?
    /// ≈ 15 Hz per Default — schnell genug für flüssig wirkende Balken, ohne den Recorder-Actor
    /// im Übermaß zu bemühen. Injizierbar, damit Tests nicht auf echte 66 ms warten müssen.
    private let pegelIntervall: Duration

    /// Blendet einen gesetzten Endzustand (Task 4, Diktat-Overlay) nach der passenden Dauer
    /// wieder aus — s. `blendeAusNach(_:)`. `nil`, solange kein Ausblenden anliegt.
    private var ausblendTask: Task<Void, Never>?
    /// „Eingefügt ✓" — kurz, weil der Text ja schon sichtbar im Zielfeld steht.
    private let dauerEingefuegt: Duration
    /// Zwischenablage — länger, damit die Textvorschau lesbar bleibt.
    private let dauerZwischenablage: Duration
    /// Fehler — dazwischen: lang genug zum Lesen, kurz genug, um nicht zu nerven.
    private let dauerFehler: Duration

    public init(hotkey: HotkeyMonitor,
                recorder: AudioRecorder,
                client: SidecarClient,
                pasteboard: Pasteboard,
                inserter: TextInserter = CGEventTextInserter(),
                target: InsertionTarget = AXInsertionTarget(),
                minimumSampleCount: Int = 4_800,
                beendenZeitlimit: Duration = .seconds(10),
                beendenPollIntervall: Duration = .milliseconds(20),
                aufnahmeObergrenze: Duration = .seconds(120),
                keyDownCounter: KeyDownCounter = SystemKeyDownCounter(),
                pegelIntervall: Duration = .milliseconds(66),
                dauerEingefuegt: Duration = .seconds(1),
                dauerZwischenablage: Duration = .seconds(4),
                dauerFehler: Duration = .milliseconds(2500)) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.client = client
        self.pasteboard = pasteboard
        self.inserter = inserter
        self.target = target
        self.minimumSampleCount = minimumSampleCount
        self.beendenZeitlimit = beendenZeitlimit
        self.beendenPollIntervall = beendenPollIntervall
        self.aufnahmeObergrenze = aufnahmeObergrenze
        self.keyDownCounter = keyDownCounter
        self.pegelIntervall = pegelIntervall
        self.dauerEingefuegt = dauerEingefuegt
        self.dauerZwischenablage = dauerZwischenablage
        self.dauerFehler = dauerFehler
    }

    // MARK: - Lebenszyklus

    public func start() async {
        stopHotkey()

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
            //
            // N1 (Re-Review M4, Important): Die Unterscheidung „erwartet/unerwartet" hängt an der
            // IDENTITÄT DIESER TASK, nicht an einem Instanz-Flag. Ein Flag war nachweislich falsch:
            // `stopHotkey()` setzte es, `start()` setzte es unmittelbar danach (ohne jeden
            // Suspension-Punkt) wieder zurück und startete die neue Task — die ALTE Task lief erst
            // DANACH aus, sah das bereits zurückgesetzte Flag und meldete einen Hotkey-Ausfall,
            // obwohl der Hotkey einwandfrei lief. `stopHotkey()` cancelt die Task ohnehin: Genau
            // die abgelöste Task ist cancelled, die neue nicht — und eine wirklich gestorbene
            // ebenfalls nicht.
            guard let self, !Task.isCancelled else { return }
            self.session = .failed("Hotkey inaktiv — Eingabeüberwachung fehlt")
            self.overlay = .fehler("Hotkey inaktiv — Eingabeüberwachung fehlt")
            self.blendeAusNach(self.dauerFehler)
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
            stoppePegelPoll()
            _ = try? await recorder.stop()
        }

        // Laufende Verarbeitungen zu Ende bringen: Ein fertig gesprochenes Diktat wegzuwerfen
        // wäre das Schlimmste, was wir tun könnten — aber unbegrenzt zu warten wäre beim Beenden
        // der App genauso schlimm (Finding 4, Review zu Task 4, Minor s. Kommentar dort).
        await warteAufVerarbeitungenMitZeitlimit()
        verarbeitungen.removeAll()
        // Symmetrie zu `stoppePegelPoll()` oben: Ein noch laufender Ausblend-Timer eines
        // Endzustands darf nach dem Beenden des Koordinators nicht mehr feuern.
        ausblendTask?.cancel()
        session = .idle
        overlay = .aus
    }

    private func stopHotkey() {
        // Das `cancel()` ist zugleich die Markierung „dieses Streamende ist ERWARTET" — der
        // Schwanz der Task liest es über `Task.isCancelled` (N1, s. Kommentar in `start()`).
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
        stoppePegelPoll()
        _ = try? await recorder.stop()
        session = .failed("Aufnahme abgebrochen — Taste nicht losgelassen?")
        overlay = .fehler("Aufnahme abgebrochen — Taste nicht losgelassen?")
        blendeAusNach(dauerFehler)
    }

    // MARK: - Live-Pegel (Task 3, Diktat-Overlay)

    /// Aktualisiert den Live-Pegel im Overlay, solange aufgenommen wird. Schreibt AUSSCHLIESSLICH,
    /// wenn das Overlay noch `.hoertZu` ist — sonst hat die Verarbeitung schon übernommen, und ein
    /// nachlaufender Poll dürfte sie nicht überschreiben (Prüfung + Schreiben unmittelbar auf dem
    /// MainActor, ohne `await` dazwischen).
    private func startePegelPoll() {
        pegelTask?.cancel()
        pegelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pegel = await self.recorder.aktuellerPegel()
                guard !Task.isCancelled else { return }
                if case .hoertZu = self.overlay { self.overlay = .hoertZu(pegel: pegel) }
                try? await Task.sleep(for: self.pegelIntervall)
            }
        }
    }

    private func stoppePegelPoll() {
        pegelTask?.cancel()
        pegelTask = nil
    }

    // MARK: - Auto-Ausblenden der Endzustände (Task 4, Diktat-Overlay)

    /// Blendet das Overlay nach `dauer` aus — es sei denn, bis dahin hat ein neues Diktat den
    /// Zustand verändert (dann wurde dieser Task abgebrochen). Ein neues Diktat ruft beim Start
    /// `ausblendTask?.cancel()`.
    private func blendeAusNach(_ dauer: Duration) {
        ausblendTask?.cancel()
        ausblendTask = Task { [weak self] in
            try? await Task.sleep(for: dauer)
            guard let self, !Task.isCancelled else { return }
            self.overlay = .aus
        }
    }

    // MARK: - Tastendruck

    private func handlePressed() async {
        // I1 (Review M4, Important): Zählerstand so früh wie möglich lesen — so nah wie möglich
        // am tatsächlichen Tastendruck. Der Vergleich mit dem Stand beim Loslassen entscheidet
        // in `handleReleased()`, ob Fn als Modifier benutzt wurde (s. `KeyDownCounter`).
        zaehlerBeimDruck = keyDownCounter.aktuellerStand()

        // M5: Ziel-App UND Ziel-Textfeld so früh wie möglich merken — jetzt steht der Cursor noch
        // dort, wo der Anwender diktieren will. Beim Zustellen (in ~6 s) wird gegen BEIDES geprüft:
        // Die App allein unterscheidet nicht zwischen dem Textfeld einer Seite und der Adressleiste
        // desselben Browsers (s. `fokusBeimDruck`).
        // Electron-/Chromium-Apps bauen ihren AX-Baum erst auf Anforderung auf — sonst sieht die
        // Zustellung kein Feld und weicht auf die Zwischenablage aus. Die vorderste App JETZT
        // wecken (der App-Wechsel-Beobachter, s. BedienungshilfenAufwecker, tut das i. d. R. schon
        // vorher; dies deckt den Fall ab, dass die App beim TypeLess-Start bereits vorne war).
        let vorne = target.vordersteApp()
        if let vorne { target.weckeBedienungshilfen(fuer: vorne) }
        zielAppBeimDruck = vorne
        fokusBeimDruck = target.fokusKennung()

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
            stoppePegelPoll()
            _ = try? await recorder.stop()
        }

        do {
            try await recorder.start()
        } catch {
            // N2 (Re-Review M4, Minor): EINE Regel, für JEDEN Fehler von `start()` — verlässt
            // `handlePressed()` einen Fehlerpfad, ist das Mikrofon zu. Ohne diesen Stop war der
            // schlimmste Fall dauerhaft tödlich: Wirft `start()` ein `.alreadyRecording` (der
            // Recorder läuft in Wahrheit noch — C1-Zustand, den der Guard oben nicht sieht, weil
            // `session` nach einem früheren Fehlschlag eben NICHT `.recording` ist), lief das
            // Mikrofon weiter, der Watchdog wurde nie armiert (er startet erst unten), und der
            // nächste Druck lief in genau dasselbe `.alreadyRecording`: Mikrofon dauerhaft offen,
            // Diktat dauerhaft tot. Ein `stop()` auf einem gar nicht laufenden Recorder wirft
            // `.notRecording` und ist folgenlos (`try?`) — das ist der Preis dafür, dass diese
            // Regel keine Fallunterscheidung braucht. Der Zustandsautomat bleibt damit einfacher
            // als mit einem eigenen `catch`-Zweig nur für `.alreadyRecording`: Es gibt keinen
            // Fehlerausgang mehr, hinter dem noch ein offenes Mikrofon stehen könnte.
            _ = try? await recorder.stop()
            if let fehler = error as? AudioRecorderError, fehler == .microphoneDenied {
                session = .failed("Mikrofonzugriff verweigert")
                overlay = .fehler("Mikrofonzugriff verweigert")
            } else {
                session = .failed("Aufnahme nicht möglich: \(error)")
                overlay = .fehler("Aufnahme nicht möglich: \(error)")
            }
            blendeAusNach(dauerFehler)
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
        // Task 4 (Diktat-Overlay): Ein neues Diktat räumt einen noch laufenden Ausblend-Timer
        // eines VORHERIGEN Diktats sofort weg — sonst würde der alte Timer gleich darauf dieses
        // frische Overlay wieder auf `.aus` ziehen.
        ausblendTask?.cancel()
        overlay = .hoertZu(pegel: 0)
        startePegelPoll()
        starteAufnahmeWatchdog()
    }

    private func handleReleased() async {
        guard session == .recording else { return }
        beendeAufnahmeWatchdog()
        // Ab hier wird die Aufnahme in JEDEM Fall verlassen — entweder in Richtung `.processing`
        // (unten) oder in einen der Fehlerpfade weiter unten in dieser Funktion. Ein einziger Stopp
        // hier deckt beide Fälle ab: Der Poll darf nach dem Zuhören unter keinen Umständen
        // weiterlaufen (s. `startePegelPoll()`).
        stoppePegelPoll()

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
            overlay = .fehler("Aufnahme fehlgeschlagen: \(error)")
            blendeAusNach(dauerFehler)
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
            overlay = .aus
            return
        }

        let samples = recording.werte

        // Versehentliches Antippen: kommentarlos verwerfen. Kein Fehler, keine Anzeige.
        guard samples.count >= minimumSampleCount else {
            session = .idle
            overlay = .aus
            return
        }

        // `verloreneHaeppchen` zählt Mikrofon-Häppchen, deren Umrechnung fehlschlug und die
        // deshalb NICHT in `samples` stecken (s. ``AudioRecording``). Ohne diese Prüfung würde
        // ein Diktat still um Wörter kürzer — der Zähler existiert genau dafür, dass das nicht
        // mehr unbemerkt passiert. Deshalb geht so eine Aufnahme nicht mehr an die Engine,
        // sondern wird als Fehlschlag gemeldet wie jeder andere auch.
        guard recording.verloreneHaeppchen == 0 else {
            session = .failed("Teile der Aufnahme gingen verloren — bitte erneut versuchen")
            overlay = .fehler("Teile der Aufnahme gingen verloren — bitte erneut versuchen")
            blendeAusNach(dauerFehler)
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
            overlay = .fehler("Audiogerät hat gewechselt — bitte erneut versuchen")
            blendeAusNach(dauerFehler)
            return
        }

        // Der einzige Fehlerfall, den der Nutzer ohne Overlay und ohne Ton sonst erst beim
        // Einfügen bemerkt — nach 30 Sekunden Sprechen in ein stummes Mikrofon.
        guard !SilenceDetector.isSilent(samples) else {
            session = .failed("Kein Ton aufgenommen — Mikrofon prüfen")
            overlay = .fehler("Kein Ton aufgenommen — Mikrofon prüfen")
            blendeAusNach(dauerFehler)
            return
        }

        session = .processing
        overlay = .verarbeitet
        verarbeite(samples, zielApp: zielAppBeimDruck, zielFokus: fokusBeimDruck)
    }

    // MARK: - Verarbeitung

    /// Ergebnis einer Zustellung — was ist mit dem fertigen Text tatsächlich passiert?
    private enum Zustellung: Equatable {
        case eingefuegt
        /// Trägt den zugestellten Text mit — das Overlay zeigt davon eine gekürzte Vorschau
        /// (s. ``beendeVerarbeitung(id:zustellung:)``), die der ``SessionState`` nicht kennt.
        case inZwischenablage(text: String)
        /// Die Engine lieferte einen LEEREN Text (M1, Abschluss-Review M5): Der Anwender hat
        /// nichts Verständliches gesagt, oder das Mikrofon nahm nur Rauschen auf, aus dem das
        /// Stille-Gate nichts machen konnte. Es gibt nichts zuzustellen — aber es ist auch kein
        /// geglücktes Diktat.
        case nichtsErkannt
        case fehler(String)
    }

    private func verarbeite(_ samples: [Float], zielApp: pid_t?, zielFokus: Fokuskennung?) {
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        // Die Task über eine Kennung verwalten, nicht über sich selbst: Eine lokale Variable,
        // die ihre eigene Closure einfängt, ist unter strict concurrency nicht erlaubt.
        let id = UUID()
        // Diese Verarbeitung ist ab jetzt die jüngste — s. `beendeVerarbeitung` und Kommentar bei
        // `juengsteVerarbeitung` (Finding 3, Review zu Task 4).
        juengsteVerarbeitung = id

        // `pasteboard` — und seit M5 ebenso `inserter` und `target` — bewusst STARK gefangen,
        // `self` dagegen SCHWACH (Finding 4, Review zu Task 4, Minor — sonst leicht als Versehen
        // "korrigiert"): Der Koordinator kann verschwinden, während diese Verarbeitung noch läuft
        // — z. B. wenn `stop()` nach `beendenZeitlimit` aufgibt, ohne diese Task abzubrechen (s.
        // dort). Läuft der PROZESS danach weiter, stellt diese Task ihr Ergebnis trotzdem noch zu,
        // sobald sie fertig ist — dafür sind die starken Referenzen da. Alle drei sind Werkzeuge
        // der Zustellung und müssen die Task deshalb überleben; `zielApp` ist ein WERT und wird
        // ohnehin mitgereicht — genau das macht die neue M5-Regel aus: Jede Verarbeitung prüft
        // IHREN eigenen gemerkten Fokus, nicht den der jüngsten.
        //
        // Dasselbe gilt für `zielFokus` (Abschluss-Review M5): ebenfalls ein WERT, ebenfalls
        // mitgereicht — jede Verarbeitung prüft IHR gemerktes Textfeld, nicht das der jüngsten.
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
        let task = Task { [weak self, client, pasteboard, inserter, target] in
            do {
                let ergebnis = try await client.process(pcm: pcm, mode: .diktat, language: nil)

                // `refined: false` heißt: Das LLM ist ausgefallen, der Text ist trotzdem da.
                // Das ist KEIN Fehler (M2-Vertrag) — ein Diktat geht nie verloren. Das gilt auch
                // dann, wenn diese Verarbeitung längst nicht mehr die jüngste ist (Finding 3):
                // Der Text wird in JEDEM Fall zugestellt (eingefügt oder, wenn das nicht sicher
                // möglich ist, in die Zwischenablage gelegt) — nur `session` folgt ihm ggf. nicht
                // mehr (s. `beendeVerarbeitung`).
                let zustellung = Self.stelleZu(ergebnis.finalText, zielApp: zielApp,
                                               zielFokus: zielFokus,
                                               target: target, inserter: inserter,
                                               pasteboard: pasteboard)
                // Kein `await`: Diese Task übernimmt bei ihrer Erzeugung die MainActor-Isolation
                // von `verarbeite(_:zielApp:)` — wir sind hier bereits auf dem MainActor, der
                // Aufruf ist synchron (`beendeVerarbeitung` ist bewusst nicht `async`).
                self?.beendeVerarbeitung(id: id, zustellung: zustellung)
            } catch {
                // Echter Fehler (Engine weg, STT-Ausfall): Die Zwischenablage bleibt unangetastet
                // — der alte Inhalt ist besser als Leere.
                self?.beendeVerarbeitung(id: id, zustellung: .fehler(Self.beschreibe(error)))
            }
        }
        verarbeitungen[id] = task
    }

    /// Die fünf Bedingungen der Zustellung — **alle** müssen erfüllt sein, sonst Zwischenablage.
    ///
    /// Bewusst `static` und ohne `self`: Diese Entscheidung hängt AUSSCHLIESSLICH von den
    /// mitgereichten Werten ab (`zielApp` und `zielFokus` DIESES Diktats), nie vom aktuellen
    /// Zustand des Koordinators. Genau das ist die gefallene M4-Regel — ein überholtes Diktat darf
    /// nicht dorthin tippen, wo der Anwender INZWISCHEN steht.
    private static func stelleZu(_ text: String,
                                 zielApp: pid_t?,
                                 zielFokus: Fokuskennung?,
                                 target: InsertionTarget,
                                 inserter: TextInserter,
                                 pasteboard: Pasteboard) -> Zustellung {
        // Leerer Text (M1, Abschluss-Review M5): nichts zu tun, nichts anzufassen — aber auch
        // NICHT als Erfolg melden. Bis M5 lief das als `.eingefuegt` durch und endete auf `.idle`:
        // Der Anwender sah damit exakt dasselbe wie nach einem geglückten Diktat — nämlich nichts.
        // Ohne Overlay und ohne Ton ist das Menüsymbol seine einzige Rückmeldung; es muss den
        // Unterschied zwischen „ist eingefügt" und „da war nichts" machen können. Es geht dabei
        // kein Text verloren (es gibt keinen), und die Zwischenablage bleibt unangetastet.
        guard !text.isEmpty else { return .nichtsErkannt }

        // Bedingung 2: dieselbe App wie beim Fn-Druck.
        guard let zielApp, target.vordersteApp() == zielApp else {
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }

        // Bedingungen 1, 3 und 4: Recht vorhanden, beschreibbares Textfeld, kein Passwortfeld.
        // `.unbekannt` deckt BEIDE Fälle ab, in denen TypeLess nicht wissen kann, ob getippter
        // Text überhaupt ankäme: fehlende Bedienungshilfen UND aktives Secure Event Input
        // (C1, Review zu Task 4 — s. ``AXInsertionTarget/fokusziel()``, dort steht die
        // Begründung). Dann wird NICHT geraten: `CGEventPost` meldet nichts zurück
        // (s. ``TextInserter``), Getipptes verpuffte also wirkungslos, ohne dass es jemand
        // merkte, und das Diktat wäre spurlos weg — bei zufriedener Anzeige.
        //
        // Diese Vorab-Prüfung ist der einzige Schutz, den diese Ebene HAT — eine Bestätigung, dass
        // Getipptes angekommen ist, gibt es auf der CGEvent-Schnittstelle nicht (s. ``TextInserter``).
        // Sie deckt die bekannten Gründe fürs Verpuffen ab, nicht beweisbar alle: Pflicht, nicht Kür.
        guard target.fokusziel() == .beschreibbaresTextfeld else {
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }

        // Bedingung 5 (Abschluss-Review M5): dasselbe TEXTFELD wie beim Fn-Druck.
        //
        // Die App-Prüfung oben sieht nicht, was INNERHALB einer App passiert: ⌘L im Browser
        // (Adressleiste), Tab in Mail (Betreff) — gleiche Prozesskennung, beschreibbares Textfeld,
        // kein Passwortfeld. Alle vier bisherigen Bedingungen wären erfüllt, und das Diktat landete
        // in der Adressleiste. Also wird zusätzlich verglichen, ob der Cursor noch in DEM Feld
        // steht, in das der Anwender vor dem Sprechen geklickt hat.
        //
        // **Datenschutz:** Verglichen wird ausschließlich die IDENTITÄT des Elements
        // (``Fokuskennung``, undurchsichtig, nur `==`), niemals sein Inhalt — TypeLess erfährt nie,
        // was in dem Feld steht, in das es schreibt.
        //
        // `guard let zielFokus`: Ist beim Fn-Druck GAR KEINE Kennung gemerkt worden (kein Recht,
        // kein fokussiertes Element), wird nicht getippt. „Nichts gemerkt" ist kein Freibrief — die
        // Zwischenablage ist hier die sichere Antwort, nicht das Raten.
        //
        // **Bewusst akzeptierter Preis** (dem Anwender genannt, von ihm angenommen): Manche Apps
        // bauen ihre AX-Elemente im Hintergrund neu, ohne dass der Anwender etwas tut — dann weicht
        // TypeLess hier gelegentlich unnötig auf die Zwischenablage aus, obwohl der Cursor nie
        // bewegt wurde. Das ist der harmlosere Fehler; der umgekehrte (Diktat in der Adressleiste)
        // ist der ärgerlichere.
        guard let zielFokus, target.fokusKennung() == zielFokus else {
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }

        do {
            try inserter.insert(text)
            // Erfolg: Die Zwischenablage bleibt UNANGETASTET (Entscheidung des Anwenders).
            return .eingefuegt
        } catch {
            // Ein Diktat darf nie verloren gehen.
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }
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
    ///
    /// **Wichtig (M5):** Diese beiden Prüfungen betreffen ausschließlich die **Anzeige**. Über die
    /// **Zustellung** entscheiden sie nicht mehr — die ist längst passiert (s. `stelleZu`) und
    /// richtet sich nach dem Fokus, den DIESES Diktat sich gemerkt hat. Der Text kommt in jedem
    /// Fall an; nur die Zustandsanzeige folgt einer nicht mehr aktuellen Verarbeitung nicht mehr.
    private func beendeVerarbeitung(id: UUID, zustellung: Zustellung) {
        verarbeitungen[id] = nil
        guard id == juengsteVerarbeitung else { return }
        guard session == .processing else { return }
        switch zustellung {
        case .eingefuegt:
            session = .idle
            overlay = .eingefuegt
            blendeAusNach(dauerEingefuegt)
        case let .inZwischenablage(text):
            session = .inZwischenablage
            overlay = .zwischenablage(vorschau: overlayVorschau(text))
            blendeAusNach(dauerZwischenablage)
        case .nichtsErkannt:
            session = .failed("Nichts erkannt")
            overlay = .fehler("Nichts erkannt")
            blendeAusNach(dauerFehler)
        case let .fehler(grund):
            session = .failed(grund)
            overlay = .fehler(grund)
            blendeAusNach(dauerFehler)
        }
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
        // Seit der Hotkey sofort steht (s. `AppDelegate.applicationDidFinishLaunching`), ist das
        // ein Fall, den der Anwender im Alltag WIRKLICH sieht: kurz nach dem Programmstart Fn
        // gedrückt, während die Engine noch aufwärmt. Der Rohgrund des Servers („starting“) sagt
        // ihm nichts — hier gehört ein Satz hin, der erklärt, was zu tun ist.
        case .notReady: return "Engine wärmt noch auf — gleich nochmal versuchen"
        case let .processingFailed(grund): return grund
        case let .badRequest(grund): return grund
        case .malformedResponse: return "Unverständliche Antwort der Engine"
        }
    }
}
