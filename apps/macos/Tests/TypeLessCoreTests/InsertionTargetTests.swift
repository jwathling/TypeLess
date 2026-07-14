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

@Test(.enabled(if: !bedienungshilfenVorhanden))
func ohneBedienungshilfenIstDasFokuszielUnbekannt() {
    // Der wichtigste Fall für die Sicherheit: Ohne das Recht darf `AXInsertionTarget` NICHT
    // fälschlich `.beschreibbaresTextfeld` melden — sonst würde der Koordinator tippen, obwohl
    // gar nichts ankommen kann, und das Diktat wäre spurlos weg.
    let ziel = AXInsertionTarget()

    #expect(ziel.fokusziel() == .unbekannt,
            "ohne Recht darf NIE ein Textfeld gemeldet werden — der Text ginge sonst verloren")
}

@Test(.enabled(if: bedienungshilfenVorhanden))
func mitBedienungshilfenLiefertDasFokuszielEineEchteAntwort() {
    // Mit Recht muss eine der drei ECHTEN Antworten kommen — welche, hängt davon ab, was beim
    // Testlauf gerade den Fokus hat (im Testrunner typischerweise kein Textfeld). `.unbekannt`
    // darf jedenfalls nicht mehr herauskommen: Das steht ausschließlich für "kein Recht".
    let ziel = AXInsertionTarget()

    #expect(ziel.fokusziel() != .unbekannt,
            ".unbekannt bedeutet ausschließlich: Recht fehlt")
}
