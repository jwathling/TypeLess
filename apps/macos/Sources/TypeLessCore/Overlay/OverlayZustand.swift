import Foundation

/// Was das Diktat-Overlay gerade anzeigt — die **Anzeige-Projektion** des Diktats, getrennt vom
/// ``SessionState`` (der die Wahrheit über den Ablauf trägt). Eigener Typ, weil das Overlay
/// Dinge zeigt, die der ``SessionState`` nicht kennt: den Live-Pegel, den erkannten Text, und den
/// kurzen „Eingefügt ✓"-Moment (den der ``SessionState`` zu `.idle` zusammenfasst).
public enum OverlayZustand: Sendable, Equatable {
    /// Nichts sichtbar — das Overlay ist ausgeblendet.
    case aus
    /// Aufnahme läuft; `pegel` (0…1) ist der ROHE Momentan-Spitzenpegel des Kerns, ungeglättet —
    /// die Glättung (Balken-Animation) übernimmt die Anzeige, nicht der Kern.
    case hoertZu(pegel: Float)
    /// Die Engine verarbeitet (STT + LLM).
    case verarbeitet
    /// Der Text wurde direkt an der Cursorposition eingefügt — kurze Erfolgsmeldung, KEIN Text
    /// (er steht ja schon im Feld).
    case eingefuegt
    /// Das Diktat wurde vom Anwender abgebrochen (Taste bei gehaltenem Fn). **Kein Fehler** —
    /// eigener Fall, damit das Overlay kein Warnzeichen zeigt, wo nichts schiefging.
    case abgebrochen
    /// Der Text liegt in der Zwischenablage (⌘V). Hier — und nur hier — zeigt das Overlay eine
    /// gekürzte Vorschau, damit der Anwender sieht, was ⌘V einfügt.
    case zwischenablage(vorschau: String)
    /// Ein Fehlschlag im Klartext (z. B. „Nichts erkannt").
    case fehler(String)
}

/// Kürzt den erkannten Text für die Zwischenablage-Vorschau auf den Anfang: erste `grenze`
/// Zeichen, am Wortende abgeschnitten, dann `" …"`. Kürzere Texte bleiben ganz. So bleibt das
/// Overlay eine Zeile breit, egal wie lang das Diktat ist.
///
/// **Datenschutz:** reine Zeichen-Operation, rein lokal — hier wird nur gekürzt, nichts gesendet.
public func overlayVorschau(_ text: String, grenze: Int = 90) -> String {
    let getrimmt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let zeichen = Array(getrimmt)
    guard zeichen.count > grenze else { return getrimmt }

    var schnitt = grenze
    // Letzte Wortgrenze (Leerzeichen) vor der Grenze wird nur genutzt, wenn sie über der HÄLFTE
    // der Grenze liegt (space > grenze * 0.55) — sonst bliebe von der Vorschau kaum noch etwas
    // übrig. Bei einem langen Einzelwort/Kompositum ohne so eine späte Wortgrenze (z. B. eine
    // URL oder ein zusammengesetztes Wort) wird deshalb bewusst HART an der Grenze geschnitten,
    // mitten im Wort — ein bewusster Kompromiss: mehr Text zu zeigen ist wichtiger als ein
    // früher Wortschnitt.
    if let space = zeichen[0..<grenze].lastIndex(of: " "),
       space > Int(Double(grenze) * 0.55) {
        schnitt = space
    }
    var kopf = String(zeichen[0..<schnitt])
    // Abschließende Satzzeichen/Leerzeichen entfernen, damit „… ," o. Ä. nicht entsteht.
    while let last = kopf.last, last == " " || ",;:.".contains(last) { kopf.removeLast() }
    return kopf + " …"
}
