import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    // Startet/beendet die Engine — s. AppDelegate weiter unten für die Begründung, warum das
    // nicht über den `.task`-Modifier auf der Szene läuft.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState

    init() {
        // Die einzige Stelle, die konkrete Typen kennt (Komposition).
        let settings = UserDefaultsSettingsStore()
        let client = HTTPSidecarClient(socketPath: settings.socketPath)
        let lifecycle = DefaultSidecarLifecycle(
            client: client,
            runner: FoundationProcessRunner(),
            engineDirectory: settings.engineDirectory,
            uvPath: settings.uvPath)

        let state = AppState(lifecycle: lifecycle, client: client,
                             permissions: SystemPermissionsService())
        _state = State(wrappedValue: state)
        appDelegate.state = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: symbol)
        }
        .menuBarExtraStyle(.menu)
    }

    /// Das Symbol spiegelt den Zustand — man sieht auf einen Blick, ob TypeLess bereit ist.
    private var symbol: String {
        switch state.engine {
        case .ready: "mic.fill"
        case .starting, .stopped: "mic"
        case .failed: "mic.slash"
        }
    }
}

/// Kümmert sich um Programmstart und -ende der Engine — bewusst **nicht** über den
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
///   `applicationShouldTerminate(_:)`. Das ist entscheidend: `state.shutdown()` ist `async`
///   (wartet u. a. auf das Ende der Poll-Task und beendet einen selbst gestarteten Sidecar-Prozess
///   sauber) — ohne diesen Haken würde AppKit den Prozess beenden, bevor die Aufräumarbeit
///   fertig ist, und ein selbst gestarteter Sidecar bliebe als Waise zurück.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Von ``TypeLessApp/init()`` gesetzt, bevor `applicationDidFinishLaunching` feuert.
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let state else { return }
        Task { await state.start() }
    }

    /// `.terminateLater` lässt der asynchronen Aufräumarbeit Zeit, ohne den Main-Thread zu
    /// blockieren — ein `DispatchSemaphore.wait()` an dieser Stelle würde mit dem
    /// `@MainActor`-isolierten `shutdown()` in einen Deadlock laufen (beide brauchen den
    /// Main-Thread).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task {
            await state.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
