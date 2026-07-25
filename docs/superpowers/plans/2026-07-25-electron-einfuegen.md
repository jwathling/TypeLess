# Direktes Einfügen in Electron-/Chromium-Apps — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TypeLess fügt seinen Text auch in Electron-/Chromium-Apps (Claude, Slack, VS Code, …) direkt an der Cursorposition ein, indem es deren Accessibility-Baum per `AXManualAccessibility` aktiviert — ohne die M5-Sicherheitsregeln aufzuweichen.

**Architecture:** Ein neuer „Aufwecker" setzt auf dem App-Element (per PID) das Attribut `AXManualAccessibility = true`; Chromium baut daraufhin seinen AX-Baum auf, sodass die bestehenden Fokus-/Beschreibbarkeits-/Identitätsprüfungen greifen. Geweckt wird primär beim App-Wechsel (NSWorkspace-Beobachter, damit der Baum vor dem Fn-Druck steht) und zusätzlich beim Fn-Druck (Absicherung). `stelleZu` und die fünf Bedingungen bleiben unverändert.

**Tech Stack:** Swift 6, AppKit/ApplicationServices (`AXUIElementSetAttributeValue`, `NSWorkspace`), Swift Testing.

## Global Constraints

- **Nur `AXManualAccessibility`** setzen (Chromium-spezifisch, nebenwirkungsarm) — **nicht** `AXEnhancedUserInterface` (löst bei manchen Apps Layout-Wechsel aus).
- **Setzen, nie lesen:** Die neue Weck-Operation setzt ein Bool-Attribut auf dem App-Element und liest **keinen** Feldinhalt — der Datenschutz-Grundsatz bleibt unangetastet.
- **M5 unverändert:** Die fünf Bedingungen in `stelleZu` und die Zustell-Logik werden **nicht** geändert. Der Fix macht die AX-Abfragen bei Electron nur überhaupt erst wirksam.
- **Nie Voraussetzung fürs Diktat:** Schlägt das Wecken fehl (native App, fehlende Rechte, App weg), wird der Fehler ignoriert; TypeLess verhält sich dann wie heute (Zwischenablage-Fallback).
- `TypeLessCore` darf AppKit/ApplicationServices nutzen (tut es via `AXInsertionTarget` bereits), bleibt aber frei von SwiftUI-**UI**.
- Kommentare/Docstrings auf **Deutsch** (bestehendem Stil folgen).
- Bekannte, akzeptierte Grenze: Electron-Passwortfelder ohne `AXSecureTextField`-Subrolle werden ggf. nicht als solche erkannt (in `CLAUDE.md`/Docstring benennen, nicht „lösen").

---

### Task 1: Weck-Schnittstelle + AX-Umsetzung + Fn-Druck-Weckung

Die Kern-Erweiterung: eine Weck-Methode am `InsertionTarget`, ihre echte AX-Umsetzung, das Nachziehen der Test-Attrappe, und der Aufruf beim Fn-Druck — unit-getestet.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift` (Protokoll + `AXInsertionTarget`)
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift` (`handlePressed()`)
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift` (`FakeTarget` + neuer Test)

**Interfaces:**
- Produces: `func weckeBedienungshilfen(fuer pid: pid_t)` im `InsertionTarget`-Protokoll. `AXInsertionTarget` setzt darin `AXManualAccessibility=true` auf `AXUIElementCreateApplication(pid)`; die Test-Attrappe merkt sich die PID.

- [ ] **Step 1: Protokoll-Methode ergänzen**

In `InsertionTarget.swift` das Protokoll (bei den anderen Methoden) erweitern:

```swift
    /// Fordert die App mit dieser Prozesskennung auf, ihren Bedienungshilfen-Baum zu aktivieren
    /// (Electron/Chromium bauen ihn erst auf Anforderung auf — s. Design). **Setzt nur** ein
    /// Attribut, liest nichts. Für native Apps folgenlos.
    func weckeBedienungshilfen(fuer pid: pid_t)
```

- [ ] **Step 2: `AXInsertionTarget`-Umsetzung**

In `AXInsertionTarget` (in derselben Datei) ergänzen:

```swift
    public func weckeBedienungshilfen(fuer pid: pid_t) {
        // Electron/Chromium bauen ihren AX-Baum erst, wenn eine assistive Technologie ihn
        // anfordert — genau dafür ist `AXManualAccessibility` da. Bei nativen Apps ist das Setzen
        // wirkungslos (unbekanntes Attribut). Ein Fehlschlag (fehlende Rechte, App weg) ist
        // folgenlos: dann bleibt es beim Zwischenablage-Fallback wie bisher.
        // **Datenschutz:** setzt nur, liest nichts. Bewusst NICHT `AXEnhancedUserInterface`
        // (löst bei manchen Apps Layout-Wechsel aus).
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
```

- [ ] **Step 3: `FakeTarget` (Test-Attrappe) nachziehen**

In `DictationCoordinatorTests.swift` bei `final class FakeTarget: InsertionTarget` ein Feld + die Methode ergänzen (threadsicher über den vorhandenen `lock`, im Stil der bestehenden Methoden):

```swift
    private(set) var gewecktePid: pid_t?
    func weckeBedienungshilfen(fuer pid: pid_t) { lock.lock(); gewecktePid = pid; lock.unlock() }
```

> Umsetzer-Hinweis: `FakeTarget` ist die **einzige** weitere `InsertionTarget`-Attrappe im Projekt (verifiziert per `grep -rn ": InsertionTarget"`). `InsertionTargetTests.swift` prüft `AXInsertionTarget` direkt und braucht keine Attrappe. Sollte der Build dennoch einen weiteren fehlenden Konformer melden, ziehe ihn mit einer leeren/merkenden Umsetzung nach.

- [ ] **Step 4: Fehlschlagenden Test schreiben**

An `DictationCoordinatorTests.swift` anhängen — dockt an den bestehenden Fn-Druck-Aufbau an (der Umsetzer nutzt exakt das Muster, mit dem andere Tests ein `.pressed` auslösen und `FakeTarget.app` setzen):

```swift
    @Test func fnDruckWecktDieVordersteApp() async {
        // FakeTarget mit vorderster App-PID 4242; ein Fn-Druck (.pressed) auslösen wie in den
        // bestehenden Tests. Erwartung: target.gewecktePid == 4242.
    }
```

> Umsetzer-Hinweis: Fülle die Probe mit dem konkreten Aufbau der Datei (FakeTarget mit gesetzter `app`-PID, Auslösen eines `.pressed` über denselben Hotkey-/Signal-Weg wie die vorhandenen `handlePressed`-Tests, deterministisch abwarten). Aussage: Nach dem Fn-Druck wurde die vorderste App geweckt.

- [ ] **Step 5: Test ausführen, Fehlschlag bestätigen**

Run: `cd apps/macos && swift test --filter DictationCoordinatorTests 2>&1 | tail -5`
Expected: FAIL — `gewecktePid` bleibt `nil` (der Coordinator weckt noch nicht) bzw. Kompilierfehler, bis Step 3 steht.

- [ ] **Step 6: Fn-Druck-Weckung im Coordinator**

In `handlePressed()` die Zeile `zielAppBeimDruck = target.vordersteApp()` ersetzen durch:

```swift
        // Electron-/Chromium-Apps bauen ihren AX-Baum erst auf Anforderung auf — sonst sieht die
        // Zustellung kein Feld und weicht auf die Zwischenablage aus. Die vorderste App JETZT
        // wecken (der App-Wechsel-Beobachter, s. BedienungshilfenAufwecker, tut das i. d. R. schon
        // vorher; dies deckt den Fall ab, dass die App beim TypeLess-Start bereits vorne war).
        let vorne = target.vordersteApp()
        if let vorne { target.weckeBedienungshilfen(fuer: vorne) }
        zielAppBeimDruck = vorne
```

(Die Folgezeile `fokusBeimDruck = target.fokusKennung()` bleibt unverändert direkt darunter.)

- [ ] **Step 7: Tests ausführen, Erfolg bestätigen**

Run: `cd apps/macos && swift test --filter DictationCoordinatorTests 2>&1 | tail -5`
Expected: PASS — die neue Probe grün, alle bestehenden grün.

- [ ] **Step 8: Voller Build + Suite**

Run: `cd apps/macos && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!`; Suite grün (das eine echte-Mikrofon-Hardwaretest-Ergebnis ist umgebungsabhängig — falls es scheitert, nennen, kein Task-Fehler).

- [ ] **Step 9: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Electron-Einfuegen: Weck-Schnittstelle (AXManualAccessibility) + Fn-Druck-Weckung

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: App-Wechsel-Beobachter (`BedienungshilfenAufwecker`) + Verdrahtung

Der primäre Weck-Weg: eine App, zu der der Anwender wechselt, wird sofort geweckt — so steht ihr AX-Baum, bevor Fn gedrückt wird. NSWorkspace-Beobachtung ist echte Umgebung → Handprobe, kein Unit-Test.

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Insertion/BedienungshilfenAufwecker.swift`
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift` (erzeugen, halten, starten)

**Interfaces:**
- Consumes: `InsertionTarget.weckeBedienungshilfen(fuer:)` (Task 1).
- Produces: `BedienungshilfenAufwecker(target:)` mit `starte()`.

- [ ] **Step 1: Den Aufwecker schreiben**

Datei `apps/macos/Sources/TypeLessCore/Insertion/BedienungshilfenAufwecker.swift`:

```swift
import AppKit

/// Weckt den Bedienungshilfen-Baum jeder App, zu der der Anwender wechselt — Electron/Chromium
/// bauen ihn erst auf Anforderung auf (s. Design). So ist er schon wach, bevor Fn gedrückt wird,
/// und die Fokus-/Identitätsprüfung greift beim ERSTEN Diktat. Bei nativen Apps folgenlos.
///
/// Bewusst schlank und ohne Unit-Test: reine Verdrahtung von `NSWorkspace` auf
/// ``InsertionTarget/weckeBedienungshilfen(fuer:)`` — der echte Effekt ist Handprobe.
@MainActor
public final class BedienungshilfenAufwecker {
    private let target: InsertionTarget
    private var beobachter: NSObjectProtocol?

    public init(target: InsertionTarget) { self.target = target }

    public func starte() {
        beobachter = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.target.weckeBedienungshilfen(fuer: pid) }
        }
    }

    deinit {
        if let beobachter {
            NSWorkspace.shared.notificationCenter.removeObserver(beobachter)
        }
    }
}
```

> Umsetzer-Hinweis: Der `queue: .main` garantiert, dass der Block auf dem Main-Thread läuft, daher `MainActor.assumeIsolated`. Falls der Swift-6-Compiler die Isolation im Closure anders verlangt (z. B. `Task { @MainActor in … }`), wähle die Variante, die ohne Warnung baut — die Wirkung (auf dem MainActor `weckeBedienungshilfen(fuer: pid)` aufrufen) muss dieselbe bleiben. Der `deinit`-Zugriff auf `NSWorkspace` ist nichtisoliert erreichbar; falls der Compiler meckert, den Beobachter-Token vor dem Entfernen lokal kopieren.

- [ ] **Step 2: Bauen**

Run: `cd apps/macos && swift build 2>&1 | tail -3`
Expected: `Build complete!` (kompiliert sauber, ohne Concurrency-Warnungen).

- [ ] **Step 3: In der App-Schicht verdrahten**

In `apps/macos/Sources/TypeLess/TypeLessApp.swift`: im `AppDelegate` ein Feld ergänzen und in `applicationDidFinishLaunching` erzeugen + starten (bei den anderen Start-Aufrufen). Der Aufwecker bekommt ein eigenes `AXInsertionTarget()` (die Weck-Methode ist zustandslos):

```swift
    private var aufwecker: BedienungshilfenAufwecker?
```

und in `applicationDidFinishLaunching(_:)` (nach den bestehenden Start-/Beobachter-Aufrufen):

```swift
        let aufwecker = BedienungshilfenAufwecker(target: AXInsertionTarget())
        aufwecker.starte()
        self.aufwecker = aufwecker
```

- [ ] **Step 4: Bauen + Suite**

Run: `cd apps/macos && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!`; Suite unverändert grün.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Insertion/BedienungshilfenAufwecker.swift apps/macos/Sources/TypeLess/TypeLessApp.swift
git commit -m "Electron-Einfuegen: App-Wechsel-Beobachter weckt Bedienungshilfen-Baum

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Abnahme (Handprobe) + CLAUDE.md

Der eigentliche Beweis — der echte AX-/NSWorkspace-Effekt ist nicht unit-testbar. Auf echter Hardware mit dem gebauten Bundle.

**Files:**
- Modify: `CLAUDE.md` (bekannte Grenzen aktualisieren)

- [ ] **Step 1: `CLAUDE.md` aktualisieren**

Im M5-Absatz (bekannte Grenzen des direkten Einfügens) ergänzen: Electron-/Chromium-Apps (Claude, Slack, VS Code, …) werden jetzt unterstützt, weil TypeLess ihren Bedienungshilfen-Baum per `AXManualAccessibility` aktiviert (primär beim App-Wechsel, zusätzlich beim Fn-Druck). Die bekannte Passwortfeld-Grenze **erweitern**: In Electron-Apps kann ein Passwortfeld ohne `AXSecureTextField`-Subrolle nicht als solches erkannt werden — dann würde direkt hineingetippt (bewusst akzeptiert, da sonst der Feldinhalt gelesen werden müsste).

- [ ] **Step 2: Bundle bauen**

Run: `bash scripts/build-app.sh && open apps/macos/TypeLess.app`
(Alte laufende Instanz vorher beenden.)

- [ ] **Step 3: Direktes Einfügen in Electron-Apps prüfen**

Jeweils **zuerst ins Eingabefeld klicken**, dann Fn halten, sprechen, loslassen:
- **Claude** → Text wird **direkt** eingefügt (nicht Zwischenablage).
- Eine weitere Electron-App (**VS Code** oder **Slack**) → ebenfalls direkt.
Expected: direktes Einfügen; das Overlay endet mit „Eingefügt ✓", nicht „Fertig · ⌘V".

- [ ] **Step 4: Keine Regression bei nativen Apps + Zwischenablage-Fällen**

- **Notizen** (nativ) → weiter direkt eingefügt.
- **Terminal** → weiter Zwischenablage (dort greift kein AX-Textfeld/Secure Input; erwartet).
Expected: unverändertes Verhalten.

- [ ] **Step 5: App-Wechsel-Weg gegenprüfen**

Zu Claude **wechseln**, dann diktieren: schon der **erste** Versuch fügt direkt ein (der Aktivierungs-Beobachter hat den Baum rechtzeitig geweckt).
Expected: erster Versuch nach App-Wechsel klappt direkt.

- [ ] **Step 6: Commit + Ergebnis festhalten**

```bash
git add CLAUDE.md
git commit -m "Electron-Einfuegen: CLAUDE.md — Electron unterstuetzt, Passwortfeld-Grenze erweitert

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
Ergebnis (bestanden/Befund) im Ledger notieren. Bei einem Fehlbefund (Claude bleibt Zwischenablage) zurück in Task 1/2 zur Ursachenklärung.

---

## Selbst-Review (gegen die Spec)

**Spec-Abdeckung:**
- `AXManualAccessibility` setzen (nur dieses, nicht `AXEnhancedUserInterface`) → Task 1 Step 2. ✅
- Wecken beim App-Wechsel (NSWorkspace-Beobachter) → Task 2. ✅
- Wecken beim Fn-Druck (Absicherung) → Task 1 Step 6. ✅
- M5-Bedingungen/`stelleZu` unverändert → keine Task fasst sie an. ✅
- Datenschutz (setzen, nie lesen) → Task 1 Step 2 (Kommentar + Umsetzung). ✅
- Nie Voraussetzung fürs Diktat (Fehler ignoriert) → `AXUIElementSetAttributeValue`-Rückgabe wird nicht ausgewertet; Aufwecker-Ausfall lässt den Fluss unberührt. ✅
- Passwortfeld-Grenze benennen → Task 3 Step 1 (CLAUDE.md). ✅
- Handproben-Abnahme (Claude/VS Code/Slack direkt, Notizen ok, Terminal Zwischenablage, App-Wechsel-Weg) → Task 3. ✅

**Platzhalter-Scan:** Die Testprobe in Task 1 ist ein Gerüst mit präziser Erwartung + Umsetzer-Hinweis (dockt an die realen, hier nicht duplizierten Fakes/Signale der bestehenden `DictationCoordinatorTests.swift` an) — kein „TBD". Produktivcode vollständig ausformuliert.

**Typ-/Namenskonsistenz:** `weckeBedienungshilfen(fuer:)` identisch über Protokoll (Task 1 Step 1), `AXInsertionTarget` (Step 2), `FakeTarget` (Step 3), Coordinator-Aufruf (Step 6) und `BedienungshilfenAufwecker` (Task 2). `AXManualAccessibility` als exakter Attribut-String durchgängig.
