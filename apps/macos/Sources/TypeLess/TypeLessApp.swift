import AppKit
import Observation
import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    // Startet/beendet Engine und Diktat — s. AppDelegate weiter unten für die Begründung, warum
    // das nicht über den `.task`-Modifier auf der Szene läuft.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState
    @State private var dictation: DictationCoordinator
    // Hält Sparkle am Leben. Instanziierung hier lädt das eingebettete Framework beim Start —
    // der eigentliche Einbettungs-Beweis dieses Tasks.
    @State private var updater = UpdaterController()

    init() {
        // Die einzige Stelle, die konkrete Typen kennt (Komposition).
        let settings = UserDefaultsSettingsStore()
        let client = HTTPSidecarClient(socketPath: settings.socketPath)

        // Application-Support-Wurzel für Laufzeit-Umgebung, uv-Cache und Modelle. Beschreibbar,
        // liegt außerhalb des (read-only, signierten) Bündels und überlebt App-Updates.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeLess", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // Liegt eine gebündelte Engine vor? (nur dann läuft die App „ausgeliefert").
        let bundledEngineDir = Bundle.main.resourceURL?
            .appendingPathComponent("engine", isDirectory: true).path
        let bundledUv = bundledEngineDir.map { $0 + "/uv" }
        let isBundled = bundledUv.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false

        let launch = EngineLaunch.resolve(
            bundledEngineDirectory: isBundled ? bundledEngineDir : nil,
            uvPath: settings.uvPath,
            engineDirectory: settings.engineDirectory,
            socketPath: settings.socketPath,
            appSupportDirectory: appSupport.path)

        let lifecycle = DefaultSidecarLifecycle(
            client: client, runner: FoundationProcessRunner(),
            launch: launch,
            // Erster gebündelter Kaltstart baut die ~1,3-GB-Python-Umgebung auf (uv sync) und lädt
            // danach das STT-Modell — das dauert je nach Netz mehrere Minuten. Der Default von 90 s
            // würde diesen Aufbau abbrechen. Das SICHTBARE Erststart-Erlebnis (Fortschritt, sauberer
            // Abbruch bei fehlendem Netz) kommt in Teil 2; hier zählt nur, dass der Aufbau nicht
            // fälschlich abgewürgt wird.
            readyTimeout: isBundled ? .seconds(900) : .seconds(90))

        let state = AppState(lifecycle: lifecycle, client: client,
                             permissions: SystemPermissionsService())
        let dictation = DictationCoordinator(
            hotkey: FnKeyMonitor(),
            recorder: AVAudioEngineRecorder(),
            client: client,
            pasteboard: SystemPasteboard(),
            inserter: CGEventTextInserter(),
            target: AXInsertionTarget())

        _state = State(wrappedValue: state)
        _dictation = State(wrappedValue: dictation)
        appDelegate.state = state
        appDelegate.dictation = dictation
    }

    var body: some Scene {
        // Das einmalige Einrichtungs-Fenster (M8-Verteilung Teil 2b) ist bewusst KEINE
        // SwiftUI-`Window`-Szene mehr (Task 7, Fix nach finalem Review): SwiftUI wertet den Body
        // einer geschlossenen `Window`-Szene nicht aus, ein `.onChange` darin öffnet also nie
        // deterministisch. Stattdessen treibt `AppDelegate.beobachteSetup()` ein direkt
        // verwaltetes `NSWindow` mit `SetupWindow` als Inhalt — s. dort.
        MenuBarExtra {
            MenuContent(state: state, dictation: dictation, checkForUpdates: updater.checkForUpdates)
        } label: {
            Image(systemName: symbol)
        }
        .menuBarExtraStyle(.menu)
    }

    /// Das Symbol zeigt den Diktat-Zustand, solange einer läuft — sonst den der Engine. Ohne
    /// Overlay ist es die einzige sichtbare Rückmeldung (Entscheidung des Anwenders).
    private var symbol: String {
        switch dictation.session {
        case .recording: "mic.circle.fill"
        case .processing: "ellipsis.circle"
        // Kein Warnzeichen: Es ist nichts schiefgegangen — der Text konnte nur nicht sicher direkt
        // eingefügt werden und wartet in der Zwischenablage auf ⌘V.
        case .inZwischenablage: "doc.on.clipboard"
        case .failed: "exclamationmark.circle"
        case .idle:
            switch state.engine {
            case .ready: "mic.fill"
            case .starting, .stopped: "mic"
            case .failed: "mic.slash"
            }
        }
    }
}

/// Kümmert sich um Programmstart und -ende von Engine und Diktat — bewusst **nicht** über den
/// `.task`-Modifier auf der `MenuBarExtra`-Szene:
///
/// - **Start:** Ob `.task` auf einer reinen `MenuBarExtra`-Szene zuverlässig genau einmal feuert
///   (statt z. B. erst beim ersten Öffnen des Menüs, oder erneut danach), ist für dieses
///   Szenen-Konstrukt nicht dokumentiert. `applicationDidFinishLaunching` feuert garantiert genau
///   einmal pro Programmstart — ein doppelter `state.start()` (und damit im schlimmsten Fall ein
///   zweiter, gleichzeitig gespawnter Sidecar-Prozess) ist damit strukturell ausgeschlossen, nicht
///   nur empirisch beobachtet.
/// - **Ende:** `NSApplication.terminate(_:)` — ob über den „TypeLess beenden"-Button, Cmd+Q, das
///   Dock-Menü oder `osascript … quit` ausgelöst — läuft **immer** durch
///   `applicationShouldTerminate(_:)`. Das ist entscheidend: `dictation.stop()` und
///   `state.shutdown()` sind `async` (warten u. a. auf das Ende einer noch laufenden
///   Verarbeitung bzw. Poll-Task und beenden einen selbst gestarteten Sidecar-Prozess sauber) —
///   ohne diesen Haken würde AppKit den Prozess beenden, bevor die Aufräumarbeit fertig ist, und
///   ein selbst gestarteter Sidecar bliebe als Waise zurück.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Von ``TypeLessApp/init()`` gesetzt, bevor `applicationDidFinishLaunching` feuert.
    var state: AppState?
    var dictation: DictationCoordinator?

    private var setupWindow: NSWindow?
    private var overlayPanel: NSPanel?
    private var overlayHosting: NSHostingController<OverlayView>?

    /// Beobachtet ``AppState/setup`` und öffnet/schließt das Einrichtungs-Fenster von einer
    /// IMMER aktiven Stelle aus (der Auslöser darf nicht im Fenster-Inhalt sitzen — SwiftUI wertet
    /// eine geschlossene ``Window``-Szene nicht aus). ``withObservationTracking`` feuert einmalig,
    /// daher am Ende erneut registrieren.
    private func beobachteSetup() {
        withObservationTracking {
            _ = state?.setup
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.aktualisiereSetupFenster()
                self?.beobachteSetup()
            }
        }
    }

    @MainActor private func aktualisiereSetupFenster() {
        guard let state else { return }
        switch state.setup {
        case .hidden:
            setupWindow?.close()
            setupWindow = nil
        case .downloading, .failed:
            if setupWindow == nil {
                let hosting = NSHostingController(rootView: SetupWindow(state: state))
                let window = NSWindow(contentViewController: hosting)
                window.title = "TypeLess Einrichtung"
                window.styleMask = [.titled]           // bewusst NICHT schließbar: die Einrichtung
                window.isReleasedWhenClosed = false      // steuert das Fenster, nicht der Nutzer
                setupWindow = window
            }
            setupWindow?.center()
            setupWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)      // LSUIElement: sonst bleibt es im Hintergrund
        }
    }

    /// Beobachtet ``DictationCoordinator/overlay`` von einer IMMER aktiven Stelle (nicht aus einer
    /// Fenster-Szene — s. Begründung bei `beobachteSetup`). `withObservationTracking` feuert
    /// einmalig, daher am Ende erneut registrieren.
    private func beobachteOverlay() {
        withObservationTracking {
            _ = dictation?.overlay
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.aktualisiereOverlay()
                self?.beobachteOverlay()
            }
        }
    }

    @MainActor private func aktualisiereOverlay() {
        guard let dictation else { return }
        if case .aus = dictation.overlay {
            overlayPanel?.orderOut(nil)
            return
        }
        if overlayPanel == nil {
            let hosting = NSHostingController(rootView: OverlayView(coordinator: dictation))
            hosting.view.frame.size = hosting.view.fittingSize
            let panel = macheOverlayPanel(inhalt: hosting.view)  // gibt ein PassivesPanel zurück
            overlayHosting = hosting
            overlayPanel = panel
        }
        guard let panel = overlayPanel, let hosting = overlayHosting else { return }
        // Größe an den aktuellen Inhalt anpassen, unten mittig auf dem aktiven Bildschirm platzieren.
        let groesse = hosting.view.fittingSize
        panel.setContentSize(groesse)
        if let screen = NSScreen.main {
            let r = screen.visibleFrame
            let x = r.midX - groesse.width / 2
            let y = r.minY + 96
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFront(nil)   // NICHT makeKey — der Fokus bleibt beim Zielfeld
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let state, let dictation else { return }

        // Einrichtungs-Fenster (Task 7): einmal sofort synchronisieren (falls `setup` beim
        // Start bereits sichtbar ist — z. B. nach einem Neustart mitten im Erststart-Download)
        // und danach über `beobachteSetup()` auf jede weitere Änderung reagieren. AppDelegate
        // lebt für die gesamte Programmlaufzeit — anders als eine `Window`-Szene, deren Body
        // SwiftUI nicht auswertet, solange ihr Fenster geschlossen ist.
        aktualisiereSetupFenster()
        beobachteSetup()

        // Diktat-Overlay (Task 5): genau wie das Einrichtungs-Fenster einmal sofort
        // synchronisieren und danach über `beobachteOverlay()` auf jede weitere Änderung
        // reagieren.
        aktualisiereOverlay()
        beobachteOverlay()

        // BEIDE in EIGENEN Tasks — nacheinander wäre ein Fehler: `state.start()` kehrt erst
        // zurück, wenn die Engine fertig aufgewärmt ist (~20 s, s. `SidecarLifecycle
        // .waitForReady()`). Hing `dictation.start()` an dessen `await`, war der Fn-Hotkey in
        // den ersten 20 s nach dem Programmstart schlicht nicht installiert — Fn tat nichts,
        // ohne dass irgendetwas darauf hingewiesen hätte. (Handprobe M4: als „Diktat startet
        // erst, wenn ich ins Menü klicke" aufgefallen — in Wahrheit hatte das Klicken nur
        // lange genug gedauert.)
        //
        // Engine-Achse und Diktat-Achse sind bewusst getrennt (`EngineState` vs. `SessionState`);
        // dieser Startpfad ist die Stelle, an der sie es auch beim Hochfahren sein müssen. Der
        // Hotkey steht damit sofort. Drückt jemand Fn, bevor die Engine warm ist, nimmt TypeLess
        // auf und meldet beim Loslassen einen sauberen Fehler (`SidecarError.notReady`) — die
        // Zwischenablage bleibt unangetastet.
        // ZUERST, synchron: Ohne dieses Recht legt `CGEvent.tapCreate` zwar klaglos einen Tap an,
        // der aber im Hintergrund nie ein Ereignis sieht — Fn wirkt dann NUR, solange TypeLess
        // die aktive App ist (etwa bei offenem Menü). Kein Fehler, kein Hinweis, nichts.
        // Erst der Aufruf hier bringt macOS dazu, zu fragen und TypeLess überhaupt in die Liste
        // der Eingabeüberwachung aufzunehmen.
        state.requestInputMonitoring()
        // Zweites Recht, dieselbe Falle (s. requestInputMonitoring darüber): Ohne
        // Bedienungshilfen postet `CGEvent.post` klaglos ins Leere — der Text erschiene einfach
        // nicht. Anfordern, nicht nur prüfen.
        state.requestAccessibility()

        Task { await state.start() }
        Task { await dictation.start() }
    }

    /// `.terminateLater` lässt der asynchronen Aufräumarbeit Zeit, ohne den Main-Thread zu
    /// blockieren — ein `DispatchSemaphore.wait()` an dieser Stelle würde mit dem
    /// `@MainActor`-isolierten `shutdown()`/`stop()` in einen Deadlock laufen (beide brauchen den
    /// Main-Thread).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, let dictation else { return .terminateNow }
        Task {
            // Erst das Diktat: Ein fertig gesprochenes, noch laufendes Diktat wird zu Ende
            // verarbeitet, bevor die Engine unter ihm weggezogen wird (s. `DictationCoordinator
            // .stop()`). Erst danach die Engine beenden — sonst bricht eine noch laufende
            // Verarbeitung mitten im Sidecar-Herunterfahren ab.
            await dictation.stop()
            await state.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
