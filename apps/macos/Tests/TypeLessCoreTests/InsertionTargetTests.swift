import AppKit
import Testing
@testable import TypeLessCore

/// Diese Proben fassen die ECHTE AX-Schnittstelle an. Ohne erteilte Bedienungshilfen kann sie
/// nichts liefern — dann überspringen sie sich selbst, statt die Suite rot zu machen (Muster aus
/// M4, s. `AudioRecorderTests`).
let bedienungshilfenVorhanden = AXIsProcessTrusted()

@Test
func vordersteAppLiefertEinePid() {
    // Braucht KEIN Recht: NSWorkspace ist frei zugänglich. Im Testprozess ist immer irgendeine
    // App vorne (mindestens der Testrunner selbst) — eine PID muss also herauskommen.
    let ziel = AXInsertionTarget()

    #expect(ziel.vordersteApp() != nil, "es ist immer irgendeine App vorne")
}

@Test
func ohneBedienungshilfenIstDasFokuszielUnbekannt() {
    // Der wichtigste Fall für die Sicherheit: Ohne das Recht darf `AXInsertionTarget` NICHT
    // fälschlich `.beschreibbaresTextfeld` melden — sonst würde der Koordinator tippen, obwohl
    // gar nichts ankommen kann, und das Diktat wäre spurlos weg.
    //
    // Läuft IMMER, unabhängig davon, ob diese Maschine das Recht erteilt hat: Die
    // Vertrauensprüfung wird injiziert (s. `AXInsertionTarget.istVertrauenswuerdig`). Mit einem
    // festen `AXIsProcessTrusted()` übersprang sich dieser Test auf einer Maschine MIT Recht —
    // und blieb dann auch dann grün, wenn man die Sicherheitsregel entfernte. Eine Wache, die
    // sich selbst überspringt, wacht nicht.
    //
    // `sichereEingabeAktiv: { false }` bewusst gesetzt: Sonst könnte ein zufällig aktives Secure
    // Event Input (s. Probe darunter) den `.unbekannt`-Wert liefern und diese Probe grün halten,
    // obwohl die RECHTE-Prüfung entfernt wurde — jede Wache prüft genau ihre eigene Regel.
    let ziel = AXInsertionTarget(istVertrauenswuerdig: { false }, sichereEingabeAktiv: { false })

    #expect(ziel.fokusziel() == .unbekannt,
            "ohne Recht darf NIE ein Textfeld gemeldet werden — der Text ginge sonst verloren")
}

@Test
func beiSichererEingabeIstDasFokuszielUnbekannt() {
    // C1 (Review zu Task 4, Critical): Secure Event Input (Terminal → Shell → „Sichere
    // Tastatureingabe", 1Password u. Ä.) lässt macOS synthetische Tastatur-Ereignisse fremder
    // Prozesse verwerfen — UNABHÄNGIG von den Bedienungshilfen. Ohne die Prüfung sähe hier alles
    // gut aus (Recht erteilt, setzbares Textfeld im Fokus), der Koordinator tippte, `CGEventPost`
    // meldete nichts, der Text käme nie an — und die Zwischenablage bliebe unangetastet, weil das
    // Tippen als Erfolg gälte. Das Diktat wäre spurlos weg.
    //
    // Deshalb steht die Prüfung VOR allen anderen, und deshalb ist sie hier mit erteiltem Recht
    // (`istVertrauenswuerdig: { true }`) geprüft: Nur so beweist der Test, dass sie eigenständig
    // greift und nicht bloß von der Rechte-Prüfung verdeckt wird. Läuft IMMER — eine Wache, die
    // sich selbst überspringt, wacht nicht.
    let ziel = AXInsertionTarget(istVertrauenswuerdig: { true }, sichereEingabeAktiv: { true })

    #expect(ziel.fokusziel() == .unbekannt,
            "bei Secure Event Input darf NIE ein Textfeld gemeldet werden — Getipptes käme nicht an")
}

@Test(.enabled(if: bedienungshilfenVorhanden))
func mitBedienungshilfenLiefertDasFokuszielEineEchteAntwort() {
    // Mit Recht muss eine der drei ECHTEN Antworten kommen — welche, hängt davon ab, was beim
    // Testlauf gerade den Fokus hat (im Testrunner typischerweise kein Textfeld). `.unbekannt`
    // darf jedenfalls nicht mehr herauskommen: Das steht ausschließlich dafür, dass TypeLess es
    // nicht wissen KANN (kein Recht oder Secure Event Input).
    //
    // Secure Event Input wird deshalb hier fest auf `false` gesetzt, statt die Maschine zu fragen:
    // Läuft `swift test` in einem Terminal mit „Sicherer Tastatureingabe" (oder steht 1Password
    // gerade vorne), lieferte die echte Abfrage `true` — die Probe wäre rot, obwohl nichts kaputt
    // ist. Der ECHTE Weg durch AX (das, was diese Probe prüft) beginnt ohnehin erst danach.
    let ziel = AXInsertionTarget(istVertrauenswuerdig: { AXIsProcessTrusted() },
                                 sichereEingabeAktiv: { false })

    #expect(ziel.fokusziel() != .unbekannt,
            ".unbekannt bedeutet ausschließlich: TypeLess kann es nicht wissen")
}
