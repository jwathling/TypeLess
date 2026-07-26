import AppKit
@preconcurrency import ApplicationServices
// Nur wegen `IsSecureEventInputEnabled()` (HIToolbox) — kein UI-Import.
@preconcurrency import Carbon
import Foundation

/// Was hat gerade den Fokus? Entscheidet, ob TypeLess dort hineintippen darf.
public enum Fokusziel: Sendable, Equatable {
    /// Ein Textfeld, in das geschrieben werden darf — hier und nur hier wird getippt.
    case beschreibbaresTextfeld
    /// Ein Passwortfeld. TypeLess tippt dort **grundsätzlich nicht** hinein.
    ///
    /// **Bekannte Grenze, ehrlich benannt:** Diese Erkennung hängt daran, dass die App ihr Feld
    /// über die AX-Subrolle `AXSecureTextField` ausweist. Apps mit lückenhafter
    /// AX-Umsetzung (z. B. manche Electron-/Cross-Platform-Apps) melden für ihr Passwortfeld
    /// unter Umständen **gar keine** Subrolle — dann sieht TypeLess ein normales Textfeld und
    /// würde dort einfügen. Schließen ließe sich das nur, indem man den **Inhalt** des Feldes
    /// läse, und genau das ist im Datenschutz-Versprechen dieses Projekts ausgeschlossen. Die
    /// Lücke ist also keine Nachlässigkeit, sondern der Preis dieser Zusicherung — sie steht hier,
    /// damit niemand später mehr Sicherheit annimmt, als diese Schnittstelle liefern kann.
    case passwortfeld
    /// Irgendetwas anderes hat den Fokus (Liste, Knopf, Leinwand) — oder gar nichts.
    case keinTextfeld
    /// TypeLess kann es schlicht **nicht wissen** — entweder fehlen die Bedienungshilfen, oder
    /// **Secure Event Input** ist aktiv (dann würde ein Tippen zwar erlaubt aussehen, aber
    /// wirkungslos verpuffen, s. ``AXInsertionTarget/fokusziel()``).
    ///
    /// Bewusst ein eigener Fall und **nicht** mit ``keinTextfeld`` zusammengelegt: Beide führen
    /// zwar zum selben Verhalten (Zwischenablage statt tippen), aber sie bedeuten Verschiedenes.
    /// `keinTextfeld` ist eine Aussage über die Welt, `unbekannt` eine über TypeLess. Nur so
    /// kann das Menü dem Anwender sagen, dass es an den Umständen auf TypeLess' Seite liegt
    /// (fehlendes Recht oder Secure Event Input) — statt ihn glauben zu lassen, er habe nicht ins
    /// richtige Feld geklickt.
    case unbekannt
}

/// Die **Identität** des fokussierten Elements — undurchsichtig und ausschließlich vergleichbar.
///
/// **Datenschutz (die harte Grenze dieses Projekts):** Dieser Typ trägt die IDENTITÄT eines
/// Elements, **nie seinen Inhalt**. Er lässt sich auf `==` prüfen und sonst nichts: Es gibt keine
/// Möglichkeit, aus ihm auszulesen, was in dem Feld steht — der gekapselte `AXUIElement` ist
/// `private` und wird nur an `CFEqual` gereicht. TypeLess erfährt so, OB der Cursor noch im selben
/// Feld steht, aber nie, WAS darin steht.
///
/// Bewusst **undurchsichtig** und nicht etwa ein durchgereichter `AXUIElement`: Der
/// ``DictationCoordinator`` muss ohne echtes Fenster und ohne Bedienungshilfen vollständig testbar
/// bleiben. Ein Protokoll, das rohe `AXUIElement` durchreicht, machte das unmöglich — eine
/// Testattrappe kann keinen echten AX-Knoten erfinden. Deshalb zwei Ausprägungen: im Produktivcode
/// ein `AXUIElement`, im Test eine schlichte Zahl (s. ``fuerTest(_:)``).
public struct Fokuskennung: Equatable, @unchecked Sendable {
    /// `@unchecked Sendable` und der Grund dafür: `AXUIElement` ist ein CF-Typ und damit für den
    /// Compiler nicht `Sendable`, obwohl er hier nachweislich sicher zwischen Ausführungskontexten
    /// reisen kann — er ist ein **unveränderlicher, undurchsichtiger Handle**, auf dem dieser Typ
    /// ausschließlich `CFEqual` aufruft (lesend, threadsicher). Gebraucht wird das, weil die
    /// Kennung vom `@MainActor` in die Verarbeitungs-Task dieses Diktats mitreist.
    private enum Inhalt {
        /// Der echte Weg: der fokussierte AX-Knoten.
        case ax(AXUIElement)
        /// Der Testweg: eine erfundene Kennung, ohne jede AX-Beteiligung.
        case erfunden(UInt64)
    }

    private let inhalt: Inhalt

    /// **Modulintern, kein `public`** — gleiche Bauart und gleicher Grund wie
    /// ``AXInsertionTarget/istVertrauenswuerdig``: Könnte die App-Schicht Kennungen selbst bauen,
    /// ließe sich die Fokusprüfung von außen aushebeln (zwei frisch gebaute, künstlich gleiche
    /// Kennungen — und schon tippt TypeLess wieder in die Adressleiste). Nur ``AXInsertionTarget``
    /// erzeugt echte Kennungen.
    init(ax element: AXUIElement) { inhalt = .ax(element) }

    /// **Nur für Tests** (modulintern, s. o.): eine Element-Identität ohne Element. Damit kann die
    /// Testattrappe zwei verschiedene „Textfelder" derselben App unterscheidbar machen, ohne dass
    /// je ein Fenster geöffnet oder ein Recht erteilt werden müsste.
    static func fuerTest(_ kennung: UInt64) -> Fokuskennung {
        Fokuskennung(inhalt: .erfunden(kennung))
    }

    private init(inhalt: Inhalt) { self.inhalt = inhalt }

    /// Vergleicht **nur Identitäten**, nie Inhalte. `CFEqual` ist für `AXUIElement` genau die
    /// Frage „derselbe Knoten in derselben App?" — es liest das Element nicht aus.
    public static func == (links: Fokuskennung, rechts: Fokuskennung) -> Bool {
        switch (links.inhalt, rechts.inhalt) {
        case let (.ax(a), .ax(b)): return CFEqual(a, b)
        case let (.erfunden(a), .erfunden(b)): return a == b
        // Ein echtes Element ist nie dasselbe wie eine erfundene Kennung. Kann im Betrieb nicht
        // vorkommen (ein Ziel liefert immer nur eine Sorte), muss aber entschieden werden — und
        // „ungleich" ist hier die sichere Antwort: Sie führt auf die Zwischenablage, nicht ins
        // Tippen.
        default: return false
        }
    }
}

/// Fragt, wohin eingefügt werden dürfte. **Fragt nur — schreibt nie.**
///
/// Als Protokoll, damit der ``DictationCoordinator`` ohne echtes Fenster und ohne erteilte
/// Rechte vollständig testbar bleibt.
public protocol InsertionTarget: Sendable {
    /// Prozesskennung der vordersten App. `nil`, wenn es keine gibt.
    func vordersteApp() -> pid_t?
    /// Art des Elements, das gerade den Tastaturfokus hat.
    func fokusziel() -> Fokusziel
    /// **Identität** des Elements, das gerade den Tastaturfokus hat — `nil`, wenn keines fokussiert
    /// ist oder TypeLess es nicht wissen kann (fehlende Bedienungshilfen).
    ///
    /// Die App-Kennung allein reicht nicht: Innerhalb DERSELBEN App kann der Anwender während der
    /// ~6 s Wartezeit in ein anderes Feld springen (⌘L in die Adressleiste des Browsers, Tab vom
    /// Mail-Rumpf ins Betreff-Feld). Ohne diese Frage wären alle übrigen Bedingungen erfüllt —
    /// gleiche App, beschreibbares Textfeld, kein Passwortfeld — und das Diktat landete in der
    /// Adressleiste. Deshalb merkt sich jedes Diktat beim Fn-Druck zusätzlich, in WELCHEM Feld es
    /// gesprochen wurde (s. ``DictationCoordinator``).
    ///
    /// **Datenschutz:** Liefert ausschließlich die vergleichbare Identität (``Fokuskennung``),
    /// niemals den Inhalt des Feldes.
    func fokusKennung() -> Fokuskennung?

    /// Fordert die App mit dieser Prozesskennung auf, ihren Bedienungshilfen-Baum zu aktivieren
    /// (Electron/Chromium bauen ihn erst auf Anforderung auf — s. Design). **Setzt nur** ein
    /// Attribut, liest nichts. Für native Apps folgenlos.
    func weckeBedienungshilfen(fuer pid: pid_t)

    /// Ob TypeLess die Bedienungshilfen hat. Ohne sie verwirft macOS jedes synthetische
    /// Tastatur-Ereignis — Tippen wäre wirkungslos, das Diktat spurlos weg.
    ///
    /// Braucht selbst **kein** fokussiertes AX-Element und darum in jeder App verlässlich.
    func bedienungshilfenErteilt() -> Bool

    /// Ob **Secure Event Input** gerade aktiv ist (Terminal mit „Sichere Tastatureingabe",
    /// 1Password u. Ä.). Dann verwirft macOS synthetische Tastatur-Ereignisse fremder Prozesse,
    /// **unabhängig** von den Bedienungshilfen.
    ///
    /// Keine Vorsicht, sondern Physik: Ohne diese Prüfung würde getippt, `CGEventPost` meldete
    /// nichts zurück (s. ``TextInserter``), und das Diktat wäre bei zufriedener Anzeige verloren.
    func sichereEingabeIstAktiv() -> Bool

    /// Ob das fokussierte Element ein Passwortfeld ist.
    ///
    /// **Ehrlich benannte Grenze:** Die Erkennung hängt an der AX-Subrolle
    /// `AXSecureTextField`. Wo kein AX-Element auffindbar ist (Apps mit unvollständigem Baum) oder
    /// die Subrolle fehlt, liefert das `false` — dann wird hineingetippt. Schließen ließe sich das
    /// nur durch Lesen des Feldinhalts, was das Datenschutz-Versprechen ausschließt. Der Schaden
    /// ist asymmetrisch harmlos: TypeLess tippt **hinein** und liest nie **heraus**.
    func istPasswortfeld() -> Bool
}

/// Die echte Umsetzung über die Bedienungshilfen-Schnittstelle (AX).
///
/// **Datenschutz:** Gefragt wird ausschließlich nach der ROLLE des fokussierten Elements, danach,
/// ob es beschreibbar ist, und nach seiner **Identität** (``Fokuskennung`` — vergleichbar, nicht
/// auslesbar). Der **Inhalt** des Feldes wird nie gelesen —
/// `kAXValueAttribute` wird ausschließlich auf *Setzbarkeit* geprüft
/// (`AXUIElementIsAttributeSettable`), nie ausgelesen. TypeLess erfährt also nie, was in dem
/// Feld steht, in das es schreibt.
public struct AXInsertionTarget: InsertionTarget {
    /// Ob TypeLess die Bedienungshilfen hat. **Injizierbar, und das aus einem konkreten Grund:**
    ///
    /// Die Regel darunter („ohne Recht NIEMALS ein Textfeld melden") ist die wichtigste
    /// Sicherheitszusicherung dieses Typs — meldete er fälschlich ein Textfeld, tippte der
    /// Koordinator ins Leere und das Diktat wäre spurlos weg. Genau diese Regel ließ sich mit
    /// einem festen `AXIsProcessTrusted()` **nicht prüfen**: Auf einer Maschine mit erteiltem
    /// Recht übersprang sich der schützende Test und blieb auch dann grün, wenn man die Regel
    /// entfernte (in der Umsetzung von M5/Task 2 genau so beobachtet). Ein Test, der eine
    /// Sicherheitsregel nicht scharf prüft, ist keine Wache, sondern Dekoration.
    ///
    /// Mit dieser Naht ist die Regel unabhängig vom Zustand der Maschine beweisbar.
    private let istVertrauenswuerdig: @Sendable () -> Bool

    /// Ob **Secure Event Input** gerade aktiv ist (C1, Review zu Task 4, Critical).
    ///
    /// Aus demselben Grund injizierbar wie ``istVertrauenswuerdig``: Der Zustand hängt daran, was
    /// auf der Maschine gerade im Vordergrund steht (Terminal mit „Sichere Tastatureingabe",
    /// 1Password u. Ä.) — ein fester `IsSecureEventInputEnabled()` wäre im Testlauf praktisch
    /// immer `false` und die Regel damit nicht prüfbar.
    private let sichereEingabeAktiv: @Sendable () -> Bool

    public init() {
        istVertrauenswuerdig = { AXIsProcessTrusted() }
        sichereEingabeAktiv = { IsSecureEventInputEnabled() }
    }

    /// **Nur für Tests** — bewusst NICHT `public`: Wäre dieser Init von außerhalb des Moduls
    /// erreichbar, könnte die App-Schicht bei der Verdrahtung versehentlich
    /// `AXInsertionTarget(istVertrauenswuerdig: { true })` bauen (etwa aus dem Testcode kopiert)
    /// und damit die Sicherheitsprüfung im Produktivbetrieb aushebeln — kein Test würde das je
    /// bemerken, weil er denselben Konstruktor unauffällig weiterbenutzte. Gleiche Bauart wie
    /// `AVAudioEngineRecorder.init(mikrofonPruefung:)`, aus demselben Grund.
    init(istVertrauenswuerdig: @escaping @Sendable () -> Bool,
         sichereEingabeAktiv: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
        self.istVertrauenswuerdig = istVertrauenswuerdig
        self.sichereEingabeAktiv = sichereEingabeAktiv
    }

    public func vordersteApp() -> pid_t? {
        // Braucht kein Sonderrecht.
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func fokusziel() -> Fokusziel {
        // C1 (Review zu Task 4, Critical): **VOR allen anderen Prüfungen.** Ist Secure Event Input
        // aktiv (Terminal → Shell → „Sichere Tastatureingabe", 1Password u. Ä., solange ihr
        // Fenster vorne ist), verwirft macOS synthetische Tastatur-Ereignisse fremder Prozesse —
        // **unabhängig von den Bedienungshilfen**. Ohne diese Prüfung sähe hier alles in bester
        // Ordnung aus: App stimmt, `AXIsProcessTrusted()` erteilt, fokussiert ist ein setzbares
        // `AXTextArea` → `.beschreibbaresTextfeld`. Der Koordinator tippte, `CGEventPost` meldet
        // nichts zurück (s. ``TextInserter``), das Diktat käme nie an — und weil das Tippen als
        // Erfolg gälte, bliebe auch die Zwischenablage unangetastet: Das Diktat wäre spurlos weg,
        // bei zufriedener Anzeige. Genau das schließt M5 aus. `.unbekannt` (nicht `.keinTextfeld`)
        // ist hier richtig: Es ist eine Aussage über TypeLess, nicht über das Feld — und es führt
        // auf den bereits gebauten Ausweichweg (Zwischenablage).
        //
        // Der Aufruf braucht kein Sonderrecht.
        guard !sichereEingabeAktiv() else { return .unbekannt }

        // Ohne Recht liefert AX gar nichts Verwertbares. Das MUSS als `.unbekannt` heraus und
        // darf niemals als "kein Textfeld" durchgehen — der Unterschied entscheidet darüber, was
        // das Menü dem Anwender erzählt.
        guard istVertrauenswuerdig() else { return .unbekannt }

        guard let ax = fokussiertesElement() else { return .keinTextfeld }

        // Rolle, Subrolle und Setzbarkeit AUSLESEN — ausschließlich Metadaten, **nie** den Inhalt
        // (`kAXValueAttribute` wird nur auf Setzbarkeit geprüft, nicht kopiert). Die eigentliche
        // Entscheidung trifft die reine, ohne AX prüfbare ``klassifiziere(rolle:subrolle:setzbar:)``.
        // Schlägt eine Abfrage fehl, bleibt der jeweilige Wert leer/`false` — was `klassifiziere`
        // konservativ als `.keinTextfeld` behandelt (kein fehlender Fall führt je ins Tippen).
        var rolle: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &rolle)
        var subrolle: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subrolle)
        var setzbar: DarwinBoolean = false
        AXUIElementIsAttributeSettable(ax, kAXValueAttribute as CFString, &setzbar)

        return Self.klassifiziere(rolle: rolle as? String,
                                  subrolle: subrolle as? String,
                                  setzbar: setzbar.boolValue)
    }

    /// Entscheidet allein aus den AX-Metadaten eines fokussierten Elements, ob dorthin getippt
    /// werden darf. **Reine Funktion, ohne jede AX-Abfrage** — damit die Sicherheitsregeln (welche
    /// Feldtypen beschreibbar sind, dass die Passwort-Subrolle alles schlägt, dass ein nicht
    /// setzbares Feld abgelehnt wird) ohne echtes Fenster und ohne erteilte Rechte prüfbar sind.
    ///
    /// **Datenschutz:** Nimmt ausschließlich Rolle, Subrolle und Setzbarkeit entgegen — nie den
    /// Inhalt des Feldes.
    static func klassifiziere(rolle: String?, subrolle: String?, setzbar: Bool) -> Fokusziel {
        // Ohne Rolle ist nichts entscheidbar — die sichere Antwort ist „kein Textfeld".
        guard let rolle else { return .keinTextfeld }

        // Passwortfelder zuerst — in sie wird unter keinen Umständen getippt, egal welche Rolle sie
        // sonst tragen. Die AX-Schnittstelle kennt dafür KEINE eigene Rolle
        // (`kAXSecureTextFieldRole` existiert nicht — geprüft gegen AXRoleConstants.h): Ein
        // Passwortfeld meldet sich als ganz normales `kAXTextFieldRole` und unterscheidet sich nur
        // über die SUBROLLE `kAXSecureTextFieldSubrole`. Deshalb hier zuerst, vor jeder Textrolle.
        if subrolle == (kAXSecureTextFieldSubrole as String) { return .passwortfeld }

        let textRollen: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            // WebKit-basierte editierbare Bereiche melden sich als `AXWebArea` — u. a. der
            // Nachrichtenrumpf von Apple Mail (WebKit-Editor für Formatierung/Bilder) sowie Webmail
            // und andere Rich-Text-Editoren auf WebKit-Basis. Für diese Rolle gibt es keine
            // offizielle Konstante; der Name ist der von WebKit vergebene String. Zugelassen NUR
            // zusammen mit der Setzbarkeitsprüfung unten: Eine reine Anzeige-Webseite (etwa in
            // Safari) meldet `kAXValue` nicht als setzbar und fällt damit heraus — es wird also nie
            // versucht, in eine nicht editierbare Seite zu tippen.
            "AXWebArea",
        ]
        guard textRollen.contains(rolle) else { return .keinTextfeld }

        // Rolle allein reicht nicht: Ein Textfeld kann schreibgeschützt sein (Anzeige-Feld), und
        // ein `AXWebArea` ist nur dann ein Ziel, wenn er editierbar ist.
        guard setzbar else { return .keinTextfeld }

        return .beschreibbaresTextfeld
    }

    public func fokusKennung() -> Fokuskennung? {
        // Ohne Recht liefert AX kein fokussiertes Element — dann gibt es auch keine Identität, die
        // sich später vergleichen ließe. `nil` ist hier die sichere Antwort: Beim Zustellen führt
        // eine fehlende gemerkte Kennung auf die Zwischenablage, nie ins Tippen
        // (s. ``DictationCoordinator``). Secure Event Input wird hier bewusst NICHT geprüft — es
        // sagt nichts über die Identität des Elements, sondern nur darüber, ob Getipptes ankäme;
        // diese Frage beantwortet ``fokusziel()``, und dort steht die Prüfung.
        guard istVertrauenswuerdig() else { return nil }
        guard let ax = fokussiertesElement() else { return nil }
        return Fokuskennung(ax: ax)
    }

    public func weckeBedienungshilfen(fuer pid: pid_t) {
        // Electron/Chromium bauen ihren AX-Baum erst, wenn eine assistive Technologie ihn
        // anfordert — genau dafür ist `AXManualAccessibility` da. Bei nativen Apps ist das Setzen
        // wirkungslos (unbekanntes Attribut). Ein Fehlschlag (fehlende Rechte, App weg) ist
        // folgenlos: dann bleibt es beim Zwischenablage-Fallback wie bisher.
        // **Datenschutz:** setzt nur, liest nichts. Bewusst NICHT `AXEnhancedUserInterface`
        // (löst bei manchen Apps Layout-Wechsel aus).
        let app = AXUIElementCreateApplication(pid)
        // Härtung (finaler Review): AXUIElementSetAttributeValue ist ein synchroner XPC-Ruf zur
        // Zielapp. Ohne Begrenzung blockierte eine hängende App den MainActor bis zum AX-Default-
        // Timeout (~6 s) — beim Fn-Druck den Aufnahmestart, beim App-Wechsel Menü/Hotkey. Ein kurzer
        // Messaging-Timeout deckelt das hart; ein Timeout ist folgenlos (dann bleibt es beim
        // Zwischenablage-Fallback wie bisher).
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    public func bedienungshilfenErteilt() -> Bool { istVertrauenswuerdig() }

    public func sichereEingabeIstAktiv() -> Bool { sichereEingabeAktiv() }

    /// **Datenschutz:** liest ausschließlich die SUBROLLE — nie den Inhalt des Feldes.
    /// `kAXValueAttribute` wird in diesem Typ nach der Umkehrung gar nicht mehr angefasst.
    public func istPasswortfeld() -> Bool {
        // Ohne Recht liefert AX kein Element; ohne Element keine Subrolle. `false` ist folgenlos,
        // weil `stelleZu` das fehlende Recht ohnehin schon abgefangen hat.
        guard istVertrauenswuerdig() else { return false }
        guard let ax = fokussiertesElement() else { return false }
        var subrolle: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subrolle)
        return Self.istPasswortSubrolle(subrolle as? String)
    }

    /// Die reine Passwort-Regel, **ohne jede AX-Abfrage** — damit sie ohne Fenster und ohne
    /// erteilte Rechte scharf prüfbar ist (gleiche Bauart wie vormals `klassifiziere`).
    ///
    /// Die AX-Schnittstelle kennt keine eigene Passwort-**Rolle** (`kAXSecureTextFieldRole`
    /// existiert nicht, geprüft gegen `AXRoleConstants.h`): Ein Passwortfeld meldet sich als
    /// normales `kAXTextFieldRole` und verrät sich einzig über diese Subrolle.
    static func istPasswortSubrolle(_ subrolle: String?) -> Bool {
        subrolle == (kAXSecureTextFieldSubrole as String)
    }

    /// Der AX-Knoten mit dem Tastaturfokus — die gemeinsame Wurzel von ``fokusziel()`` und
    /// ``fokusKennung()``.
    ///
    /// **Datenschutz:** Gefragt wird nur nach dem fokussierten ELEMENT, nicht nach seinem Wert.
    /// `kAXValueAttribute` wird in diesem Typ ausschließlich auf Setzbarkeit geprüft
    /// (`AXUIElementIsAttributeSettable`), nie ausgelesen.
    ///
    /// Setzt ein bereits geprüftes `istVertrauenswuerdig()` voraus (beide Aufrufer tun das) — ohne
    /// das Recht liefert AX ohnehin nichts.
    private func fokussiertesElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var fokussiertes: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &fokussiertes)
        guard status == .success, let element = fokussiertes else { return nil }
        // `as!` wäre hier ein Absturz-Risiko, falls AX je etwas anderes liefert.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)  // sicher: TypeID oben geprüft
    }
}
