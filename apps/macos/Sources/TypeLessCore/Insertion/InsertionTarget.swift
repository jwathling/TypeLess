import AppKit
@preconcurrency import ApplicationServices
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
    /// Die Bedienungshilfen fehlen: TypeLess kann es schlicht **nicht wissen**.
    ///
    /// Bewusst ein eigener Fall und **nicht** mit ``keinTextfeld`` zusammengelegt: Beide führen
    /// zwar zum selben Verhalten (Zwischenablage statt tippen), aber sie bedeuten Verschiedenes.
    /// `keinTextfeld` ist eine Aussage über die Welt, `unbekannt` eine über TypeLess. Nur so
    /// kann das Menü dem Anwender sagen, dass ein RECHT fehlt — statt ihn glauben zu lassen, er
    /// habe nicht ins richtige Feld geklickt.
    case unbekannt
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
}

/// Die echte Umsetzung über die Bedienungshilfen-Schnittstelle (AX).
///
/// **Datenschutz:** Gefragt wird ausschließlich nach der ROLLE des fokussierten Elements und
/// danach, ob es beschreibbar ist. Der **Inhalt** des Feldes wird nie gelesen —
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

    public init() {
        istVertrauenswuerdig = { AXIsProcessTrusted() }
    }

    /// **Nur für Tests** — bewusst NICHT `public`: Wäre dieser Init von außerhalb des Moduls
    /// erreichbar, könnte die App-Schicht bei der Verdrahtung versehentlich
    /// `AXInsertionTarget(istVertrauenswuerdig: { true })` bauen (etwa aus dem Testcode kopiert)
    /// und damit die Sicherheitsprüfung im Produktivbetrieb aushebeln — kein Test würde das je
    /// bemerken, weil er denselben Konstruktor unauffällig weiterbenutzte. Gleiche Bauart wie
    /// `AVAudioEngineRecorder.init(mikrofonPruefung:)`, aus demselben Grund.
    init(istVertrauenswuerdig: @escaping @Sendable () -> Bool) {
        self.istVertrauenswuerdig = istVertrauenswuerdig
    }

    public func vordersteApp() -> pid_t? {
        // Braucht kein Sonderrecht.
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func fokusziel() -> Fokusziel {
        // Ohne Recht liefert AX gar nichts Verwertbares. Das MUSS als `.unbekannt` heraus und
        // darf niemals als "kein Textfeld" durchgehen — der Unterschied entscheidet darüber, was
        // das Menü dem Anwender erzählt.
        guard istVertrauenswuerdig() else { return .unbekannt }

        let system = AXUIElementCreateSystemWide()
        var fokussiertes: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &fokussiertes)
        guard status == .success, let element = fokussiertes else { return .keinTextfeld }
        // `as!` wäre hier ein Absturz-Risiko, falls AX je etwas anderes liefert.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return .keinTextfeld }
        let ax = element as! AXUIElement  // sicher: TypeID oben geprüft

        var rolle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &rolle) == .success,
              let rollenName = rolle as? String
        else { return .keinTextfeld }

        // Passwortfelder zuerst — in sie wird unter keinen Umständen getippt. Die AX-Schnittstelle
        // kennt dafür KEINE eigene Rolle (`kAXSecureTextFieldRole` existiert nicht — geprüft gegen
        // AXRoleConstants.h): Ein Passwortfeld meldet sich als ganz normales `kAXTextFieldRole` und
        // unterscheidet sich nur über die SUBROLLE `kAXSecureTextFieldSubrole`. Deshalb hier
        // zusätzlich abfragen, bevor überhaupt auf Textrollen geprüft wird.
        var subrolle: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subrolle) == .success,
           let subrollenName = subrolle as? String,
           subrollenName == (kAXSecureTextFieldSubrole as String) {
            return .passwortfeld
        }

        let textRollen: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        guard textRollen.contains(rollenName) else { return .keinTextfeld }

        // Rolle allein reicht nicht: Ein Textfeld kann schreibgeschützt sein (Anzeige-Feld).
        var setzbar: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(ax, kAXValueAttribute as CFString, &setzbar) == .success,
              setzbar.boolValue
        else { return .keinTextfeld }

        return .beschreibbaresTextfeld
    }
}
