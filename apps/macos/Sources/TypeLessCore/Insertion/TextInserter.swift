import CoreGraphics
import Foundation

public enum TextInserterError: Error, Equatable {
    /// Das Tastatur-Ereignis ließ sich nicht erzeugen. Der Aufrufer weicht dann auf die
    /// Zwischenablage aus — ein Diktat darf nie verloren gehen.
    case ereignisNichtErzeugbar
}

/// Fügt Text an der Cursorposition ein, indem er Tastatur-Ereignisse erzeugt — als hätte der
/// Anwender getippt, nur in einem Rutsch.
///
/// Als Protokoll, damit der ``DictationCoordinator`` testbar bleibt, ohne dass im Testlauf
/// wirklich irgendwo Text erscheint.
public protocol TextInserter: Sendable {
    func insert(_ text: String) throws
}

/// Die echte Umsetzung über `CGEventKeyboardSetUnicodeString`.
///
/// **Warum nicht über die Zwischenablage (simuliertes ⌘V):** Ausdrückliche Entscheidung des
/// Anwenders (s. Spec). Dieser Weg lässt die Zwischenablage vollständig in Ruhe.
///
/// **Warum nicht über die AX-API (`kAXValueAttribute` setzen):** Verworfen — das überschreibt in
/// vielen Apps das GANZE Feld, statt an der Cursorposition einzufügen. AX wird ausschließlich
/// zum Fragen benutzt (s. ``AXInsertionTarget``).
public struct CGEventTextInserter: TextInserter {
    /// Ein `CGEvent` nimmt nur begrenzt viele UTF-16-Einheiten auf. Längerer Text wird sonst
    /// **stillschweigend abgeschnitten** — das Diktat wäre teilweise weg, ohne jede Fehlermeldung.
    static let haeppchenGroesse = 20

    public init() {}

    public func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard let quelle = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInserterError.ereignisNichtErzeugbar
        }

        for haeppchen in Self.zerlege(text) {
            guard let runter = CGEvent(keyboardEventSource: quelle, virtualKey: 0, keyDown: true),
                  let hoch = CGEvent(keyboardEventSource: quelle, virtualKey: 0, keyDown: false)
            else { throw TextInserterError.ereignisNichtErzeugbar }

            // `virtualKey: 0` plus gesetzter Unicode-String: Das System nimmt den String, nicht
            // den Tastencode — so lässt sich beliebiger Text einfügen, unabhängig vom
            // Tastaturlayout des Anwenders.
            runter.keyboardSetUnicodeString(stringLength: haeppchen.count,
                                            unicodeString: haeppchen)
            hoch.keyboardSetUnicodeString(stringLength: haeppchen.count, unicodeString: haeppchen)

            runter.post(tap: .cgAnnotatedSessionEventTap)
            hoch.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Zerlegt den Text in Häppchen von höchstens ``haeppchenGroesse`` UTF-16-Einheiten — **ohne
    /// je ein Surrogatpaar zu zerschneiden**.
    ///
    /// Emoji und viele Sonderzeichen belegen zwei UTF-16-Einheiten (Surrogatpaar). Ein naives
    /// Zerlegen nach genau 20 Einheiten kann mitten hindurchschneiden; die beiden Hälften wären
    /// dann für sich genommen ungültiges UTF-16, und statt des Zeichens erschiene Müll. Deshalb
    /// wird ein Häppchen lieber eine Einheit kürzer, als ein Paar zu trennen.
    static func zerlege(_ text: String) -> [[UInt16]] {
        let einheiten = Array(text.utf16)
        var haeppchen: [[UInt16]] = []
        var start = 0

        while start < einheiten.count {
            var ende = min(start + haeppchenGroesse, einheiten.count)
            // Endet das Häppchen auf der ERSTEN Hälfte eines Surrogatpaars, eine Einheit
            // zurückgehen — das Paar wandert dann vollständig ins nächste Häppchen.
            if ende < einheiten.count, UTF16.isLeadSurrogate(einheiten[ende - 1]) {
                ende -= 1
            }
            haeppchen.append(Array(einheiten[start..<ende]))
            start = ende
        }
        return haeppchen
    }
}
