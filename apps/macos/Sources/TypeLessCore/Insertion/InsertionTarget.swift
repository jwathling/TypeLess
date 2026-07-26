import AppKit
@preconcurrency import ApplicationServices
// Nur wegen `IsSecureEventInputEnabled()` (HIToolbox) — kein UI-Import.
@preconcurrency import Carbon
import Foundation

/// Fragt, wohin eingefügt werden dürfte. **Fragt nur — schreibt nie.**
///
/// Als Protokoll, damit der ``DictationCoordinator`` ohne echtes Fenster und ohne erteilte
/// Rechte vollständig testbar bleibt.
public protocol InsertionTarget: Sendable {
    /// Prozesskennung der vordersten App. `nil`, wenn es keine gibt.
    func vordersteApp() -> pid_t?

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
/// **Datenschutz:** Gefragt wird ausschließlich nach der SUBROLLE des fokussierten Elements
/// (Passwortfeld-Erkennung, s. ``istPasswortfeld()``). Der **Inhalt** des Feldes wird nie gelesen —
/// `kAXValueAttribute` wird in diesem Typ gar nicht mehr angefasst (die frühere Setzbarkeitsprüfung
/// gehörte zur inzwischen entfernten Vorab-Klassifizierung, s. Git-Verlauf).
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

    /// Der AX-Knoten mit dem Tastaturfokus — gebraucht einzig von ``istPasswortfeld()``.
    ///
    /// **Datenschutz:** Gefragt wird nur nach dem fokussierten ELEMENT, nicht nach seinem Wert.
    /// `kAXValueAttribute` wird in diesem Typ gar nicht mehr angefasst.
    ///
    /// Setzt ein bereits geprüftes `istVertrauenswuerdig()` voraus (der einzige Aufrufer tut das) —
    /// ohne das Recht liefert AX ohnehin nichts.
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
