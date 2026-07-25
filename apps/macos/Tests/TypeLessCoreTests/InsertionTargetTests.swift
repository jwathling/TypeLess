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

// MARK: - Klassifizierung eines fokussierten Elements (reine Logik, ohne AX)

// Diese Proben brauchen KEIN Recht und KEIN Fenster: `klassifiziere(...)` entscheidet allein aus
// Rolle, Subrolle und Setzbarkeit. So sind die Sicherheitsregeln, die sonst hinter der echten
// AX-Abfrage in `fokusziel()` verborgen (und darum ungetestet) waren, scharf prüfbar.

@Test
func einSetzbaresTextfeldIstBeschreibbar() {
    #expect(AXInsertionTarget.klassifiziere(
        rolle: kAXTextFieldRole as String, subrolle: nil, setzbar: true) == .beschreibbaresTextfeld)
    #expect(AXInsertionTarget.klassifiziere(
        rolle: kAXTextAreaRole as String, subrolle: nil, setzbar: true) == .beschreibbaresTextfeld)
    #expect(AXInsertionTarget.klassifiziere(
        rolle: kAXComboBoxRole as String, subrolle: nil, setzbar: true) == .beschreibbaresTextfeld)
}

@Test
func einSetzbarerWebAreaIstBeschreibbar() {
    // Der eigentliche Fix: WebKit-editierbare Bereiche (Apple Mail-Nachrichtenrumpf, Webmail,
    // Rich-Text-Editoren) melden sich als `AXWebArea`. Solange sie setzbar sind, wird dorthin
    // direkt eingefügt — die vier übrigen Bedingungen in `stelleZu` bleiben davon unberührt.
    #expect(AXInsertionTarget.klassifiziere(
        rolle: "AXWebArea", subrolle: nil, setzbar: true) == .beschreibbaresTextfeld)
}

@Test
func einNichtSetzbarerWebAreaIstKeinTextfeld() {
    // Die Setzbarkeitsprüfung ist der Schutz, der `AXWebArea` sicher macht: Eine reine
    // Anzeige-Webseite (etwa in Safari) meldet `kAXValue` nicht als setzbar und darf NIE ein
    // Einfüge-Ziel werden. Entfernte man die Setzbarkeitsprüfung, tippte TypeLess in beliebige
    // Webseiten — diese Probe würde dann rot.
    #expect(AXInsertionTarget.klassifiziere(
        rolle: "AXWebArea", subrolle: nil, setzbar: false) == .keinTextfeld)
}

@Test
func einNichtSetzbaresTextfeldIstKeinTextfeld() {
    // Schreibgeschütztes Anzeige-Feld: richtige Rolle, aber nicht setzbar → kein Ziel.
    #expect(AXInsertionTarget.klassifiziere(
        rolle: kAXTextFieldRole as String, subrolle: nil, setzbar: false) == .keinTextfeld)
}

@Test
func dasPasswortfeldSchlaegtAlles() {
    // Die Passwort-Subrolle führt IMMER zu `.passwortfeld` — auch bei setzbarem Feld und auch bei
    // einem WebArea. Entfernte man die Subrollen-Prüfung, käme hier `.beschreibbaresTextfeld`
    // heraus und TypeLess tippte in ein Passwortfeld.
    #expect(AXInsertionTarget.klassifiziere(
        rolle: kAXTextFieldRole as String,
        subrolle: kAXSecureTextFieldSubrole as String,
        setzbar: true) == .passwortfeld)
    #expect(AXInsertionTarget.klassifiziere(
        rolle: "AXWebArea",
        subrolle: kAXSecureTextFieldSubrole as String,
        setzbar: true) == .passwortfeld)
}

@Test
func eineFremdeRolleIstKeinTextfeld() {
    // Knöpfe, Listen, Leinwände u. Ä. sind nie ein Ziel — selbst wenn sie setzbar wären.
    #expect(AXInsertionTarget.klassifiziere(
        rolle: kAXButtonRole as String, subrolle: nil, setzbar: true) == .keinTextfeld)
}

@Test
func ohneRolleIstKeinTextfeld() {
    // Fehlgeschlagene Rollen-Abfrage (Element weg, App hängt): die sichere Antwort ist „kein Feld".
    #expect(AXInsertionTarget.klassifiziere(
        rolle: nil, subrolle: nil, setzbar: true) == .keinTextfeld)
}

// MARK: - Abschluss-Review M5: die Identität des fokussierten Elements

@Test
func ohneBedienungshilfenGibtEsKeineFokuskennung() {
    // Ohne Recht liefert AX kein fokussiertes Element — dann darf hier auch keine Identität
    // herauskommen. `nil` ist die sichere Antwort: Beim Zustellen führt eine fehlende gemerkte
    // Kennung auf die Zwischenablage, nie ins Tippen (s. `DictationCoordinator.stelleZu`).
    //
    // Läuft IMMER (injizierte Vertrauensprüfung, s. `AXInsertionTarget.istVertrauenswuerdig`) —
    // eine Wache, die sich auf einer Maschine MIT Recht selbst überspringt, wacht nicht.
    let ziel = AXInsertionTarget(istVertrauenswuerdig: { false }, sichereEingabeAktiv: { false })

    #expect(ziel.fokusKennung() == nil, "ohne Recht gibt es keine Identität zu vergleichen")
}

@Test
func fokuskennungenVergleichenNurIdentitaeten() {
    // Der ganze Vertrag dieses Typs in einer Probe: gleiche Kennung → gleich, andere → ungleich.
    // Mehr kann er nicht, und mehr DARF er nicht: Er trägt die IDENTITÄT eines Elements, nie
    // seinen Inhalt (Datenschutz-Grenze dieses Projekts).
    #expect(Fokuskennung.fuerTest(1) == Fokuskennung.fuerTest(1))
    #expect(Fokuskennung.fuerTest(1) != Fokuskennung.fuerTest(2),
            "zwei verschiedene Textfelder derselben App dürfen nie als dasselbe gelten")
}

@Test(.enabled(if: bedienungshilfenVorhanden))
func mitBedienungshilfenIstDieFokuskennungInSichStabil() {
    // Zweimal hintereinander gefragt, ohne dass sich etwas bewegt hat: Es muss dieselbe Identität
    // herauskommen — sonst wiche TypeLess IMMER auf die Zwischenablage aus (die neue Bedingung
    // träfe nie zu) und das direkte Einfügen wäre in der Praxis tot. `CFEqual` auf `AXUIElement`
    // ist genau die Frage "derselbe Knoten in derselben App?" — es liest das Element nicht aus.
    //
    // Im Testrunner ist typischerweise gar nichts fokussiert; dann sind beide Antworten `nil` —
    // auch das ist "in sich stabil" und für diese Probe in Ordnung. Es geht hier ausschließlich
    // darum, dass die Kennung nicht bei jedem Aufruf von selbst eine andere wird.
    let ziel = AXInsertionTarget(istVertrauenswuerdig: { AXIsProcessTrusted() },
                                 sichereEingabeAktiv: { false })

    #expect(ziel.fokusKennung() == ziel.fokusKennung(),
            "ohne Fokuswechsel muss zweimal dieselbe Identität herauskommen")
}
