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

    private let lifecycle: SidecarLifecycle
    private let client: SidecarClient
    private let permissionsService: PermissionsService
    private let pollIntervalStarting: Duration
    private let pollIntervalReady: Duration

    private var pollTask: Task<Void, Never>?

    public init(lifecycle: SidecarLifecycle,
                client: SidecarClient,
                permissions: PermissionsService,
                pollIntervalStarting: Duration = .seconds(1),
                pollIntervalReady: Duration = .seconds(5)) {
        self.lifecycle = lifecycle
        self.client = client
        permissionsService = permissions
        self.pollIntervalStarting = pollIntervalStarting
        self.pollIntervalReady = pollIntervalReady
        self.permissions = permissions.status()
    }

    // MARK: - Lebenszyklus

    public func start() async {
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
        await lifecycle.stop()
        engine = .stopped
    }

    public func refreshPermissions() {
        permissions = permissionsService.status()
    }

    public func openSettings(for permission: Permission) {
        permissionsService.openSettings(for: permission)
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
    /// Finding I1 (Review): Außerhalb der Tests wurde ``refreshPermissions()`` nie aufgerufen —
    /// `permissions` blieb für die gesamte Laufzeit auf dem Stand aus `init`. Erteilt der Nutzer
    /// ein fehlendes Recht in den Systemeinstellungen, blieb das Menü trotzdem dauerhaft bei ⚠
    /// stehen. Die drei Abfragen sind billig, deshalb hier im ohnehin laufenden Poll-Takt mit
    /// erledigen.
    private func pollOnce() async -> Duration {
        refreshPermissions()
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
