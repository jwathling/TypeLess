import Testing
@testable import TypeLessCore

@Test
func leererTextWirdNichtGepostet() throws {
    // Nichts zu tippen heißt: gar kein Ereignis erzeugen. Ein leeres Ereignis zu posten wäre ein
    // sinnloser Tastendruck in einer fremden App.
    let inserter = CGEventTextInserter()

    // Darf nicht werfen und nichts tun.
    try inserter.insert("")
}

@Test
func langerTextWirdInHaeppchenZerlegt() {
    // Ein CGEvent nimmt nur eine begrenzte Zahl UTF-16-Einheiten auf (Apple-Limit: 20). Längerer
    // Text MUSS zerlegt werden — sonst wird er stillschweigend abgeschnitten, und das Diktat ist
    // teilweise weg, ohne dass irgendetwas einen Fehler meldet.
    let text = String(repeating: "a", count: 95)

    let haeppchen = CGEventTextInserter.zerlege(text)

    #expect(haeppchen.count == 5, "95 Einheiten / 20 = 5 Häppchen")
    #expect(haeppchen.allSatisfy { $0.count <= CGEventTextInserter.haeppchenGroesse })
    #expect(haeppchen.flatMap { $0 } == Array(text.utf16), "kein Zeichen darf verloren gehen")
}

@Test
func umlauteUndEmojiBleibenIntakt() {
    // Deutsch ist die Hauptsprache — Umlaute MÜSSEN funktionieren. Emoji sind der harte Fall:
    // Sie belegen zwei UTF-16-Einheiten (Surrogatpaar). Würde ein Häppchen mitten durch ein
    // Surrogatpaar schneiden, käme ein kaputtes Zeichen heraus.
    let text = "Grüße über Öl — 🎉"

    let haeppchen = CGEventTextInserter.zerlege(text)

    let zusammengesetzt = String(utf16CodeUnits: haeppchen.flatMap { $0 },
                                 count: haeppchen.flatMap { $0 }.count)
    #expect(zusammengesetzt == text, "Umlaute und Emoji müssen die Zerlegung überleben")
}

@Test
func surrogatpaarWirdNichtZerschnitten() {
    // Gezielt so gebaut, dass ein naives Zerlegen bei 20 genau MITTEN in ein Surrogatpaar
    // schneiden würde: 19 ASCII-Zeichen, dann ein Emoji (2 UTF-16-Einheiten).
    let text = String(repeating: "x", count: 19) + "🎉"

    let haeppchen = CGEventTextInserter.zerlege(text)

    #expect(haeppchen.allSatisfy { haeppchenIstGueltigesUTF16($0) },
            "kein Häppchen darf mitten durch ein Surrogatpaar geschnitten sein")
}

/// Prüft, dass ein Häppchen für sich allein gültiges UTF-16 ist — also mit keinem halben
/// Surrogatpaar anfängt oder aufhört.
private func haeppchenIstGueltigesUTF16(_ einheiten: [UInt16]) -> Bool {
    if let erste = einheiten.first, UTF16.isTrailSurrogate(erste) { return false }
    if let letzte = einheiten.last, UTF16.isLeadSurrogate(letzte) { return false }
    return true
}
