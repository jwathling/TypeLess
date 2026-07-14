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
    // Surrogatpaar schneiden, käme statt des Zeichens Müll heraus.
    //
    // **Was dieser Test ist und was nicht** (nachgemessen, nicht angenommen): Er ist ein
    // Regressionsschutz mit realistischem Diktat-Text — er belegt, dass ein normaler deutscher
    // Satz mit Emoji die Zerlegung heil übersteht. Er ist NICHT die Wache über den
    // Surrogat-Schutz: Ob die Emoji zufällig auf eine Häppchen-Grenze fallen, hängt am Wortlaut.
    // Entfernt man den Schutz, bleibt dieser Test grün (ausprobiert). Die eigentliche Wache ist
    // `einEmojiAnJederMoeglichenHaeppchenGrenzeUeberlebt` darunter — die probiert JEDE Position
    // durch und kann sich nicht wegdrehen.
    //
    // (Die erste Fassung war sogar nur 18 UTF-16-Einheiten lang — kürzer als ein Häppchen (20) —
    // und wurde nie zerlegt. Ein Test, der die Grenze nie erreicht, prüft sie nicht.)
    let text = """
        Grüße über Öl 🎉 — größere Änderungen für Müller & Söhne 🚀 sind heute früh \
        überprüft worden 🙂 und äußerst zufriedenstellend
        """

    let haeppchen = CGEventTextInserter.zerlege(text)
    let alle = haeppchen.flatMap { $0 }

    #expect(haeppchen.count > 3, "der Text MUSS lang genug sein, um mehrfach zerlegt zu werden")
    #expect(String(utf16CodeUnits: alle, count: alle.count) == text,
            "Umlaute und Emoji müssen die Zerlegung unbeschadet überleben")
}

@Test
func einEmojiAnJederMoeglichenHaeppchenGrenzeUeberlebt() {
    // Die scharfe Fassung: Ein einzelner Test mit einem festen Emoji-Platz trifft die kritische
    // Grenze nur zufällig. Hier wandert das Emoji durch JEDE mögliche Position rund um die
    // Häppchen-Grenze — ein Off-by-one im Surrogat-Schutz kann sich nirgends verstecken.
    for versatz in 0...(2 * CGEventTextInserter.haeppchenGroesse) {
        let text = String(repeating: "x", count: versatz) + "🎉" + String(repeating: "y", count: 5)

        let haeppchen = CGEventTextInserter.zerlege(text)
        let alle = haeppchen.flatMap { $0 }

        #expect(haeppchen.allSatisfy { haeppchenIstGueltigesUTF16($0) },
                "Versatz \(versatz): Häppchen mitten durch ein Surrogatpaar geschnitten")
        #expect(String(utf16CodeUnits: alle, count: alle.count) == text,
                "Versatz \(versatz): Text hat die Zerlegung nicht unbeschadet überlebt")
    }
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
