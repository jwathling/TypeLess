import Foundation

/// Beantwortet die Frage: Ist bei dieser Aufnahme überhaupt Ton angekommen?
///
/// Ohne Overlay und ohne Tonsignal (Entscheidung des Anwenders) ist das der einzige
/// Fehlerfall, den der Nutzer sonst erst beim Einfügen bemerkt — nachdem er 30 Sekunden in
/// ein stummgeschaltetes Mikrofon gesprochen hat.
public enum SilenceDetector {
    /// −50 dBFS ≈ 0,00316 in Float32.
    ///
    /// Bewusst niedrig: Ein stummes Mikrofon liefert winziges Rauschen (deutlich darunter),
    /// leises Sprechen dagegen liegt bei etwa −40 dBFS (0,01) — also klar darüber. Der
    /// Schwellwert trennt „nichts angekommen" von „leise gesprochen", nicht „leise" von „laut".
    public static let thresholdDBFS: Float = -50

    private static var thresholdAmplitude: Float {
        pow(10, thresholdDBFS / 20)
    }

    /// Spitzenpegel, **nicht** Durchschnitt: Eine Aufnahme mit einem einzelnen lauten Wort und
    /// viel Pause ist nicht tonlos.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    public static func isSilent(_ samples: [Float]) -> Bool {
        peak(samples) < thresholdAmplitude
    }
}
