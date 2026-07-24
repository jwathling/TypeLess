import Testing
@testable import TypeLessCore

struct OverlayVorschauTests {
    @Test func kurzerTextBleibtGanz() {
        #expect(overlayVorschau("Ja, passt.") == "Ja, passt.")
    }

    @Test func langerTextWirdAmWortendeGekuerzt() {
        let text = "Ich schlage vor, dass wir das Feature erst nach dem Release angehen, weil sonst der Zeitplan kippt."
        let v = overlayVorschau(text, grenze: 40)
        #expect(v.hasSuffix(" …"))
        #expect(v.count <= 42)              // 40 + " …" minus entfernter Rest
        #expect(!v.dropLast(2).hasSuffix(" ")) // kein Leerzeichen vor dem Auslassungszeichen
        #expect(text.hasPrefix(String(v.dropLast(2)))) // der Anfang stimmt wörtlich
    }

    @Test func genauAnDerGrenzeBleibtGanz() {
        let text = String(repeating: "a", count: 30)
        #expect(overlayVorschau(text, grenze: 30) == text)
    }

    @Test func ohneWortgrenzeImKnappenBereichHarterSchnitt() {
        // Ein sehr langes Wort ohne Leerzeichen: es gibt keine sinnvolle Wortgrenze,
        // also wird hart an der Grenze geschnitten.
        let text = String(repeating: "b", count: 60)
        let v = overlayVorschau(text, grenze: 20)
        #expect(v == String(repeating: "b", count: 20) + " …")
    }

    @Test func fuehrendeUndFolgendeLeerzeichenWerdenGetrimmt() {
        #expect(overlayVorschau("   Hallo Welt   ") == "Hallo Welt")
    }

    @Test func wortgrenzeUnterDerHaelfteFuehrtZuHartemSchnittAnDerGrenze() {
        // Randfall der Schwelle `space > grenze * 0.55`: Eine Wortgrenze, die (weit) UNTER der
        // Hälfte der Grenze liegt, zählt NICHT — dann wird bewusst hart an der Grenze
        // geschnitten, auch mitten in einem langen Wort, statt an der frühen Wortgrenze.
        // Grenze 20 → Schwelle 11: Das Leerzeichen bei Index 2 ("hi ") liegt weit darunter, das
        // folgende lange Wort hat keine weitere Wortgrenze vor der Grenze.
        let text = "hi " + String(repeating: "b", count: 30)
        let v = overlayVorschau(text, grenze: 20)
        let erwarteterHarterSchnitt = "hi " + String(repeating: "b", count: 17)  // erste 20 Zeichen

        #expect(v == erwarteterHarterSchnitt + " …",
                "hart an der Grenze geschnitten, NICHT an der frühen Wortgrenze")
        #expect(!v.hasPrefix("hi …"), "darf NICHT an der frühen Wortgrenze bei Index 2 abschneiden")
    }
}
