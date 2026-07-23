import SwiftUI
import TypeLessCore

/// Der Inhalt des Menüleisten-Menüs. Zeigt nur an, was ``AppState`` und
/// ``DictationCoordinator`` sagen — keine Logik. Kein ``@Bindable``: Das Menü schreibt nichts
/// zurück, es liest nur. ``@Observable`` sorgt dafür, dass es sich bei jeder Zustandsänderung
/// neu zeichnet.
struct MenuContent: View {
    let state: AppState
    let dictation: DictationCoordinator
    /// Löst den Sparkle-Update-Check aus (Verdrahtung in TypeLessApp; hier nur ein Auslöser, keine
    /// Logik — MenuContent bleibt anzeigend).
    let checkForUpdates: () -> Void

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

        // Ohne Bedienungshilfen kann NIE direkt eingefügt werden — der Text landet dann immer in
        // der Zwischenablage. TypeLess bleibt voll benutzbar, aber es tut nicht so, als sei alles
        // in Ordnung (Lektion aus der M4-Handprobe: „Bereit", während der Hotkey tot war).
        if state.einfuegenBrauchtBedienungshilfen {
            Text("⚠ Bedienungshilfen fehlen — Text landet in der Zwischenablage")
            Button("   → Bedienungshilfen erlauben, dann TypeLess neu starten") {
                state.openSettings(for: .accessibility)
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

        Button("Nach Updates suchen …") {
            checkForUpdates()
        }

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
    ///
    /// M3 (Abschluss-Review M5): Bei fehlender Eingabeüberwachung sagte es die Statuszeile, bei
    /// fehlenden Bedienungshilfen nur der Warnblock darunter — die Statuszeile behauptete weiter
    /// „Bereit — Fn halten zum Diktieren". Keine Lüge, aber inkonsistent zur Schwesterregel.
    ///
    /// Rangfolge, wenn BEIDE Rechte fehlen: Die Eingabeüberwachung geht vor. Ohne sie wirkt der
    /// Hotkey gar nicht — dann ist es müßig, vor dem Zustellweg zu warnen, den man ohnehin nie
    /// erreicht.
    private var statusText: String {
        switch dictation.session {
        case .recording: "🔴 Nimmt auf …"
        case .processing: "Verarbeite …"
        // Kein Fehler — nur ein anderer Weg: Der Text ließ sich nicht sicher direkt einfügen.
        case .inZwischenablage: "In der Zwischenablage — ⌘V zum Einfügen"
        case let .failed(grund): "Fehler: \(grund)"
        case .idle:
            switch state.engine {
            case .ready where state.hotkeyBrauchtEingabeueberwachung:
                "⚠ Engine bereit, aber Fn wirkt nicht (s. unten)"
            // Kein Ausfall — Diktieren geht, nur der letzte Schritt ist ein anderer: Der Text
            // landet in der Zwischenablage statt direkt an der Cursorposition.
            case .ready where state.einfuegenBrauchtBedienungshilfen:
                "⚠ Bereit — Text landet aber nur in der Zwischenablage (⌘V)"
            case .ready: "Bereit — Fn halten zum Diktieren"
            case .starting: "Engine startet …"
            case .stopped: "Engine: gestoppt"
            case let .failed(grund): "Engine-Fehler: \(grund)"
            }
        }
    }
}
