# M5 — Text an der Cursorposition einfügen: Implementierungsplan

> **Für agentische Bearbeiter:** ERFORDERLICHE SUB-SKILL: `superpowers:subagent-driven-development`
> (empfohlen) oder `superpowers:executing-plans`, um diesen Plan Aufgabe für Aufgabe umzusetzen.
> Schritte nutzen Checkbox-Syntax (`- [ ]`) zur Nachverfolgung.

**Ziel:** Der fertige Diktat-Text landet direkt im Textfeld, in dem der Cursor steht — ohne ⌘V
und ohne die Zwischenablage anzufassen. Ist das nicht sicher möglich, landet er in der
Zwischenablage, und das Menü sagt es.

**Architektur:** Zwei neue Protokolle in `TypeLessCore/Insertion/` — `InsertionTarget` (fragt
über die AX-Schnittstelle: welche App ist vorne, und steht der Cursor in einem beschreibbaren
Textfeld?) und `TextInserter` (erzeugt Tastatur-Ereignisse mit
`CGEventKeyboardSetUnicodeString`). Der `DictationCoordinator` merkt sich beim Fn-Druck die
Ziel-App und prüft beim Zustellen vier Bedingungen; nur wenn alle erfüllt sind, wird getippt.

**Tech-Stack:** Swift 6, macOS 14+, `ApplicationServices` (AX), `CoreGraphics` (CGEvent),
`AppKit` (nur `NSWorkspace` — **kein UI**), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-14-m5-text-einfuegen-design.md` — bei jedem Zweifel gilt
die Spec, nicht dieser Plan.

## Global Constraints

Diese gelten für **jede** Aufgabe, ohne Ausnahme:

- **Datenschutz ist das Produktversprechen: keine Cloud, keine APIs, keine Daten verlassen den
  Rechner.** Kein `print`/`NSLog`/`os_log`, keine Temp-Dateien, kein Netzwerkzugriff.
- **Der `CGEventTap` in `FnKeyMonitor` wird in M5 NICHT angefasst.** Seine Event-Maske bleibt
  ausschließlich `.flagsChanged`. Sie um `.keyDown` zu erweitern wäre ein Datenschutzbruch.
- **Die AX-Schnittstelle wird NUR zum Fragen benutzt, nie zum Schreiben.** Gefragt wird
  ausschließlich nach Rolle und Bearbeitbarkeit des fokussierten Elements — **nie nach dessen
  Inhalt** (`kAXValueAttribute` wird weder gelesen noch gesetzt).
- **Oberste Regel von M5:** Der Text wird entweder an der richtigen Stelle eingefügt — oder er
  liegt in der Zwischenablage. Ein drittes Ergebnis gibt es nicht.
- **Die Zwischenablage wird nur beschrieben, wenn sie der Ausweichweg ist.** Wurde direkt
  eingefügt, bleibt sie unangetastet. Bei einem echten Fehler (Engine weg, STT-Ausfall) bleibt
  sie ebenfalls unangetastet — alter Inhalt schlägt Leere.
- `TypeLessCore` importiert **kein SwiftUI und kein AppKit-UI**. `import AppKit` allein für
  `NSWorkspace` ist erlaubt (Präzedenzfall: `Permissions/PermissionsService.swift`).
- Swift 6, **strict concurrency**, Build **warnungsfrei** (`swift build` darf keine einzige
  Warnung ausgeben).
- Kommentare und Docstrings auf **Deutsch**, dem bestehenden Stil folgend.
- **Jede Schutzregel braucht eine Mutationsprobe:** Regel entfernen → der zugehörige Test muss
  **rot werden** (nicht hängen!) → Regel wiederherstellen → grün. Ein Test, der unter einer
  Mutation hängt statt rot zu werden, ist wertlos — das ist in diesem Projekt dreimal passiert.
- Tests laufen mit `cd apps/macos && swift test`. Aktueller Stand vor M5: **95 Tests grün**.

---

## Dateistruktur

| Datei | Verantwortung |
|---|---|
| `Sources/TypeLessCore/Insertion/InsertionTarget.swift` (neu) | *Wohin?* — Protokoll + AX-Umsetzung: vorderste App (PID) und Art des fokussierten Elements. Fragt nur, schreibt nie. |
| `Sources/TypeLessCore/Insertion/TextInserter.swift` (neu) | *Wie?* — Protokoll + CGEvent-Umsetzung: Text als Tastatur-Ereignisse posten. |
| `Sources/TypeLessCore/Dictation/DictationCoordinator.swift` (ändern) | Führt beides zusammen: Ziel-App beim Fn-Druck merken, beim Zustellen die vier Bedingungen prüfen. Neuer `SessionState`-Fall. |
| `Sources/TypeLessCore/Permissions/PermissionsService.swift` (ändern) | `requestAccessibility()` — anfordern, nicht nur prüfen (Lektion aus M4). |
| `Sources/TypeLessCore/AppState.swift` (ändern) | `requestAccessibility()` durchreichen, `einfuegenBrauchtBedienungshilfen` für das Menü. |
| `Sources/TypeLess/TypeLessApp.swift` (ändern) | Komposition (die einzige Stelle, die konkrete Typen kennt) + Recht beim Start anfordern. |
| `Sources/TypeLess/MenuContent.swift` (ändern) | Neuer Zustand und fehlendes Recht sichtbar machen — das Menü darf nicht lügen. |

---

## Task 1: Bedienungshilfen anfordern (nicht nur prüfen)

Die Lektion aus der M4-Handprobe, **bevor** irgendetwas gebaut wird, das darauf angewiesen ist:
`CGEvent.post` braucht das Recht **Bedienungshilfen**. Fehlt es, passiert schlicht nichts — ohne
Fehler, ohne Hinweis. In M4 hat genau dieses Muster (Recht wurde nur geprüft, nie angefordert)
einen Abend gekostet.

**Dateien:**
- Ändern: `apps/macos/Sources/TypeLessCore/Permissions/PermissionsService.swift`
- Ändern: `apps/macos/Sources/TypeLessCore/AppState.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/AppStateTests.swift`

**Interfaces:**
- Konsumiert: `PermissionsService` (bestehend, hat bereits `status()`, `openSettings(for:)`,
  `requestInputMonitoring()`), `AppState` (bestehend).
- Produziert: `PermissionsService.requestAccessibility() -> Bool`,
  `AppState.requestAccessibility()`, `AppState.einfuegenBrauchtBedienungshilfen: Bool`.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

Ans Ende von `apps/macos/Tests/TypeLessCoreTests/AppStateTests.swift` anhängen:

```swift
@MainActor
@Test(.timeLimit(.minutes(1)))
func bedienungshilfenWerdenAktivAngefordertUndNichtNurGeprueft() async throws {
    // Dieselbe Falle wie bei der Eingabeüberwachung in M4: `CGEvent.post` braucht das Recht
    // "Bedienungshilfen". Fehlt es, passiert beim Einfügen schlicht NICHTS — kein Fehler, kein
    // Hinweis. Wird das Recht nur GEPRÜFT und nie ANGEFORDERT, fragt macOS den Anwender nie.
    let permissions = ZaehlendePermissions()
    let state = AppState(lifecycle: FakeLifecycle(.success(.adopted)),
                         client: StaticClient(.success(health("ready"))),
                         permissions: permissions,
                         pollIntervalStarting: .milliseconds(10),
                         pollIntervalReady: .milliseconds(10))

    #expect(state.einfuegenBrauchtBedienungshilfen,
            "vor der Anfrage fehlt das Recht — das Menü muss das sagen können")

    state.requestAccessibility()

    #expect(permissions.axAnfragen == 1, "das Recht muss ANGEFORDERT werden, nicht nur geprüft")
    #expect(!state.einfuegenBrauchtBedienungshilfen,
            "nach erteiltem Recht muss die Anzeige das sofort widerspiegeln")
}
```

`ZaehlendePermissions` in derselben Datei (existiert bereits aus M4) um den AX-Zähler erweitern —
die bestehenden Felder `erteilt`/`anfragen` bleiben unverändert:

```swift
final class ZaehlendePermissions: PermissionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var erteilt = false
    private(set) var anfragen = 0
    private(set) var axAnfragen = 0

    func status() -> PermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return PermissionStatus(microphone: erteilt, accessibility: erteilt,
                                inputMonitoring: erteilt)
    }

    func openSettings(for permission: Permission) {}

    @discardableResult
    func requestInputMonitoring() -> Bool {
        lock.lock(); defer { lock.unlock() }
        anfragen += 1
        erteilt = true
        return true
    }

    @discardableResult
    func requestAccessibility() -> Bool {
        lock.lock(); defer { lock.unlock() }
        axAnfragen += 1
        erteilt = true
        return true
    }
}
```

Die beiden anderen Attrappen in derselben Datei (`FakePermissions`, `MutablePermissions`) müssen
die neue Protokoll-Anforderung ebenfalls erfüllen — je eine Zeile:

```swift
// in FakePermissions:
@discardableResult func requestAccessibility() -> Bool { granted }

// in MutablePermissions:
@discardableResult func requestAccessibility() -> Bool { status().accessibility }
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

```bash
cd apps/macos && swift test --filter bedienungshilfenWerdenAktivAngefordert
```
Erwartung: Übersetzungsfehler — `requestAccessibility` und `einfuegenBrauchtBedienungshilfen`
gibt es noch nicht.

- [ ] **Schritt 3: Umsetzung**

In `PermissionsService.swift` das Protokoll erweitern (direkt unter `requestInputMonitoring()`):

```swift
    /// Fordert die **Bedienungshilfen** an — **muss beim Programmstart aufgerufen werden**.
    ///
    /// Ohne dieses Recht postet `CGEvent.post` zwar klaglos, aber **nichts kommt an**: keine
    /// Ausnahme, kein Rückgabewert, kein Hinweis — der Text erscheint einfach nicht. Genau die
    /// Fehlerklasse, die in der M4-Handprobe einen Abend gekostet hat (dort beim `CGEventTap`,
    /// s. ``requestInputMonitoring()``). Ohne Anfrage zeigt macOS keinen Dialog und trägt
    /// TypeLess unter Umständen nicht einmal in die Liste ein, in der man den Schalter umlegen
    /// könnte.
    ///
    /// Der Rückgabewert sagt, ob das Recht (jetzt) da ist.
    @discardableResult
    func requestAccessibility() -> Bool
```

In `SystemPermissionsService` die Umsetzung (unter `requestInputMonitoring()`):

```swift
    @discardableResult
    public func requestAccessibility() -> Bool {
        // `kAXTrustedCheckOptionPrompt: true` ist der Unterschied zwischen "prüfen" und
        // "anfordern" — nur damit zeigt macOS den Dialog und nimmt TypeLess in die Liste auf.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
```

In `AppState.swift` direkt unter `requestInputMonitoring()`:

```swift
    /// Fordert die Bedienungshilfen an und aktualisiert sofort die Anzeige — beim Programmstart
    /// aufzurufen. Ohne dieses Recht kann TypeLess nie direkt einfügen; es fällt dann immer auf
    /// die Zwischenablage zurück (ausführliche Begründung bei
    /// ``PermissionsService/requestAccessibility()``).
    public func requestAccessibility() {
        permissionsService.requestAccessibility()
        refreshPermissions()
    }

    /// Ohne Bedienungshilfen kann TypeLess Text nie direkt einfügen — es landet dann IMMER in der
    /// Zwischenablage. Die App bleibt voll benutzbar, aber sie darf nicht so tun, als sei alles
    /// in Ordnung (Lektion M4: „Bereit", während der Hotkey tot war).
    public var einfuegenBrauchtBedienungshilfen: Bool {
        !permissions.accessibility
    }
```

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

```bash
cd apps/macos && swift test --filter bedienungshilfenWerdenAktivAngefordert
```
Erwartung: PASS.

- [ ] **Schritt 5: Mutationsprobe**

In `AppState.requestAccessibility()` die Zeile `permissionsService.requestAccessibility()`
auskommentieren, Test erneut laufen lassen → muss **rot** werden (schnell, nicht hängen).
Wiederherstellen → grün. Beide Läufe mit Laufzeit im Bericht festhalten.

- [ ] **Schritt 6: Volle Suite + Commit**

```bash
cd apps/macos && swift build 2>&1 | grep -i warning ; swift test
git add -A
git commit -m "M5: Bedienungshilfen werden angefordert, nicht nur geprüft"
```
Erwartung: keine Warnung, 96 Tests grün.

---

## Task 2: InsertionTarget — wohin darf eingefügt werden?

Beantwortet zwei Fragen, ohne je einen Feldinhalt zu lesen: *Welche App ist vorne?* und *Steht
der Cursor in einem beschreibbaren Textfeld?*

**Dateien:**
- Erstellen: `apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/InsertionTargetTests.swift` (neu)

**Interfaces:**
- Konsumiert: nichts aus früheren Aufgaben.
- Produziert:
  - `enum Fokusziel: Sendable, Equatable { case beschreibbaresTextfeld, passwortfeld, keinTextfeld, unbekannt }`
  - `protocol InsertionTarget: Sendable { func vordersteApp() -> pid_t?; func fokusziel() -> Fokusziel }`
  - `struct AXInsertionTarget: InsertionTarget` (die echte Umsetzung)

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

Neue Datei `apps/macos/Tests/TypeLessCoreTests/InsertionTargetTests.swift`:

```swift
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
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

```bash
cd apps/macos && swift test --filter InsertionTarget
```
Erwartung: Übersetzungsfehler — `AXInsertionTarget` und `Fokusziel` gibt es nicht.

- [ ] **Schritt 3: Umsetzung**

Neue Datei `apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift`:

```swift
import AppKit
import ApplicationServices
import Foundation

/// Was hat gerade den Fokus? Entscheidet, ob TypeLess dort hineintippen darf.
public enum Fokusziel: Sendable, Equatable {
    /// Ein Textfeld, in das geschrieben werden darf — hier und nur hier wird getippt.
    case beschreibbaresTextfeld
    /// Ein Passwortfeld. TypeLess tippt dort **grundsätzlich nicht** hinein.
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
    public init() {}

    public func vordersteApp() -> pid_t? {
        // Braucht kein Sonderrecht.
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func fokusziel() -> Fokusziel {
        // Ohne Recht liefert AX gar nichts Verwertbares. Das MUSS als `.unbekannt` heraus und
        // darf niemals als "kein Textfeld" durchgehen — der Unterschied entscheidet darüber, was
        // das Menü dem Anwender erzählt.
        guard AXIsProcessTrusted() else { return .unbekannt }

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

        // Passwortfelder zuerst — in sie wird unter keinen Umständen getippt.
        if rollenName == (kAXSecureTextFieldRole as String) { return .passwortfeld }

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
```

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

```bash
cd apps/macos && swift test --filter InsertionTarget
```
Erwartung: PASS (einer der beiden rechteabhängigen Tests läuft, der andere überspringt sich —
je nachdem, ob der Testprozess die Bedienungshilfen hat).

- [ ] **Schritt 5: Mutationsprobe**

`guard AXIsProcessTrusted() else { return .unbekannt }` durch
`guard true else { return .unbekannt }` ersetzen (Prüfung faktisch deaktiviert). Ohne erteiltes
Recht muss `ohneBedienungshilfenIstDasFokuszielUnbekannt` **rot** werden. Wiederherstellen →
grün.

Läuft der Testprozess **mit** erteiltem Recht, ist dieser Test übersprungen und die Mutation
nicht beobachtbar. Das ist dann **ausdrücklich so zu berichten** („nicht geprüft, weil Recht
vorhanden") — nicht stillschweigend übergehen.

- [ ] **Schritt 6: Volle Suite + Commit**

```bash
cd apps/macos && swift build 2>&1 | grep -i warning ; swift test
git add -A
git commit -m "M5: InsertionTarget — fragt über AX, wohin eingefügt werden darf (liest nie Inhalte)"
```

---

## Task 3: TextInserter — Text als Tastatur-Ereignisse

**Dateien:**
- Erstellen: `apps/macos/Sources/TypeLessCore/Insertion/TextInserter.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/TextInserterTests.swift` (neu)

**Interfaces:**
- Konsumiert: nichts aus früheren Aufgaben.
- Produziert:
  - `enum TextInserterError: Error, Equatable { case ereignisNichtErzeugbar }`
  - `protocol TextInserter: Sendable { func insert(_ text: String) throws }`
  - `struct CGEventTextInserter: TextInserter` (echte Umsetzung)
  - `CGEventTextInserter.haeppchenGroesse` (interne Konstante `20`, im Test geprüft)

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

Neue Datei `apps/macos/Tests/TypeLessCoreTests/TextInserterTests.swift`:

```swift
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
    // Surrogatpaar schneiden, käme ein kaputtes Zeichen heraus.
    let text = "Grüße über Öl — 🎉"

    let haeppchen = CGEventTextInserter.zerlege(text)

    let zusammengesetzt = String(utf16CodeUnits: haeppchen.flatMap { $0 },
                                 count: haeppchen.flatMap { $0 }.count)
    #expect(zusammengesetzt == text, "Umlaute und Emoji müssen die Zerlegung überleben")
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
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

```bash
cd apps/macos && swift test --filter TextInserter
```
Erwartung: Übersetzungsfehler — `CGEventTextInserter` gibt es nicht.

- [ ] **Schritt 3: Umsetzung**

Neue Datei `apps/macos/Sources/TypeLessCore/Insertion/TextInserter.swift`:

```swift
import CoreGraphics
import Foundation

public enum TextInserterError: Error, Equatable {
    /// Das Tastatur-Ereignis ließ sich nicht erzeugen. Der Aufrufer weicht dann auf die
    /// Zwischenablage aus — ein Diktat darf nie verloren gehen.
    case ereignisNichtErzeugbar
}

/// Fügt Text an der Cursorposition ein, indem er Tastatur-Ereignisse erzeugt — als hätte der
/// Anwender getippt, nur in einem Rutsch.
///
/// Als Protokoll, damit der ``DictationCoordinator`` testbar bleibt, ohne dass im Testlauf
/// wirklich irgendwo Text erscheint.
public protocol TextInserter: Sendable {
    func insert(_ text: String) throws
}

/// Die echte Umsetzung über `CGEventKeyboardSetUnicodeString`.
///
/// **Warum nicht über die Zwischenablage (simuliertes ⌘V):** Ausdrückliche Entscheidung des
/// Anwenders (s. Spec). Dieser Weg lässt die Zwischenablage vollständig in Ruhe.
///
/// **Warum nicht über die AX-API (`kAXValueAttribute` setzen):** Verworfen — das überschreibt in
/// vielen Apps das GANZE Feld, statt an der Cursorposition einzufügen. AX wird ausschließlich
/// zum Fragen benutzt (s. ``AXInsertionTarget``).
public struct CGEventTextInserter: TextInserter {
    /// Ein `CGEvent` nimmt nur begrenzt viele UTF-16-Einheiten auf. Längerer Text wird sonst
    /// **stillschweigend abgeschnitten** — das Diktat wäre teilweise weg, ohne jede Fehlermeldung.
    static let haeppchenGroesse = 20

    public init() {}

    public func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard let quelle = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInserterError.ereignisNichtErzeugbar
        }

        for haeppchen in Self.zerlege(text) {
            guard let runter = CGEvent(keyboardEventSource: quelle, virtualKey: 0, keyDown: true),
                  let hoch = CGEvent(keyboardEventSource: quelle, virtualKey: 0, keyDown: false)
            else { throw TextInserterError.ereignisNichtErzeugbar }

            // `virtualKey: 0` plus gesetzter Unicode-String: Das System nimmt den String, nicht
            // den Tastencode — so lässt sich beliebiger Text einfügen, unabhängig vom
            // Tastaturlayout des Anwenders.
            runter.keyboardSetUnicodeString(stringLength: haeppchen.count,
                                            unicodeString: haeppchen)
            hoch.keyboardSetUnicodeString(stringLength: haeppchen.count, unicodeString: haeppchen)

            runter.post(tap: .cgAnnotatedSessionEventTap)
            hoch.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Zerlegt den Text in Häppchen von höchstens ``haeppchenGroesse`` UTF-16-Einheiten — **ohne
    /// je ein Surrogatpaar zu zerschneiden**.
    ///
    /// Emoji und viele Sonderzeichen belegen zwei UTF-16-Einheiten (Surrogatpaar). Ein naives
    /// Zerlegen nach genau 20 Einheiten kann mitten hindurchschneiden; die beiden Hälften wären
    /// dann für sich genommen ungültiges UTF-16, und statt des Zeichens erschiene Müll. Deshalb
    /// wird ein Häppchen lieber eine Einheit kürzer, als ein Paar zu trennen.
    static func zerlege(_ text: String) -> [[UInt16]] {
        let einheiten = Array(text.utf16)
        var haeppchen: [[UInt16]] = []
        var start = 0

        while start < einheiten.count {
            var ende = min(start + haeppchenGroesse, einheiten.count)
            // Endet das Häppchen auf der ERSTEN Hälfte eines Surrogatpaars, eine Einheit
            // zurückgehen — das Paar wandert dann vollständig ins nächste Häppchen.
            if ende < einheiten.count, UTF16.isLeadSurrogate(einheiten[ende - 1]) {
                ende -= 1
            }
            haeppchen.append(Array(einheiten[start..<ende]))
            start = ende
        }
        return haeppchen
    }
}
```

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

```bash
cd apps/macos && swift test --filter TextInserter
```
Erwartung: PASS, 5 Tests.

- [ ] **Schritt 5: Mutationsprobe**

Den Surrogat-Schutz entfernen (die drei Zeilen `if ende < einheiten.count, UTF16.isLeadSurrogate…`
löschen). `surrogatpaarWirdNichtZerschnitten` **und** `umlauteUndEmojiBleibenIntakt` müssen
**rot** werden. Wiederherstellen → grün.

- [ ] **Schritt 6: Volle Suite + Commit**

```bash
cd apps/macos && swift build 2>&1 | grep -i warning ; swift test
git add -A
git commit -m "M5: TextInserter — Text als Tastatur-Ereignisse, ohne Zwischenablage"
```

---

## Task 4: Der Koordinator stellt zu — die vier Bedingungen

Das Herzstück. Hier fällt die M4-Regel, und hier entsteht der neue Zustand.

**Dateien:**
- Ändern: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Konsumiert (aus Task 2 und 3): `InsertionTarget` mit `vordersteApp() -> pid_t?` und
  `fokusziel() -> Fokusziel`; `Fokusziel` mit den Fällen `.beschreibbaresTextfeld`,
  `.passwortfeld`, `.keinTextfeld`, `.unbekannt`; `TextInserter` mit `insert(_ text: String) throws`.
- Produziert: `SessionState.inZwischenablage`; zwei neue Init-Parameter am
  `DictationCoordinator` (`inserter:`, `target:`).

- [ ] **Schritt 1: Die fehlschlagenden Tests schreiben**

Ans Ende von `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift` anhängen —
zuerst die Attrappen:

```swift
// MARK: - Attrappen für M5

/// Steuerbare Antwort auf „wohin darf eingefügt werden?".
final class FakeTarget: InsertionTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var app: pid_t?
    private var ziel: Fokusziel

    init(app: pid_t? = 42, ziel: Fokusziel = .beschreibbaresTextfeld) {
        self.app = app
        self.ziel = ziel
    }

    /// Simuliert, dass der Anwender in eine ANDERE App gewechselt ist.
    func wechsleApp(zu neue: pid_t?) { lock.lock(); app = neue; lock.unlock() }
    func setzeZiel(_ neues: Fokusziel) { lock.lock(); ziel = neues; lock.unlock() }

    func vordersteApp() -> pid_t? { lock.lock(); defer { lock.unlock() }; return app }
    func fokusziel() -> Fokusziel { lock.lock(); defer { lock.unlock() }; return ziel }
}

/// Schreibt nur mit, was getippt WORDEN WÄRE — im Test erscheint nirgends echter Text.
final class SpyInserter: TextInserter, @unchecked Sendable {
    private let lock = NSLock()
    private var _getippt: [String] = []
    private let fehler: TextInserterError?

    init(fehler: TextInserterError? = nil) { self.fehler = fehler }

    var getippt: [String] { lock.lock(); defer { lock.unlock() }; return _getippt }

    func insert(_ text: String) throws {
        if let fehler { throw fehler }
        lock.lock(); _getippt.append(text); lock.unlock()
    }
}
```

`makeCoordinator(...)` in derselben Datei um die zwei neuen Parameter erweitern (bestehende
Parameter unverändert lassen, damit alle vorhandenen Tests weiterlaufen):

```swift
@MainActor
func makeCoordinator(hotkey: HotkeyMonitor, recorder: AudioRecorder,
                     client: SidecarClient, pasteboard: Pasteboard,
                     inserter: TextInserter = SpyInserter(),
                     target: InsertionTarget = FakeTarget(),
                     keyDownCounter: KeyDownCounter = FakeKeyDownCounter(),
                     aufnahmeObergrenze: Duration = .seconds(120)) -> DictationCoordinator {
    DictationCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                         pasteboard: pasteboard, inserter: inserter, target: target,
                         aufnahmeObergrenze: aufnahmeObergrenze,
                         keyDownCounter: keyDownCounter)
}
```

> **Hinweis an den Umsetzer:** Die bestehende `makeCoordinator`-Signatur in der Datei kann von
> der hier gezeigten leicht abweichen (Parameter aus M4). **Bestehende Parameter nicht
> entfernen** — nur `inserter:` und `target:` mit Defaults ergänzen, damit die ~30 vorhandenen
> Tests unverändert grün bleiben.

Dann die acht Tests aus der Spec:

```swift
@MainActor
@Test(.timeLimit(.minutes(1)))
func normalfallTipptDirektUndLaesstDieZwischenablageInRuhe() async throws {
    // Der Fall, für den M5 gebaut wird — und die wichtigste Zusicherung des Anwenders:
    // "Diktieren und Kopieren dürfen sich nicht gegenseitig stören."
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Guten Morgen.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(inserter.getippt == ["Guten Morgen."], "der Text muss direkt eingefügt werden")
    #expect(pasteboard.geschrieben.isEmpty,
            "die Zwischenablage bleibt im Normalfall UNANGETASTET — Entscheidung des Anwenders")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func appWechselWaehrendDerVerarbeitungVerhindertDasTippen() async throws {
    // Der gefährlichste Fall: Zwischen Loslassen und fertigem Text vergehen ~6 s. Klickt der
    // Anwender in dieser Zeit in ein anderes Fenster, würde ungeprüftes Tippen sein Diktat in
    // einen Slack-Chat oder ein Suchfeld schreiben.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Geheimer Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    // Der Anwender klickt woanders hin, WÄHREND verarbeitet wird.
    target.wechsleApp(zu: 99)
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty, "NIEMALS in ein fremdes Fenster tippen")
    #expect(pasteboard.geschrieben == ["Geheimer Text."],
            "der Text darf nicht verloren gehen — er landet in der Zwischenablage")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func ohneTextfeldImFokusWirdNichtGetippt() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .keinTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty, "ohne Textfeld gibt es keinen Ort zum Tippen")
    #expect(pasteboard.geschrieben == ["Text."])

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func inEinPasswortfeldWirdNiemalsGetippt() async throws {
    // Sicherheitsregel, nicht verhandelbar.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .passwortfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty, "in ein Passwortfeld tippt TypeLess GRUNDSÄTZLICH nicht")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func ohneBedienungshilfenWirdNichtGetippt() async throws {
    // `.unbekannt` heißt: Das Recht fehlt, TypeLess kann es nicht wissen. Dann wird nicht
    // geraten — würde getippt, käme nichts an, und das Diktat wäre spurlos weg.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .unbekannt)
    let client = DictationClient(ergebnis: .success(ergebnis("Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty)
    #expect(pasteboard.geschrieben == ["Text."], "ohne Recht ist die Zwischenablage der einzige Weg")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func scheiterndesTippenVerliertDasDiktatNicht() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter(fehler: .ereignisNichtErzeugbar)
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Wichtiger Text.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(pasteboard.geschrieben == ["Wichtiger Text."],
            "ein Diktat darf NIE verloren gehen — auch nicht, wenn das Tippen scheitert")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func engineFehlerLaesstDieZwischenablageUnangetastet() async throws {
    // Die M4-Regel, die BLEIBT: Bei einem echten Fehler ist der alte Inhalt der Zwischenablage
    // besser als Leere.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let client = DictationClient(ergebnis: .failure(.unreachable))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard, inserter: inserter)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { true } else { false } }

    #expect(pasteboard.geschrieben.isEmpty, "bei einem echten Fehler bleibt sie unangetastet")
    #expect(inserter.getippt.isEmpty)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func jedesDiktatPruftSeinenEigenenGemerktenFokus() async throws {
    // Die GEFALLENE M4-Regel. In M4 galt: "Die Zwischenablage bekommt JEDES Ergebnis, auch das
    // einer überholten Verarbeitung." Mit automatischem Einfügen wäre das fatal — ein überholtes
    // Diktat würde in das Fenster tippen, in dem der Anwender INZWISCHEN steht.
    //
    // Neu: Jedes Diktat merkt sich beim Fn-Druck SEINE Ziel-App und prüft beim Zustellen genau
    // diese. Hier: Das erste Diktat wird in App 42 gesprochen; danach wechselt der Anwender in
    // App 99 und diktiert dort erneut. Das erste Ergebnis darf NICHT in App 99 getippt werden.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let inserter = SpyInserter()
    let target = FakeTarget(app: 42, ziel: .beschreibbaresTextfeld)
    let client = DictationClient(ergebnis: .success(ergebnis("Erstes Diktat.")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard,
                                      inserter: inserter, target: target)
    await coordinator.start()

    // Erstes Diktat in App 42.
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    // Anwender wechselt die App, BEVOR das Ergebnis eintrifft.
    target.wechsleApp(zu: 99)
    hotkey.send(.released)
    await warteBis { coordinator.session == .inZwischenablage }

    #expect(inserter.getippt.isEmpty,
            "das Diktat aus App 42 darf niemals in App 99 getippt werden")
    #expect(pasteboard.geschrieben == ["Erstes Diktat."])

    await coordinator.stop()
}
```

- [ ] **Schritt 2: Tests laufen lassen, Fehlschlag bestätigen**

```bash
cd apps/macos && swift test --filter DictationCoordinator
```
Erwartung: Übersetzungsfehler — `SessionState.inZwischenablage` und die Init-Parameter
`inserter:`/`target:` gibt es nicht.

- [ ] **Schritt 3: Umsetzung — neuer Zustand**

In `DictationCoordinator.swift` das `SessionState`-Enum erweitern:

```swift
public enum SessionState: Sendable, Equatable {
    case idle
    case recording
    case processing
    /// Der Text ist fertig, konnte aber nicht sicher direkt eingefügt werden — er liegt in der
    /// Zwischenablage, ⌘V holt ihn.
    ///
    /// **Kein Fehler.** Alles hat funktioniert; nur eine der vier Bedingungen fürs direkte
    /// Einfügen war nicht erfüllt (andere App im Vordergrund, kein Textfeld im Fokus,
    /// Passwortfeld, oder die Bedienungshilfen fehlen). Ein eigener Fall und **nicht** `.failed`,
    /// weil das Menü sonst ein Warnzeichen zeigte, wo nichts schiefging — und weil der Anwender
    /// genau wissen soll, dass jetzt ⌘V dran ist.
    case inZwischenablage
    /// Der letzte Fehlschlag, im Klartext — sichtbar bis zum nächsten Diktat.
    case failed(String)
}
```

- [ ] **Schritt 4: Umsetzung — Abhängigkeiten und gemerkter Fokus**

Neue gespeicherte Eigenschaften (bei den anderen, oberhalb von `init`):

```swift
    private let inserter: TextInserter
    private let target: InsertionTarget

    /// Die App, die beim Fn-Druck vorne war — das ZIEL dieses Diktats.
    ///
    /// Wird bei **jedem** `.pressed` neu gelesen und mit dem jeweiligen Diktat mitgereicht (s.
    /// `verarbeite`). Entscheidend ist, dass jede Verarbeitung ihren EIGENEN Wert prüft und nicht
    /// den der jüngsten: Zwischen Loslassen und fertigem Text vergehen ~6 s, in denen der
    /// Anwender längst woanders sein kann.
    private var zielAppBeimDruck: pid_t?
```

`init` um die zwei Parameter erweitern (die bestehenden bleiben unverändert; Defaults, damit
Aufrufer nicht brechen):

```swift
    public init(hotkey: HotkeyMonitor,
                recorder: AudioRecorder,
                client: SidecarClient,
                pasteboard: Pasteboard,
                inserter: TextInserter = CGEventTextInserter(),
                target: InsertionTarget = AXInsertionTarget(),
                minimumSampleCount: Int = 4_800,
                beendenZeitlimit: Duration = .seconds(10),
                beendenPollIntervall: Duration = .milliseconds(20),
                aufnahmeObergrenze: Duration = .seconds(120),
                keyDownCounter: KeyDownCounter = SystemKeyDownCounter()) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.client = client
        self.pasteboard = pasteboard
        self.inserter = inserter
        self.target = target
        self.minimumSampleCount = minimumSampleCount
        self.beendenZeitlimit = beendenZeitlimit
        self.beendenPollIntervall = beendenPollIntervall
        self.aufnahmeObergrenze = aufnahmeObergrenze
        self.keyDownCounter = keyDownCounter
    }
```

In `handlePressed()` den Fokus merken — **direkt nach** dem Lesen des Tastendruck-Zählers
(`zaehlerBeimDruck = keyDownCounter.aktuellerStand()`), also so früh wie möglich:

```swift
        // M5: Ziel-App so früh wie möglich merken — jetzt steht der Cursor noch dort, wo der
        // Anwender diktieren will. Beim Zustellen (in ~6 s) wird dagegen geprüft.
        zielAppBeimDruck = target.vordersteApp()
```

- [ ] **Schritt 5: Umsetzung — die Zustellung**

`verarbeite(_:)` bekommt die Ziel-App mitgereicht. Der Aufruf in `handleReleased()` wird zu:

```swift
        session = .processing
        verarbeite(samples, zielApp: zielAppBeimDruck)
```

`verarbeite` und `beendeVerarbeitung` umbauen. Der bestehende ausführliche Kommentar über das
**starke** Fangen von `pasteboard` und das **schwache** Fangen von `self` bleibt gültig und muss
erhalten bleiben — `inserter` und `target` werden aus demselben Grund ebenfalls **stark**
gefangen:

```swift
    /// Ergebnis einer Zustellung — was ist mit dem fertigen Text tatsächlich passiert?
    private enum Zustellung: Equatable {
        case eingefuegt
        case inZwischenablage
        case fehler(String)
    }

    private func verarbeite(_ samples: [Float], zielApp: pid_t?) {
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let id = UUID()
        juengsteVerarbeitung = id

        // `pasteboard`, `inserter` und `target` bewusst STARK gefangen, `self` dagegen SCHWACH
        // (s. ausführliche Begründung unten): Der Koordinator kann verschwinden, während diese
        // Verarbeitung noch läuft. `zielApp` ist ein WERT und wird mitgereicht — genau das macht
        // die neue Regel aus: Jede Verarbeitung prüft IHREN eigenen gemerkten Fokus, nicht den
        // der jüngsten.
        let task = Task { [weak self, client, pasteboard, inserter, target] in
            do {
                let ergebnis = try await client.process(pcm: pcm, mode: .diktat, language: nil)

                // `refined: false` heißt: Das LLM ist ausgefallen, der Text ist trotzdem da.
                // Das ist KEIN Fehler (M2-Vertrag) — ein Diktat geht nie verloren.
                let zustellung = Self.stelleZu(ergebnis.finalText, zielApp: zielApp,
                                               target: target, inserter: inserter,
                                               pasteboard: pasteboard)
                self?.beendeVerarbeitung(id: id, zustellung: zustellung)
            } catch {
                // Echter Fehler (Engine weg, STT-Ausfall): Zwischenablage bleibt unangetastet —
                // der alte Inhalt ist besser als Leere.
                self?.beendeVerarbeitung(id: id, zustellung: .fehler(Self.beschreibe(error)))
            }
        }
        verarbeitungen[id] = task
    }

    /// Die vier Bedingungen aus der Spec — **alle** müssen erfüllt sein, sonst Zwischenablage.
    ///
    /// Bewusst `static` und ohne `self`: Diese Entscheidung hängt AUSSCHLIESSLICH von den
    /// mitgereichten Werten ab (`zielApp` dieses Diktats), nie vom aktuellen Zustand des
    /// Koordinators. Genau das ist die gefallene M4-Regel — ein überholtes Diktat darf nicht
    /// dorthin tippen, wo der Anwender INZWISCHEN steht.
    private static func stelleZu(_ text: String,
                                 zielApp: pid_t?,
                                 target: InsertionTarget,
                                 inserter: TextInserter,
                                 pasteboard: Pasteboard) -> Zustellung {
        // Leerer Text: nichts zu tun, nichts anzufassen.
        guard !text.isEmpty else { return .eingefuegt }

        // Bedingung 2: dieselbe App wie beim Fn-Druck.
        guard let zielApp, target.vordersteApp() == zielApp else {
            pasteboard.write(text)
            return .inZwischenablage
        }

        // Bedingungen 1, 3 und 4: Recht vorhanden, beschreibbares Textfeld, kein Passwortfeld.
        // `.unbekannt` deckt den Fall "Bedienungshilfen fehlen" ab — dann wird NICHT geraten:
        // Getipptes käme nicht an, und das Diktat wäre spurlos weg.
        guard target.fokusziel() == .beschreibbaresTextfeld else {
            pasteboard.write(text)
            return .inZwischenablage
        }

        do {
            try inserter.insert(text)
            // Erfolg: Die Zwischenablage bleibt UNANGETASTET (Entscheidung des Anwenders).
            return .eingefuegt
        } catch {
            // Ein Diktat darf nie verloren gehen.
            pasteboard.write(text)
            return .inZwischenablage
        }
    }

    /// Setzt den Zustand nach einer Verarbeitung — aber **nur**, wenn sie erstens noch die
    /// JÜNGSTE ist und zweitens der Nutzer nicht inzwischen schon wieder aufnimmt.
    ///
    /// Wichtig: Diese Prüfungen betreffen ausschließlich die **Anzeige**. Über die **Zustellung**
    /// entscheiden sie nicht mehr — die ist längst passiert (s. `stelleZu`) und richtet sich nach
    /// dem Fokus, den DIESES Diktat sich gemerkt hat.
    private func beendeVerarbeitung(id: UUID, zustellung: Zustellung) {
        verarbeitungen[id] = nil
        guard id == juengsteVerarbeitung else { return }
        guard session == .processing else { return }
        switch zustellung {
        case .eingefuegt: session = .idle
        case .inZwischenablage: session = .inZwischenablage
        case let .fehler(grund): session = .failed(grund)
        }
    }
```

> **Hinweis:** Der bestehende, lange Kommentarblock in `verarbeite` (über starkes/schwaches
> Fangen und das Beenden der App) ist wertvolles Wissen aus zwei Reviews. Er ist oben aus
> Platzgründen gekürzt — **im Code bleibt er erhalten** und wird nur um `inserter`/`target`
> ergänzt.

- [ ] **Schritt 6: Tests laufen lassen, grün bestätigen**

```bash
cd apps/macos && swift test
```
Erwartung: alle Tests grün (95 bestehende + 8 neue = 103). **Alle bestehenden Tests müssen
unverändert grün bleiben** — insbesondere die, die `pasteboard.geschrieben` prüfen: Sie nutzen
die Default-`FakeTarget()` (App 42, beschreibbares Textfeld), tippen also jetzt statt zu kopieren.

> **Achtung, das ist der heikle Punkt dieser Aufgabe:** Bestehende M4-Tests, die
> `pasteboard.geschrieben == ["…"]` erwarten, werden durch M5 **fachlich falsch** — im Normalfall
> wird jetzt getippt, nicht kopiert. Sie sind entsprechend **anzupassen** (auf `inserter.getippt`
> umstellen), **nicht** zu löschen und **nicht** durch Aufweichen der Zusicherung zu retten. Jede
> solche Änderung im Bericht einzeln benennen und begründen.

- [ ] **Schritt 7: Mutationsproben (drei Stück)**

1. **App-Prüfung deaktivieren:** `guard let zielApp, target.vordersteApp() == zielApp else` →
   `guard true else`. `appWechselWaehrendDerVerarbeitungVerhindertDasTippen` und
   `jedesDiktatPruftSeinenEigenenGemerktenFokus` müssen **rot** werden.
2. **Fokusziel-Prüfung deaktivieren:** `guard target.fokusziel() == .beschreibbaresTextfeld else`
   → `guard true else`. `inEinPasswortfeldWirdNiemalsGetippt`, `ohneTextfeldImFokusWirdNichtGetippt`
   und `ohneBedienungshilfenWirdNichtGetippt` müssen **rot** werden.
3. **Zwischenablage-Rettung im `catch` entfernen** (`pasteboard.write(text)` in `stelleZu`s
   `catch`): `scheiterndesTippenVerliertDasDiktatNicht` muss **rot** werden.

Jede Probe: rot bestätigen (mit Laufzeit — **kein Hängen**), wiederherstellen, grün bestätigen.

- [ ] **Schritt 8: Volle Suite + Commit**

```bash
cd apps/macos && swift build 2>&1 | grep -i warning ; swift test
git add -A
git commit -m "M5: Koordinator stellt zu — vier Bedingungen, sonst Zwischenablage"
```

---

## Task 5: App-Schicht verdrahten — und das Menü sagt die Wahrheit

**Dateien:**
- Ändern: `apps/macos/Sources/TypeLess/TypeLessApp.swift`
- Ändern: `apps/macos/Sources/TypeLess/MenuContent.swift`

**Interfaces:**
- Konsumiert: `AppState.requestAccessibility()` und `AppState.einfuegenBrauchtBedienungshilfen`
  (Task 1); `SessionState.inZwischenablage` (Task 4); `CGEventTextInserter` (Task 3);
  `AXInsertionTarget` (Task 2).
- Produziert: nichts für spätere Aufgaben.

- [ ] **Schritt 1: Komposition**

In `TypeLessApp.swift`, in `init()`, den `DictationCoordinator` mit den echten Umsetzungen bauen
(`TypeLessApp.init` ist laut Projektkonvention die **einzige** Stelle, die konkrete Typen kennt):

```swift
        let dictation = DictationCoordinator(
            hotkey: FnKeyMonitor(),
            recorder: AVAudioEngineRecorder(),
            client: client,
            pasteboard: SystemPasteboard(),
            inserter: CGEventTextInserter(),
            target: AXInsertionTarget())
```

- [ ] **Schritt 2: Recht beim Start anfordern**

In `AppDelegate.applicationDidFinishLaunching`, **direkt neben** dem bestehenden
`state.requestInputMonitoring()`:

```swift
        // Zweites Recht, dieselbe Falle (s. requestInputMonitoring darüber): Ohne
        // Bedienungshilfen postet `CGEvent.post` klaglos ins Leere — der Text erschiene einfach
        // nicht. Anfordern, nicht nur prüfen.
        state.requestAccessibility()
```

- [ ] **Schritt 3: Menü — neuer Zustand**

In `MenuContent.swift`, in `statusText`, den neuen Fall ergänzen:

```swift
        case .inZwischenablage: "Text liegt in der Zwischenablage — ⌘V zum Einfügen"
```

In `TypeLessApp.swift`, in `symbol`, ebenfalls (kein Warnzeichen — es ist **kein** Fehler):

```swift
        case .inZwischenablage: "doc.on.clipboard"
```

- [ ] **Schritt 4: Menü — fehlendes Recht sichtbar machen**

In `MenuContent.swift`, direkt **unter** dem bestehenden Block für die fehlende
Eingabeüberwachung (dem gleichen Muster folgend):

```swift
        // Ohne Bedienungshilfen kann NIE direkt eingefügt werden — der Text landet dann immer in
        // der Zwischenablage. TypeLess bleibt voll benutzbar, aber es tut nicht so, als sei alles
        // in Ordnung (Lektion aus der M4-Handprobe: „Bereit", während der Hotkey tot war).
        if state.einfuegenBrauchtBedienungshilfen {
            Text("⚠ Bedienungshilfen fehlen — Text landet in der Zwischenablage")
            Button("   → Bedienungshilfen erlauben, dann TypeLess neu starten") {
                state.openSettings(for: .accessibility)
            }
            Divider()
        }
```

- [ ] **Schritt 5: Bauen und volle Suite**

```bash
cd apps/macos && swift build 2>&1 | grep -i warning ; swift test
```
Erwartung: keine Warnung, alle Tests grün.

- [ ] **Schritt 6: Commit**

```bash
git add -A
git commit -m "M5: App-Schicht verdrahtet — Bedienungshilfen angefordert, Menü sagt die Wahrheit"
```

---

## Handprobe (durch den Anwender, nach Task 5)

Der Umsetzer baut die App und übergibt sie mit dieser Liste. Das eigentliche Einfügen an der
Cursorposition ist **nicht** automatisiert prüfbar — es braucht echte Apps.

```bash
cd ~/Projekte/TypeLess && bash scripts/build-app.sh && open apps/macos/TypeLess.app
```

Beim ersten Start fragt macOS jetzt nach **Bedienungshilfen** — erlauben, dann TypeLess **einmal
neu starten** (das Recht greift bei macOS erst danach). Zur Erinnerung: Die Ad-hoc-Signatur
erzeugt bei jedem Neubau eine neue Identität — macOS verwirft dann **alle** erteilten Rechte, sie
müssen erneut erteilt werden. Ein echtes Zertifikat gibt es erst in M8.

| Probe | Erwartung |
|---|---|
| In Mail/Notizen in ein Textfeld klicken, diktieren | Text erscheint an der Cursorposition. **Zwischenablage unverändert** (vorher etwas kopieren und mit ⌘V prüfen!) |
| Diktieren, dann **während der Verarbeitung** in ein anderes Fenster klicken | **Nichts** wird getippt. Menü: „Text liegt in der Zwischenablage — ⌘V" |
| Diktieren, ohne vorher in ein Textfeld zu klicken | Nichts getippt, Text in der Zwischenablage |
| In ein **Passwortfeld** klicken und diktieren | Nichts getippt, Text in der Zwischenablage |
| Diktat mit Umlauten und einem Emoji | Alles kommt korrekt an, nichts abgeschnitten |
| Langes Diktat (mehrere Sätze) | Vollständig, nichts fehlt am Ende |
| Bedienungshilfen entziehen, TypeLess neu starten | Menü warnt oben; Text landet in der Zwischenablage statt zu verschwinden |
