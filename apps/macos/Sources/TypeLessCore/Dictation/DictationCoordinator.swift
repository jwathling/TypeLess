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

    public init(hotkey: HotkeyMonitor,
                recorder: AudioRecorder,
                client: SidecarClient,
                pasteboard: Pasteboard,
                minimumSampleCount: Int = 4_800,
                beendenZeitlimit: Duration = .seconds(10),
                beendenPollIntervall: Duration = .milliseconds(20)) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.client = client
        self.pasteboard = pasteboard
        self.minimumSampleCount = minimumSampleCount
        self.beendenZeitlimit = beendenZeitlimit
        self.beendenPollIntervall = beendenPollIntervall
    }

    // MARK: - Lebenszyklus

    public func start() async {
        stopHotkey()
        do {
            let stream = try hotkey.start()
            hotkeyTask = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case .pressed: await self.handlePressed()
                    case .released: await self.handleReleased()
                    }
                }
            }
        } catch {
            session = .failed("Hotkey inaktiv — Eingabeüberwachung fehlt")
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
        await bisherigeHotkeyTask?.value

        // Eine noch laufende Aufnahme darf hier nicht einfach ignoriert werden: Ohne dieses
        // `stop()` bliebe das Mikrofon nach dem Beenden des Koordinators für immer offen — es
        // kommt ja kein `.released`-Ereignis mehr an, das die Aufnahme regulär beenden würde
        // (derselbe Fehlerklasse wie das "Mikrofon endlos offen"-Finding aus Task 2). Das
        // Ergebnis wird bewusst verworfen: Wir beenden gerade den Koordinator, es gibt niemanden
        // mehr, der ein Diktat entgegennehmen würde.
        if session == .recording {
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
        hotkeyTask?.cancel()
        hotkeyTask = nil
        hotkey.stop()
    }

    // MARK: - Tastendruck

    private func handlePressed() async {
        do {
            try await recorder.start()
        } catch AudioRecorderError.microphoneDenied {
            session = .failed("Mikrofonzugriff verweigert")
            return
        } catch {
            session = .failed("Aufnahme nicht möglich: \(error)")
            return
        }

        // Geprüft und bewusst NICHT ergänzt (Finding 1, Review zu Task 4): eine zusätzliche
        // `guard !Task.isCancelled`-Prüfung hier, die den Recorder bei stornierter Hotkey-Task
        // sofort selbst wieder zumacht. Für die im Finding beschriebene Garantie — "nach
        // `stop()` läuft kein Mikrofon mehr" — ist sie NICHT nötig: Das `await` oben in `stop()`
        // deckt beide möglichen Verzahnungen bereits vollständig ab (ob `handlePressed()` VOR
        // oder NACH dem `cancel()` in `stopHotkey()` aus dem Gate zurückkehrt, `stop()` sieht in
        // jedem Fall den korrekten `session`-Wert, sobald es weiterläuft, weil es exakt darauf
        // wartet). Eine zusätzliche Prüfung hier würde sogar aktiv schaden: Sie schlösse den
        // Recorder unabhängig vom Fix in `stop()` und würde dadurch die Mutationsprobe zu diesem
        // Finding verdecken (Test bliebe grün, selbst wenn das `await` in `stop()` versehentlich
        // wieder entfernt würde). Ein echter Bedarf für eine Reaktion auf Stornierung bestünde
        // nur bei einem ganz anderen, hier nicht vorliegenden Ablauf — einem erneuten `start()`,
        // das eine noch hängende alte Hotkey-Task kommentarlos abschießt, ohne auf sie zu warten
        // (`stopHotkey()` in `start()`); das ist kein Teil dieses Findings und hier nicht
        // angefasst.

        // Beschleunigung, kein Muss: Das Sprachmodell lädt, während der Nutzer noch spricht.
        // Scheitert das, lädt `/process` notfalls selbst nach — ein Diktat darf daran nie
        // scheitern. Deshalb wird der Fehler bewusst verworfen.
        Task { [client] in try? await client.preload() }

        session = .recording
    }

    private func handleReleased() async {
        guard session == .recording else { return }

        let recording: AudioRecording
        do {
            recording = try await recorder.stop()
        } catch {
            session = .failed("Aufnahme fehlgeschlagen: \(error)")
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
        // verschwinden, während diese Verarbeitung noch läuft — spätestens beim Beenden der App,
        // wenn `stop()` nach `beendenZeitlimit` aufgibt, ohne diese Task abzubrechen (s. dort).
        // Das Diktat soll TROTZDEM ankommen — unverhandelbar: ein Diktat darf nie verloren gehen
        // —, deshalb muss `pasteboard` unabhängig vom Koordinator am Leben bleiben. `self`
        // dagegen schwach: `session` hat ohne einen noch existierenden Koordinator keinen Sinn
        // mehr (niemand liest ihn mehr) — ihn stark zu fangen würde den Koordinator nur künstlich
        // am Leben halten. `client` bleibt ebenfalls stark, schon weil er für den `await`-Aufruf
        // unten gebraucht wird.
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
    /// NICHT abgebrochen und laufen im Hintergrund weiter; ihr Ergebnis landet trotzdem noch in
    /// der Zwischenablage, sobald sie fertig sind (s. `verarbeite`, starkes Fangen von
    /// `pasteboard`). Ein fertig gesprochenes Diktat zu retten ist wichtig — aber nicht um den
    /// Preis, dass sich die App nicht mehr beenden lässt.
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
