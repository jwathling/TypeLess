import CoreGraphics
import Foundation

public enum TextInserterError: Error, Equatable {
    /// Das Tastatur-Ereignis ließ sich nicht **erzeugen**. Der Aufrufer weicht dann auf die
    /// Zwischenablage aus — ein Diktat darf nie verloren gehen.
    ///
    /// Achtung, die Umkehrung gilt **nicht**: Dass kein Fehler geworfen wird, heißt nicht, dass
    /// der Text angekommen ist (s. ``TextInserter``). Das Posten selbst meldet nichts zurück.
    case ereignisNichtErzeugbar
}

/// Fügt Text an der Cursorposition ein, indem er Tastatur-Ereignisse erzeugt — als hätte der
/// Anwender getippt, nur in einem Rutsch.
///
/// **Was dieser Typ NICHT kann — und warum der Aufrufer vorher prüfen MUSS:**
///
/// `CGEventPost` ist in Apples Header als `void` deklariert: kein Rückgabewert, kein Fehlerkanal.
/// Das Posten kann aus **mindestens zwei** Gründen wirkungslos verpuffen — es fehlen die
/// Bedienungshilfen (nicht erteilt, oder zur Laufzeit entzogen), **oder** Secure Event Input ist
/// aktiv (dann verwirft macOS synthetische Tastatur-Ereignisse fremder Prozesse, ganz unabhängig
/// von den Bedienungshilfen). In beiden Fällen erscheint kein Zeichen, und `insert()` kehrt
/// trotzdem **ohne Fehler** zurück. Ein `throw` aus `insert()` bedeutet also „das Ereignis ließ
/// sich nicht **erzeugen**"; es ist **keine** Bestätigung, dass ein nicht-werfender Aufruf
/// tatsächlich angekommen ist. Diese Bestätigung gibt es auf dieser Schnittstelle schlicht nicht.
///
/// Der Schutz davor liegt deshalb **außerhalb** dieses Typs: Der Aufrufer darf `insert()` nur
/// aufrufen, wenn ``InsertionTarget/fokusziel()`` ein `.beschreibbaresTextfeld` gemeldet hat —
/// was weder ohne erteilte Bedienungshilfen noch bei aktivem Secure Event Input passiert (in
/// beiden Fällen kommt `.unbekannt` heraus, s. ``AXInsertionTarget/fokusziel()``). Diese
/// Vorab-Prüfung ist **Pflicht, nicht Kür**: Ohne sie tippt TypeLess ins Leere und das Diktat ist
/// spurlos weg — genau das, was M5 ausschließen soll.
///
/// **Ehrlich benannt:** Damit sind die *bekannten* Gründe abgedeckt, nicht bewiesenermaßen alle.
/// Eine Zustellbestätigung gibt es auf dieser Ebene nicht — sie ließe sich nur erkaufen, indem man
/// den Inhalt des Zielfeldes läse, und das schließt das Datenschutz-Versprechen dieses Projekts
/// aus (gleiche Abwägung wie bei ``Fokusziel/passwortfeld``).
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

    /// **Tragende Invariante, keine Geschmacksfrage** (I1, Abschluss-Review M5, Important).
    ///
    /// Dieser Einfüger postet `keyDown`-Ereignisse. Gleichzeitig zählt ``SystemKeyDownCounter``
    /// Tastendrücke — er ist die Wache gegen „Fn als Modifier benutzt": Steigt er zwischen
    /// Fn-Druck und Fn-Loslassen, verwirft `DictationCoordinator` das Diktat **kommentarlos**.
    /// Zählte dieser Zähler die hier geposteten Ereignisse mit, hieße das: Diktat 1 wird fertig
    /// und **tippt**, während der Anwender Fn für Diktat 2 schon hält → der Zähler steigt →
    /// Diktat 2 wird stumm weggeworfen, der Anwender hat umsonst gesprochen. Das dritte Ergebnis,
    /// das M5 ausschließt — und keine Anzeige würde es verraten.
    ///
    /// **Gemessen** (Abschluss-Review M5): Ob der Zähler ein selbst gepostetes Ereignis
    /// mitzählt, hängt **allein an dieser Tap-Wahl** — die `stateID` der Quelle (auch
    /// `.privateState`) ändert nichts daran. Auf `.cgAnnotatedSessionEventTap` bleiben beide
    /// Zähler (`.hidSystemState` und `.combinedSessionState`) stehen; auf `.cghidEventTap`
    /// steigen **beide** um die Zahl der geposteten Ereignisse (auf HID-Ebene injizierte
    /// Ereignisse sind von echter Hardware per Konstruktion nicht unterscheidbar). Die volle
    /// Tabelle steht bei ``KeyDownCounter``.
    ///
    /// Deshalb: **Diese Konstante darf nicht auf `.cghidEventTap` wechseln** — auch nicht als
    /// schneller Reflex, falls eine App annotierte Session-Ereignisse schluckt. Wer das doch
    /// braucht, muss vorher die Fn-als-Modifier-Wache anders bauen (z. B. die eigenen geposteten
    /// Ereignisse mitzählen und herausrechnen). Ein Test bewacht diesen Wert.
    static let postTap: CGEventTapLocation = .cgAnnotatedSessionEventTap

    public init() {}

    public func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard let quelle = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInserterError.ereignisNichtErzeugbar
        }

        // ERST alle Ereignisse bauen, DANN posten — bewusst in zwei Durchgängen.
        //
        // Naheliegender wäre eine Schleife, die jedes Häppchen sofort nach dem Bauen postet. Die
        // hat aber einen hässlichen Fehlerfall: Scheitert das Bauen beim fünften von zehn
        // Häppchen, stehen die ersten vier bereits **im Textfeld des Anwenders**, und `insert()`
        // wirft trotzdem. Der Aufrufer legt daraufhin den VOLLSTÄNDIGEN Text in die
        // Zwischenablage (so ist der Vertrag) — drückt der Anwender dann ⌘V, hat er den Anfang
        // doppelt im Dokument.
        //
        // In zwei Durchgängen ist das ausgeschlossen: Geht beim Bauen etwas schief, wurde noch
        // kein einziges Zeichen getippt. Entweder alles oder nichts.
        var ereignisse: [CGEvent] = []
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
            ereignisse.append(runter)
            ereignisse.append(hoch)
        }

        // `postTap` ist bewusst eine benannte Konstante und kein Literal — an ihr hängt die
        // Fn-als-Modifier-Wache (s. dort und ``KeyDownCounter``).
        for ereignis in ereignisse {
            ereignis.post(tap: Self.postTap)
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
