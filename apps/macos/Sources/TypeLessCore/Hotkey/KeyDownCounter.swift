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
/// Die Lösung: `CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)`
/// liefert eine reine Ordnungszahl aller Tastendrücke seit Systemstart — kein Keycode, nichts
/// Speicherbares. Steigt der Zähler zwischen Fn-Druck und Fn-Loslassen, hat der Nutzer
/// mindestens eine Zeichentaste gedrückt, während Fn unten war — Fn wurde als Modifier benutzt,
/// nicht zum Diktieren. Das lässt sich erkennen, OHNE die Event-Maske des Taps um `.keyDown` zu
/// erweitern (das wäre eine echte Verschlechterung der Datenschutz-Haltung).
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

    public func aktuellerStand() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }
}
