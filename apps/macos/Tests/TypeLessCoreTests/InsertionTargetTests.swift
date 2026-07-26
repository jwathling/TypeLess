import AppKit
import Testing
@testable import TypeLessCore

@Test
func vordersteAppLiefertEinePid() {
    // Braucht KEIN Recht: NSWorkspace ist frei zugänglich. Im Testprozess ist immer irgendeine
    // App vorne (mindestens der Testrunner selbst) — eine PID muss also herauskommen.
    let ziel = AXInsertionTarget()

    #expect(ziel.vordersteApp() != nil, "es ist immer irgendeine App vorne")
}

// MARK: - Die neue Zustellregel: nur noch das Passwortfeld wird am Element geprüft

@Test
func nurDieSichereSubrolleGiltAlsPasswortfeld() {
    // Die AX-Schnittstelle kennt KEINE eigene Passwort-Rolle (`kAXSecureTextFieldRole` existiert
    // nicht): Ein Passwortfeld meldet sich als normales Textfeld und verrät sich einzig über die
    // SUBROLLE. Entfernte man diesen Vergleich, tippte TypeLess in Passwortfelder.
    #expect(AXInsertionTarget.istPasswortSubrolle(kAXSecureTextFieldSubrole as String))
    #expect(AXInsertionTarget.istPasswortSubrolle(nil) == false)
    #expect(AXInsertionTarget.istPasswortSubrolle(kAXSearchFieldSubrole as String) == false)
}

@Test
func ohneBedienungshilfenWirdKeinPasswortfeldErkannt() {
    // Ehrlich benannte Grenze (Spec, Restrisiko 2): Ohne Recht liefert AX kein Element, also auch
    // keine Subrolle. `false` ist hier folgenlos, weil ohne Bedienungshilfen ohnehin NICHT getippt
    // wird — das entscheidet `bedienungshilfenErteilt()` in `stelleZu`.
    let ziel = AXInsertionTarget(istVertrauenswuerdig: { false }, sichereEingabeAktiv: { false })

    #expect(ziel.istPasswortfeld() == false)
}

@Test
func dieBeidenKostenlosenPruefungenMeldenDenInjiziertenZustand() {
    // Beide Prüfungen sind die Grundlage der neuen Regel und müssen unabhängig vom Zustand der
    // Maschine prüfbar bleiben (gleiche Begründung wie bei `istVertrauenswuerdig`, s. dort).
    let aus = AXInsertionTarget(istVertrauenswuerdig: { false }, sichereEingabeAktiv: { false })
    let an = AXInsertionTarget(istVertrauenswuerdig: { true }, sichereEingabeAktiv: { true })

    #expect(aus.bedienungshilfenErteilt() == false)
    #expect(aus.sichereEingabeIstAktiv() == false)
    #expect(an.bedienungshilfenErteilt())
    #expect(an.sichereEingabeIstAktiv())
}
