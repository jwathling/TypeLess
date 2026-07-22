import Foundation
import Observation

/// Zustand der Engine, wie ihn der Nutzer im Menü sieht.
public enum EngineState: Sendable, Equatable {
    case stopped
    /// Der Sidecar läuft, das STT-Modell lädt (~20 s).
    case starting
    case ready
    /// Mit Klartext-Grund — kein bloßes rotes Symbol.
    case failed(String)
}

/// Führt alles zusammen, was die Oberfläche wissen muss. Das **Einzige**, was die SwiftUI-
/// Schicht kennt — und der Vorläufer des ``RecordingCoordinator`` aus M4.
@MainActor
@Observable
public final class AppState {
    public private(set) var engine: EngineState = .stopped
    public private(set) var permissions: PermissionStatus
    /// UI-Zustand des Einrichtungs-Fensters (M8-Verteilung Teil 2b) — abgeleitet über eine
    /// eigene Poll-Achse (``startSetupPolling()``), NICHT mehr über den Engine-Poll (s. dort für
    /// die Begründung: der Engine-Poll läuft erst nach einem erfolgreichen ``lifecycle.start()``,
    /// das aber genau die Download-Phase blockiert, die dieses Fenster zeigen soll).
    public private(set) var setup: SetupState = .hidden

    private let lifecycle: SidecarLifecycle
    private let client: SidecarClient
    private let permissionsService: PermissionsService
    private let pollIntervalStarting: Duration
    private let pollIntervalReady: Duration
    private let permissionsInterval: Duration
    private let setupInterval: Duration

    private var pollTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?

    public init(lifecycle: SidecarLifecycle,
                client: SidecarClient,
                permissions: PermissionsService,
                pollIntervalStarting: Duration = .seconds(1),
                pollIntervalReady: Duration = .seconds(5),
                permissionsInterval: Duration = .seconds(2),
                setupInterval: Duration = .seconds(1)) {
        self.lifecycle = lifecycle
        self.client = client
        permissionsService = permissions
        self.pollIntervalStarting = pollIntervalStarting
        self.pollIntervalReady = pollIntervalReady
        self.permissionsInterval = permissionsInterval
        self.setupInterval = setupInterval
        self.permissions = permissions.status()
    }

    // MARK: - Lebenszyklus

    public func start() async {
        // M2 (Abschluss-Review M5): Die Rechte-Auffrischung läuft auf einer EIGENEN Achse — sie
        // beginnt vor `lifecycle.start()` und hängt an dessen Ausgang nicht. Bis M5 lief sie im
        // Engine-Poll mit, und der startet nur NACH einem erfolgreichen Start: Kam die Engine
        // nicht hoch (fehlendes Engine-Verzeichnis — ein getesteter Fall), wurde `permissions`
        // nie wieder gelesen. Erteilte der Anwender jetzt die Bedienungshilfen, blieb die
        // Warnung „Text landet in der Zwischenablage" für immer stehen, obwohl das Recht da war.
        //
        // Zwei getrennte Tasks statt einer gemeinsamen: Der Engine-Poll DARF nicht laufen, wenn
        // die Engine gar nicht steht (sein `health()` würde `engine` sofort von der klaren
        // Startfehler-Meldung — „Engine nicht gefunden: …" — auf ein nichtssagendes „Verbindung
        // zur Engine verloren" umschreiben). Die Rechte-Achse dagegen MUSS immer laufen. Zwei
        // Zwecke, zwei Lebensdauern, zwei Tasks — das hält beide Schleifen dumm und ohne jede
        // Fallunterscheidung. Es ist dieselbe Trennung wie zwischen `EngineState` und
        // `SessionState`.
        //
        // Bewusst SYNCHRON (kein `await`) — nachgemessen, nicht vermutet: Eine zusätzliche
        // Aufhängestelle HIER, vor `stopPolling()`, verschiebt die Reihenfolge, in der die alte
        // Poll-Task und dieses `start()` nach einem doppelten Start wieder auf den MainActor
        // kommen. Der Test `doppelterStartUeberlagertKeinePollTasks` lief damit in genau den
        // Zustand, den er bewacht: Die alte Poll-Task kam vor dem `cancel()` noch zu einem
        // weiteren `health()`-Aufruf, blieb in dessen (nicht stornierbarer) Continuation hängen,
        // und `stopPolling()` wartete für immer auf sie. Die Rechte-Achse hat mit dieser
        // Reihenfolge nichts zu tun und darf sie deshalb auch nicht anfassen.
        startPermissionsPolling()

        // Task 5 (Handprobe-Befund zu M8-Verteilung Teil 2b): analog zur Rechte-Achse eine
        // EIGENE Poll-Achse für den Erststart-Fortschritt, ebenfalls VOR `lifecycle.start()`
        // gestartet — s. ausführliche Begründung bei ``startSetupPolling()``.
        startSetupPolling()

        engine = .starting
        do {
            _ = try await lifecycle.start()
            engine = .ready
            await startPolling()
        } catch let error as LifecycleError {
            engine = .failed(Self.beschreibe(error))
        } catch {
            engine = .failed("Unerwarteter Fehler: \(error)")
        }
    }

    public func restart() async {
        await stopPolling()
        await lifecycle.stop()
        await start()
    }

    public func shutdown() async {
        await stopPolling()
        await stopPermissionsPolling()
        await stopSetupPolling()
        await lifecycle.stop()
        engine = .stopped
    }

    public func refreshPermissions() {
        permissions = permissionsService.status()
    }

    public func openSettings(for permission: Permission) {
        permissionsService.openSettings(for: permission)
    }

    /// „Erneut versuchen" aus dem Einrichtungs-Fenster: stößt den Modell-Bootstrap erneut an. Der
    /// Fortschritt/Erfolg kommt über den normalen Poll (``setup``) zurück, deshalb hier nur anstoßen.
    public func retryModelDownload() async {
        try? await client.ensureModels()
    }

    /// Fordert die Eingabeüberwachung an und aktualisiert sofort die Anzeige — beim Programmstart
    /// aufzurufen. Ohne diesen Aufruf bleibt der globale Hotkey stumm, ohne dass irgendetwas
    /// darauf hindeutet (ausführliche Begründung bei ``PermissionsService/requestInputMonitoring()``).
    public func requestInputMonitoring() {
        permissionsService.requestInputMonitoring()
        refreshPermissions()
    }

    /// Der Hotkey kann ohne Eingabeüberwachung nicht im Hintergrund wirken — dann darf das Menü
    /// **nicht** „Bereit" behaupten (das tat es und schickte den Anwender auf die Suche nach einem
    /// Fehler, den es im Code gar nicht gab).
    public var hotkeyBrauchtEingabeueberwachung: Bool {
        !permissions.inputMonitoring
    }

    /// Fordert die Bedienungshilfen an und aktualisiert sofort die Anzeige — beim Programmstart
    /// aufzurufen. Ohne dieses Recht kann TypeLess nie direkt einfügen; es fällt dann immer auf
    /// die Zwischenablage zurück (ausführliche Begründung bei
    /// ``PermissionsService/requestAccessibility()``).
    public func requestAccessibility() {
        permissionsService.requestAccessibility()
        refreshPermissions()
    }

    /// Ohne Bedienungshilfen kann TypeLess Text nie direkt einfügen — es landet dann IMMER in der
    /// Zwischenablage. Die App bleibt voll benutzbar, aber sie darf nicht so tun, als sei alles
    /// in Ordnung (Lektion M4: „Bereit", während der Hotkey tot war).
    public var einfuegenBrauchtBedienungshilfen: Bool {
        !permissions.accessibility
    }

    // MARK: - Rechte-Auffrischung (M2, Abschluss-Review M5)

    /// Liest die Berechtigungen im festen Takt neu — **unabhängig davon, ob die Engine läuft**.
    ///
    /// Ein Recht kann jederzeit dazukommen (der Anwender legt den Schalter in den
    /// Systemeinstellungen um) oder wegfallen. Die Anzeige darf nie stehen bleiben: Genau diese
    /// Fehlerklasse („veraltete Rechteanzeige") war in M3 schon einmal behoben, und M5 hat mit
    /// der Bedienungshilfen-Warnung eine neue Anzeige an dieselbe (kaputte) Leitung gehängt.
    /// Die drei Abfragen sind billig — ein eigener, langsamer Takt ist bezahlbar.
    ///
    /// Bricht eine eventuell noch laufende Vorgänger-Task ab, ohne auf deren Ende zu **warten**
    /// (anders als ``stopPolling()``, s. Kommentar in ``start()``). Das ist hier ungefährlich:
    /// Das Schlimmste, was eine abgelöste Rechte-Task noch tun kann, ist ein weiteres
    /// ``refreshPermissions()`` — sie schreibt also bestenfalls denselben, schlimmstenfalls den
    /// AKTUELLEN Rechtestand. Es gibt keinen Zustand, den sie überschreiben und damit verfälschen
    /// könnte (beim Engine-Poll ist das anders: Dessen später Schreibzugriff würde ein
    /// `engine = .stopped` aus ``shutdown()`` wieder aufheben).
    private func startPermissionsPolling() {
        permissionsTask?.cancel()
        permissionsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshPermissions()
                try? await Task.sleep(for: self.permissionsInterval)
            }
        }
    }

    /// Beim **Beenden** wird sehr wohl auf das Ende der Task gewartet: Danach soll wirklich nichts
    /// mehr laufen, was auf `self` zugreift — dieselbe Sorgfalt wie bei ``stopPolling()``, nur
    /// ohne dessen Zustands-Argument (s. ``startPermissionsPolling()``).
    private func stopPermissionsPolling() async {
        permissionsTask?.cancel()
        await permissionsTask?.value
        permissionsTask = nil
    }

    // MARK: - Erststart-Fortschritt (Task 5, Fix zu M8-Verteilung Teil 2b)

    /// Eigene Achse für den Erststart-Fortschritt — läuft **unabhängig** vom Engine-Poll und schon
    /// **während** ``lifecycle.start()`` (das die gesamte Download-Phase in ``waitForReady()``
    /// blockiert). Nur so kann das Einrichtungs-Fenster während des Modell-Downloads erscheinen.
    ///
    /// Eine **Handprobe** hat aufgedeckt, dass das Fenster im realen Ablauf nie erscheinen konnte:
    /// `setup` wurde bis hierher nur im Engine-Poll gesetzt, und der startet erst NACH einem
    /// erfolgreichen `lifecycle.start()` — genau der Aufruf, der bei `DefaultSidecarLifecycle` die
    /// gesamte Download-Phase blockiert (`waitForReady()` wertet nur `status`, nicht `models`,
    /// aus). Kam `lifecycle.start()` zurück, war der Download längst fertig und `models.state`
    /// bereits `"ready"` → `.hidden`. Strukturell konnte das Fenster nie sichtbar werden.
    ///
    /// Setzt ausschließlich ``setup`` (ein Schreiber — der Engine-Poll fasst `setup` seither nicht
    /// mehr an, s. ``pollOnce()``); ein fehlgeschlagenes ``health()`` (Engine kommt gerade erst
    /// hoch, der Socket existiert noch nicht) lässt ``setup`` unangetastet (bleibt ``.hidden`` →
    /// kein Fenster), analog zur toleranten Rechte-Achse.
    ///
    /// **Erst schlafen, dann fragen** (anders als die Rechte-Achse, die sofort liest): Direkt nach
    /// dem Start existiert der Sidecar-Socket in der Regel noch gar nicht — ein sofortiger
    /// `health()` liefe nur ins Leere. Der kleine Anfangsversatz (``setupInterval``, in der
    /// Produktion 1 s) ist unkritisch, der Download dauert Sekunden. Die Reihenfolge hat zudem eine
    /// harte Test-Konsequenz: Nach einem `cancel()` (aus ``stopSetupPolling()``) darf die Achse
    /// **keinen weiteren** `health()`-Aufruf mehr absetzen — sonst bliebe sie an einem
    /// test-seitig gegateten `health()` hängen und ``stopSetupPolling()`` (das auf `value` wartet)
    /// verklemmte. Deshalb nach dem Schlaf **vor** dem Aufruf noch einmal auf Abbruch prüfen.
    private func startSetupPolling() {
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.setupInterval)
                if Task.isCancelled { return }
                if let health = try? await self.client.health() {
                    self.setup = SetupState(models: health.models)
                }
            }
        }
    }

    /// Beim **Beenden** wird auf das Ende der Task gewartet — dieselbe Sorgfalt wie bei
    /// ``stopPermissionsPolling()`` (s. dort für die Begründung, warum das bei ``stopPolling()``
    /// sogar noch strenger sein muss, hier aber wie bei der Rechte-Achse ungefährlich ist).
    private func stopSetupPolling() async {
        setupTask?.cancel()
        await setupTask?.value
        setupTask = nil
    }

    // MARK: - Polling

    /// Fragt den Sidecar regelmäßig, wie es ihm geht — damit ein Wegsterben auffällt.
    private func startPolling() async {
        await stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Bricht die Poll-Task ab **und wartet, bis sie tatsächlich beendet ist** — nicht nur
    /// markiert. Ein bloßes `cancel()` lässt eine gerade laufende Anfrage noch zu Ende laufen;
    /// ohne dieses Warten könnte ihr letzter `engine`-Schreibzugriff erst *nach* dem
    /// `engine = .stopped` in ``shutdown()`` bzw. dem neuen Start in ``restart()`` eintreffen und
    /// den Zustand wieder überschreiben. Da alles auf dem `MainActor` läuft, macht das Warten
    /// auf `pollTask?.value` diese Reihenfolge deterministisch.
    private func stopPolling() async {
        pollTask?.cancel()
        await pollTask?.value
        pollTask = nil
    }

    /// Ein Poll-Durchgang. Liefert das Intervall bis zum nächsten.
    ///
    /// Kümmert sich **ausschließlich** um die Engine. Die Rechte-Auffrischung lief bis M5 hier
    /// mit (Finding I1, Review M3) — sie ist seit M2 (Abschluss-Review M5) auf eine eigene Task
    /// gezogen, weil diese hier nur nach einem ERFOLGREICHEN Engine-Start läuft; s.
    /// ``startPermissionsPolling()``. Aus demselben Grund (Task 5) setzt dieser Poll seit der
    /// eigenen setup-Achse auch ``setup`` nicht mehr — s. ``startSetupPolling()``.
    private func pollOnce() async -> Duration {
        do {
            let health = try await client.health()
            switch health.status {
            case "ready":
                engine = .ready
                return pollIntervalReady
            case "starting":
                engine = .starting
                return pollIntervalStarting
            default:
                engine = .failed(health.error ?? "Engine meldet einen unbekannten Fehler")
                return pollIntervalReady
            }
        } catch SidecarError.timedOut {
            // Die Verbindung stand, nur die Antwort blieb aus — der Sidecar verarbeitet laut M2
            // serialisiert gerade etwas anderes. Das ist kein Absturz: Zustand bewusst NICHT auf
            // `failed` kippen, einfach im bisherigen Takt weiterfragen.
            return currentPollInterval()
        } catch let error as SidecarError {
            engine = .failed(Self.beschreibe(error))
            return pollIntervalReady
        } catch is CancellationError {
            // Abbruch durch shutdown()/restart() — kein Fehlerzustand.
            return pollIntervalReady
        } catch {
            engine = .failed("Unerwarteter Fehler: \(error)")
            return pollIntervalReady
        }
    }

    /// Takt für einen erneuten Versuch, ohne den aktuellen Zustand zu verändern — passend zur
    /// Regel, dass ein Timeout allein den Zustand nicht kippen darf.
    private func currentPollInterval() -> Duration {
        if case .starting = engine {
            return pollIntervalStarting
        }
        return pollIntervalReady
    }

    // MARK: - Fehlertexte

    /// Übersetzt die technischen Fehler aus dem Lifecycle in etwas, das im Menü stehen kann.
    static func beschreibe(_ error: LifecycleError) -> String {
        switch error {
        case let .engineDirectoryMissing(path):
            "Engine nicht gefunden: \(path)"
        case let .uvMissing(path):
            "uv nicht gefunden: \(path)"
        case .readyTimeout:
            "Zeitüberschreitung beim Start der Engine"
        case let .failed(reason):
            reason        // Klartext aus der Engine (M2) — nicht überschreiben.
        }
    }

    /// Übersetzt Fehler aus dem laufenden Betrieb (Polling). ``timedOut`` läuft nie hier ein —
    /// der Aufrufer behandelt ihn vorher gesondert (siehe ``pollOnce()``).
    static func beschreibe(_ error: SidecarError) -> String {
        switch error {
        case .unreachable:
            "Verbindung zur Engine verloren"
        case .timedOut:
            "Die Engine antwortet gerade nicht (beschäftigt)"
        case let .notReady(reason):
            reason        // Klartext aus der Engine (M2) — nicht überschreiben.
        case let .processingFailed(reason):
            reason
        case let .badRequest(reason):
            reason
        case .malformedResponse:
            "Unerwartete Antwort der Engine"
        }
    }
}
