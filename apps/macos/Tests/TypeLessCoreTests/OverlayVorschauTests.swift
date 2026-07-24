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
}
