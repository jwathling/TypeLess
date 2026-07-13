import SwiftUI
import TypeLessCore

/// Der Inhalt des Menüleisten-Menüs. Zeigt nur an, was ``AppState`` sagt — keine Logik.
/// Kein ``@Bindable``: Das Menü schreibt nichts zurück, es liest nur. ``@Observable`` sorgt
/// dafür, dass es sich bei jeder Zustandsänderung neu zeichnet.
struct MenuContent: View {
    let state: AppState

    var body: some View {
        Text(engineText)

        Divider()

        ForEach(Permission.allCases, id: \.self) { permission in
            Button {
                state.openSettings(for: permission)
            } label: {
                let granted = state.permissions.isGranted(permission)
                Text("\(granted ? "✓" : "⚠") \(permission.title) — \(permission.purpose)")
            }
        }

        Divider()

        Button("Engine neu starten") {
            Task { await state.restart() }
        }

        // Läuft ausschließlich über NSApplication.terminate(): applicationShouldTerminate(_:) in
        // AppDelegate (TypeLessApp.swift) fängt das ab und wartet dort async auf state.shutdown()
        // — derselbe Weg wie bei Cmd+Q oder „Beenden" im Dock. Ein zweiter, hier lokaler Aufruf von
        // state.shutdown() würde nur denselben Zustand doppelt (und ohne Not vor dem eigentlichen
        // Beenden-Ereignis) durchlaufen.
        Button("TypeLess beenden") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Der Zustand in einem Satz — bei einem Fehler mit dem Grund im Klartext.
    private var engineText: String {
        switch state.engine {
        case .stopped: "Engine: gestoppt"
        case .starting: "Engine: startet …"
        case .ready: "Engine: bereit"
        case let .failed(reason): "Engine-Fehler: \(reason)"
        }
    }
}
