import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    // Startet/beendet Engine und Diktat — s. AppDelegate weiter unten für die Begründung, warum
    // das nicht über den `.task`-Modifier auf der Szene läuft.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState
    @State private var dictation: DictationCoordinator

    init() {
        // Die einzige Stelle, die konkrete Typen kennt (Komposition).
        let settings = UserDefaultsSettingsStore()
        let client = HTTPSidecarClient(socketPath: settings.socketPath)
        let lifecycle = DefaultSidecarLifecycle(
            client: client,
            runner: FoundationProcessRunner(),
            engineDirectory: settings.engineDirectory,
            uvPath: settings.uvPath,
            socketPath: settings.socketPath)

        let state = AppState(lifecycle: lifecycle, client: client,
                             permissions: SystemPermissionsService())
        let dictation = DictationCoordinator(
            hotkey: FnKeyMonitor(),
            recorder: AVAudioEngineRecorder(),
            client: client,
            pasteboard: SystemPasteboard())

        _state = State(wrappedValue: state)
        _dictation = State(wrappedValue: dictation)
        appDelegate.state = state
        appDelegate.dictation = dictation
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, dictation: dictation)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let state, let dictation else { return }
        Task {
            await state.start()
            await dictation.start()
        }
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
