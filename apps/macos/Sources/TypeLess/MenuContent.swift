import SwiftUI
import TypeLessCore

/// Der Inhalt des Menüleisten-Menüs. Zeigt nur an, was ``AppState`` und
/// ``DictationCoordinator`` sagen — keine Logik. Kein ``@Bindable``: Das Menü schreibt nichts
/// zurück, es liest nur. ``@Observable`` sorgt dafür, dass es sich bei jeder Zustandsänderung
/// neu zeichnet.
struct MenuContent: View {
    let state: AppState
    let dictation: DictationCoordinator

    var body: some View {
        Text(statusText)

        Divider()

        // Ohne Eingabeüberwachung sieht der Tastatur-Hook im Hintergrund NICHTS — Fn wirkt dann
        // nur, solange TypeLess die aktive App ist (z. B. bei offenem Menü). Genau dieses
        // Fehlerbild kostete in der Handprobe zu M4 einen Abend: „Diktieren geht nur, wenn ich
        // das Menü offen habe." Deshalb steht es hier ganz oben und nicht bloß als eines von
        // drei Häkchen weiter unten.
        if state.hotkeyBrauchtEingabeueberwachung {
            Text("⚠ Eingabeüberwachung fehlt — Fn wirkt nur bei offenem Menü")
            Button("   → Eingabeüberwachung erlauben, dann TypeLess neu starten") {
                state.openSettings(for: .inputMonitoring)
            }
            Divider()
        }

        // Der Hotkey ist nutzlos, wenn macOS die Fn-Taste selbst belegt. Das sagen wir, statt
        // den Nutzer rätseln zu lassen, warum ständig Emojis aufpoppen.
        if FnKeyMonitor.fnKeyOpensEmojiPicker() {
            Text("⚠ Fn öffnet den Emoji-Picker")
            Text("   Tastatur-Einstellungen → „Beim Drücken der 🌐-Taste“ → „Keine Aktion“")
            Divider()
        }

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
        // AppDelegate (TypeLessApp.swift) fängt das ab und wartet dort async zuerst auf
        // dictation.stop(), dann auf state.shutdown() — derselbe Weg wie bei Cmd+Q oder
        // „Beenden" im Dock. Ein zweiter, hier lokaler Aufruf würde nur denselben Zustand
        // doppelt (und ohne Not vor dem eigentlichen Beenden-Ereignis) durchlaufen.
        Button("TypeLess beenden") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Der Diktat-Zustand hat Vorrang: Während der Aufnahme oder Verarbeitung interessiert die
    /// Engine nicht — das sähe der Nutzer ohnehin nur als irreführende Ablenkung.
    private var statusText: String {
        switch dictation.session {
        case .recording: "🔴 Nimmt auf …"
        case .processing: "Verarbeite …"
        case let .failed(grund): "Fehler: \(grund)"
        case .idle:
            switch state.engine {
            case .ready where state.hotkeyBrauchtEingabeueberwachung:
                "⚠ Engine bereit, aber Fn wirkt nicht (s. unten)"
            case .ready: "Bereit — Fn halten zum Diktieren"
            case .starting: "Engine startet …"
            case .stopped: "Engine: gestoppt"
            case let .failed(grund): "Engine-Fehler: \(grund)"
            }
        }
    }
}
