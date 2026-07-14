import CoreGraphics

/// Reiner Tastendruck-ZÄHLER seit Systemstart — ohne Keycode, ohne Inhalt, ohne zu wissen,
/// WELCHE Taste gedrückt wurde (I1, Review M4, Important).
///
/// Hintergrund: `FnKeyMonitor`s `CGEventTap` läuft bewusst `.listenOnly` und mit einer
/// Event-Maske, die AUSSCHLIESSLICH `.flagsChanged` sieht (s. dort) — er kann technisch gar
/// nicht erfahren, welche Zeichentaste gedrückt wurde. Das ist Absicht: Eine dauerhaft im
/// Hintergrund laufende App soll so wenig wie möglich über Tastatureingaben wissen können.
///
/// Problem dabei: Hält der Nutzer Fn als MODIFIER (Fn+Pfeil, Fn+Entf, …) länger als die
/// Diktat-Mindestdauer (300 ms — bei mehrfachem Drücken normal), nimmt TypeLess trotzdem auf —
/// der Tap verschluckt nichts, Fn+Pfeil funktioniert ja weiter. Whisper halluziniert dann aus
/// dem Rauschen/Tastaturklappern einen Satz, der die Zwischenablage überschreibt.
///
/// Die Lösung: `CGEventSource.counterForEventType(…, eventType: .keyDown)` liefert eine reine
/// Ordnungszahl aller Tastendrücke seit Systemstart — kein Keycode, nichts Speicherbares. Steigt
/// der Zähler zwischen Fn-Druck und Fn-Loslassen, hat der Nutzer mindestens eine Zeichentaste
/// gedrückt, während Fn unten war — Fn wurde als Modifier benutzt, nicht zum Diktieren. Das lässt
/// sich erkennen, OHNE die Event-Maske des Taps um `.keyDown` zu erweitern (das wäre eine echte
/// Verschlechterung der Datenschutz-Haltung).
///
/// ## Achtung, unsichtbare Kopplung: TypeLess TIPPT seit M5 selbst
///
/// (I1, Abschluss-Review M5, Important.) ``CGEventTextInserter`` postet beim Einfügen echte
/// `keyDown`-Ereignisse. Zählte dieser Zähler die MIT, entstünde ein lautloser Datenverlust:
/// Diktat 1 wird fertig und tippt, während der Anwender Fn für Diktat 2 schon hält → der Zähler
/// steigt → Diktat 2 wird beim Loslassen als „Fn war ein Modifier" **kommentarlos verworfen**
/// (s. `DictationCoordinator.handleReleased()`). Der Anwender hat gesprochen, und es passiert
/// nichts — bei zufriedener Anzeige. Genau das dritte Ergebnis, das M5 ausschließt.
///
/// **Gemessen** (Abschluss-Review M5, auf dieser Maschine; 20 synthetische `keyDown` posten und
/// die Differenz beider Zähler lesen). Ob ein selbst gepostetes Ereignis mitgezählt wird, hängt
/// **allein am Tap, auf den der Einfüger postet** — die `stateID` der Ereignis*quelle* (auch
/// `.privateState`) ändert daran nichts:
///
/// | Der Einfüger postet auf …    | `.hidSystemState` | `.combinedSessionState` |
/// |------------------------------|-------------------|-------------------------|
/// | `.cgAnnotatedSessionEventTap`| **+0**            | +0                      |
/// | `.cgSessionEventTap`         | **+0**            | **+20** ⚠               |
/// | `.cghidEventTap`             | +20 ⚠             | +20 ⚠                   |
///
/// Daraus folgen zwei Dinge, und beide sind nötig:
///
/// 1. **Hier** wird `.hidSystemState` gelesen, nicht `.combinedSessionState`. Das ist semantisch
///    das, was die Regel meint („hat *der Nutzer* eine Zeichentaste gedrückt?") — und deckt eine
///    Tap-Wahl mehr ab.
/// 2. `.hidSystemState` allein rettet **nicht**: Postet der Einfüger je auf `.cghidEventTap`,
///    zählt auch dieser Zähler mit — auf HID-Ebene injizierte Ereignisse sind von Hardware per
///    Konstruktion nicht unterscheidbar. Deshalb ist die Tap-Wahl des Einfügers eine **tragende
///    Invariante** und keine Geschmacksfrage; sie ist in ``CGEventTextInserter/postTap``
///    festgeschrieben, dort begründet und durch einen Test bewacht.
///
/// Als Protokoll, damit `DictationCoordinator` den Zähler im Test steuern kann (ohne echte
/// Tastendrücke zu erzeugen).
public protocol KeyDownCounter: Sendable {
    /// Aktueller Zählerstand. Der genaue Anfangswert ist irrelevant — nur die DIFFERENZ zwischen
    /// zwei Aufrufen zählt.
    func aktuellerStand() -> UInt32
}

/// Die echte Implementierung über `CGEventSource`.
public struct SystemKeyDownCounter: KeyDownCounter {
    public init() {}

    /// `.hidSystemState`, **nicht** `.combinedSessionState` — s. die Messtabelle oben
    /// (I1, Abschluss-Review M5): Der Zähler soll ausschließlich Tastendrücke DES NUTZERS sehen,
    /// nie die Ereignisse, die ``CGEventTextInserter`` selbst postet.
    public func aktuellerStand() -> UInt32 {
        CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
    }
}
