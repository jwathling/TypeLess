# Diktat abbrechen — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein laufendes Diktat lässt sich während der Verarbeitung (~6 s nach dem Loslassen) mit Escape abbrechen, sodass der Text nicht im Feld landet und die Zwischenablage unberührt bleibt.

**Architecture:** Escape wird über `RegisterEventHotKey` (Carbon) angemeldet — das **liest keine Tasten mit**, im Gegensatz zu einem `CGEventTap`, und ist deshalb der einzige datenschutzkonforme Weg. Der Hotkey ist **nur registriert, solange `session == .processing`**, sonst wäre Escape systemweit blockiert. Die Kopplung erfolgt über **eine idempotente Methode**, die den Ist-Zustand prüft statt Übergänge zu zählen — sonst bliebe der Hotkey in den Pfaden hängen, in denen `.processing` verlassen wird, ohne dass `beendeVerarbeitung` läuft. Der Abbruch selbst ist `Task.cancel()`; der Transport ist darauf vorbereitet.

**Tech Stack:** Swift 6, SwiftUI-Shell (`apps/macos`), Swift Testing (`@Test`/`#expect`, **nicht** XCTest), Carbon (`RegisterEventHotKey`/`InstallEventHandler`).

**Spec:** `docs/superpowers/specs/2026-07-26-diktat-abbrechen-design.md`

## Global Constraints

- **Kommentare und Doku auf Deutsch**, bestehendem Stil folgen (begründend, nicht beschreibend).
- Alle Tests mit **Swift Testing** (`@Test`, `#expect`), nicht XCTest.
- **Die Event-Maske des Fn-Taps bleibt ausschließlich `.flagsChanged`.** Sie um `.keyDown` zu erweitern wäre ein Datenschutzbruch (M4-Regel). Dieser Plan fasst den Fn-Tap **überhaupt nicht** an — der Abbruch-Hotkey ist ein davon völlig getrennter Mechanismus.
- **`CGEventTextInserter.postTap` bleibt `.cgAnnotatedSessionEventTap`** — nicht anfassen.
- **In Tests nie die echten `CGEventTextInserter`/`AXInsertionTarget`/`SystemAbbruchHotkey`** als Coordinator-Abhängigkeit — sonst tippt ein Testlauf echten Text bzw. registriert einen echten systemweiten Hotkey. Immer die Attrappen.
- **Der Abbruch ist kein Fehler:** `session` endet auf `.idle`, nicht `.failed`; Overlay zeigt `.abgebrochen`, nicht `.fehler`.
- **Bei Abbruch bleibt die Zwischenablage unangetastet** — der Anwender will diesen Text ausdrücklich nicht.
- Bauen und testen aus `apps/macos`: `swift build && swift test`. Einzelprobe: `swift test --filter <TestName>`.
- Vor jedem Commit muss `swift test` **vollständig grün** sein. Ausgangslage: **151 Proben**.
- **Kein `git stash`** — der Stash-Stapel ist mit anderen Sitzungen geteilt.

## Ausgangslage im Code (bereits vorhanden, nicht neu bauen)

- `OverlayZustand.abgebrochen` **existiert schon** (aus der Einfach-tippen-Umsetzung), inklusive Zweig in `apps/macos/Sources/TypeLess/OverlayWindow.swift` und der Dauer `dauerAbgebrochen` (Default `.milliseconds(1500)`) im `DictationCoordinator`-Init. Hier nur mitbenutzen.
- `verarbeite(_ samples: [Float], zielApp: pid_t?)` (`DictationCoordinator.swift:539`) erzeugt `let id = UUID()`, setzt `juengsteVerarbeitung = id`, startet `Task { [weak self, client, pasteboard, inserter, target] in … }` und legt sie in `verarbeitungen[id]` ab. Im `do`-Zweig: `client.process(...)` → `Self.stelleZu(...)` → `beendeVerarbeitung(id:zustellung:)`. Im `catch`: `beendeVerarbeitung(id:, zustellung: .fehler(Self.beschreibe(error)))`.
- `beendeVerarbeitung(id:zustellung:)` (`:684`) hat **zwei früh zurückkehrende Guards**: `guard id == juengsteVerarbeitung` und `guard session == .processing`.
- `private enum Zustellung` (`:526`): `.eingefuegt`, `.inZwischenablage(text:)`, `.nichtsErkannt`, `.fehler(String)`.
- `session = .processing` wird an genau einer Stelle gesetzt: `handleReleased()`, `DictationCoordinator.swift:518`.
- Test-Attrappe für den Fn-Hotkey heißt `FakeHotkey` und liegt in `Tests/TypeLessCoreTests/HotkeyMonitorTests.swift`; Ereignisse werden mit **`send(.pressed)` / `send(.released)`** geschickt (**nicht** `druecke()`).
- Hilfsfunktionen im Testfile: `warteBis { … }`, `warteBisMitEchterZeit { … }`, `sprache()`, `ergebnis(_:)`, `makeCoordinator(hotkey:recorder:client:pasteboard:inserter:target:keyDownCounter:aufnahmeObergrenze:)`, `SpyPasteboard.geschrieben`, `SpyInserter.getippt`, `FakeTarget(app:bedienungshilfen:sichereEingabe:passwortfeld:)`.
- **`GatedDictationClient`** (torgesteuert) hat ein **parameterloses** `init()`; das Ergebnis wird erst bei der Freigabe übergeben: `freigeben(mit: .success(ergebnis("Text")))`. Die Freigabe ist **FIFO** — bei zwei wartenden Verarbeitungen löst der erste Aufruf die **ältere** auf. Wichtig: `process` hängt dort in `withCheckedContinuation`, das auf `cancel()` **nicht** reagiert; eine abgebrochene Verarbeitung läuft erst weiter, wenn sie freigegeben wird — dann greift der `isCancelled`-Check. Proben müssen nach dem Abbruch also trotzdem freigeben.

---

### Task 1: `AbbruchHotkey` — Protokoll, Carbon-Umsetzung, Attrappe

Rein additiv: Der Koordinator benutzt noch nichts davon, alles kompiliert und die 151 Proben bleiben grün.

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Hotkey/AbbruchHotkey.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/AbbruchHotkeyTests.swift`

**Interfaces:**
- Consumes: nichts (erste Task)
- Produces:
  - `protocol AbbruchHotkey: Sendable` mit `func registriere(_ beiDruck: @escaping @Sendable () -> Void)` und `func gibFrei()`
  - `final class SystemAbbruchHotkey: AbbruchHotkey` (Carbon, Escape)
  - `final class FakeAbbruchHotkey: AbbruchHotkey` mit `istRegistriert: Bool`, `registrierungen: Int`, `freigaben: Int`, `druecke()`

- [ ] **Step 1: Die Attrappe und ihre Proben schreiben**

Der echte `SystemAbbruchHotkey` lässt sich nicht sinnvoll unit-testen — er würde einen echten systemweiten Hotkey anmelden. Getestet wird deshalb der **Vertrag** an der Attrappe; die echte Registrierung ist Handprobe (so wie bei `CGEventTextInserter`).

Neue Datei `apps/macos/Tests/TypeLessCoreTests/AbbruchHotkeyTests.swift`:

```swift
import Testing
@testable import TypeLessCore

/// Steuerbarer Abbruch-Hotkey: Der Test entscheidet, wann „Escape" gedrückt wird.
///
/// Bewusst eine Attrappe und **nie** `SystemAbbruchHotkey` in Koordinator-Proben: Der echte Typ
/// meldet einen systemweiten Hotkey an — ein Testlauf würde dem ganzen Rechner Escape wegnehmen.
final class FakeAbbruchHotkey: AbbruchHotkey, @unchecked Sendable {
    private let lock = NSLock()
    private var beiDruck: (@Sendable () -> Void)?
    private var _registrierungen = 0
    private var _freigaben = 0

    var istRegistriert: Bool { lock.lock(); defer { lock.unlock() }; return beiDruck != nil }
    var registrierungen: Int { lock.lock(); defer { lock.unlock() }; return _registrierungen }
    var freigaben: Int { lock.lock(); defer { lock.unlock() }; return _freigaben }

    func registriere(_ beiDruck: @escaping @Sendable () -> Void) {
        lock.lock(); self.beiDruck = beiDruck; _registrierungen += 1; lock.unlock()
    }

    func gibFrei() {
        lock.lock(); beiDruck = nil; _freigaben += 1; lock.unlock()
    }

    /// Der Test drückt Escape. Folgenlos, wenn nicht registriert — genau wie beim echten Hotkey.
    func druecke() {
        lock.lock(); let cb = beiDruck; lock.unlock()
        cb?()
    }
}

@Test
func dieAttrappeMeldetIhrenRegistrierungszustand() {
    let hotkey = FakeAbbruchHotkey()
    #expect(hotkey.istRegistriert == false)

    hotkey.registriere {}
    #expect(hotkey.istRegistriert)
    #expect(hotkey.registrierungen == 1)

    hotkey.gibFrei()
    #expect(hotkey.istRegistriert == false)
    #expect(hotkey.freigaben == 1)
}

@Test
func einDruckOhneRegistrierungIstFolgenlos() {
    // Wichtig für die Koordinator-Proben: Escape außerhalb einer Verarbeitung darf nichts tun.
    // Die Attrappe muss sich hier genauso verhalten wie der echte Hotkey, sonst prüfen die
    // Proben eine Eigenschaft, die es in der Produktion nicht gibt.
    let hotkey = FakeAbbruchHotkey()
    var gerufen = 0
    hotkey.registriere { gerufen += 1 }
    hotkey.gibFrei()

    hotkey.druecke()

    #expect(gerufen == 0, "nach der Freigabe darf der Callback nicht mehr laufen")
}
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `cd apps/macos && swift test --filter dieAttrappeMeldetIhrenRegistrierungszustand`
Expected: Compile-Fehler — `AbbruchHotkey` existiert nicht.

- [ ] **Step 3: Protokoll und Carbon-Umsetzung schreiben**

Neue Datei `apps/macos/Sources/TypeLessCore/Hotkey/AbbruchHotkey.swift`:

```swift
@preconcurrency import Carbon
import Foundation

/// Meldet eine **einzelne** Tastenkombination beim System an und ruft zurück, wenn sie gedrückt
/// wird — der Auslöser für den Abbruch eines laufenden Diktats.
///
/// **Warum nicht über den bestehenden `CGEventTap`:** Der Tap müsste dafür `.keyDown` mitlesen,
/// also **jeden** Tastendruck des Anwenders sehen. Das ist ein Datenschutzbruch und durch die
/// M4-Regel ausgeschlossen (die Maske bleibt ausschließlich `.flagsChanged`). `RegisterEventHotKey`
/// ist das Gegenteil: Es sieht ausschließlich die angemeldete Kombination, alle anderen
/// Tastendrücke bleiben unsichtbar.
///
/// Als Protokoll, damit der ``DictationCoordinator`` ohne echte systemweite Registrierung prüfbar
/// bleibt — gleiche Bauart wie ``Pasteboard``, ``TextInserter``, ``InsertionTarget``.
public protocol AbbruchHotkey: Sendable {
    /// Meldet die Kombination an. Mehrfach aufrufbar: Eine bereits bestehende Registrierung wird
    /// dabei ersetzt, nicht verdoppelt.
    func registriere(_ beiDruck: @escaping @Sendable () -> Void)

    /// Gibt die Kombination wieder frei. Mehrfach aufrufbar und ohne bestehende Registrierung
    /// folgenlos — der Aufrufer synchronisiert nach Zustand, nicht nach Übergängen.
    func gibFrei()
}

/// Die echte Umsetzung über Carbon: **Escape**.
///
/// **Warum nur zeitweise registriert:** Solange die Kombination angemeldet ist, bekommt **keine**
/// andere App Escape zu sehen. Ein dauerhaft registriertes Escape würde den Rechner unbenutzbar
/// machen (jeder Dialog, jedes Sheet). Deshalb registriert der ``DictationCoordinator`` nur für die
/// Dauer einer laufenden Verarbeitung — s. dort.
///
/// **Nicht unit-getestet, bewusst:** Ein Test würde dem ganzen Rechner Escape wegnehmen. Geprüft
/// wird der Vertrag an ``FakeAbbruchHotkey``; diese Umsetzung ist Handprobe (gleiche Abwägung wie
/// bei ``CGEventTextInserter``).
public final class SystemAbbruchHotkey: AbbruchHotkey, @unchecked Sendable {
    /// Virtueller Tastencode von Escape (`kVK_Escape`). Als benannte Konstante, damit der Wert
    /// nicht als magische Zahl im Registrierungsaufruf steht.
    private static let escapeKeycode: UInt32 = 53

    private let lock = NSLock()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var beiDruck: (@Sendable () -> Void)?

    public init() {}

    public func registriere(_ beiDruck: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        // Idempotent: Eine bestehende Registrierung zuerst abbauen. Ohne das sammelte jeder
        // Aufruf einen weiteren Handler an, und `gibFrei()` räumte nur den letzten weg.
        gibFreiOhneLock()
        self.beiDruck = beiDruck

        var eventTyp = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        // `Unmanaged` als Brücke in den C-Callback: Carbon kennt keine Swift-Closures. Die
        // Referenz wird NICHT retained (`passUnretained`) — dieser Typ überlebt seinen Handler,
        // weil `gibFrei()` ihn vor der Freigabe des Objekts abbaut.
        let selbst = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, nutzerdaten in
            guard let nutzerdaten else { return noErr }
            let ich = Unmanaged<SystemAbbruchHotkey>.fromOpaque(nutzerdaten).takeUnretainedValue()
            ich.ausloesen()
            return noErr
        }, 1, &eventTyp, selbst, &handlerRef)

        // Eigene Signatur, damit diese Anmeldung nicht mit einer fremden kollidiert.
        let kennung = EventHotKeyID(signature: OSType(0x544C_4553 /* "TLES" */), id: 1)
        RegisterEventHotKey(Self.escapeKeycode, 0, kennung,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    public func gibFrei() {
        lock.lock()
        defer { lock.unlock() }
        gibFreiOhneLock()
    }

    /// Setzt voraus, dass ``lock`` gehalten wird (aus ``registriere`` und ``gibFrei``).
    private func gibFreiOhneLock() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        beiDruck = nil
    }

    /// Aus dem Carbon-Callback gerufen. Liest die Closure unter dem Lock, ruft sie aber
    /// **außerhalb** — sonst liefe der Abbruch (der wieder `gibFrei()` auslöst) in einen Deadlock.
    private func ausloesen() {
        lock.lock()
        let cb = beiDruck
        lock.unlock()
        cb?()
    }
}
```

- [ ] **Step 4: Tests laufen lassen — alle grün**

Run: `cd apps/macos && swift build && swift test`
Expected: PASS, 153 Proben (151 + 2 neue). Bestehende unberührt.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Hotkey/AbbruchHotkey.swift \
        apps/macos/Tests/TypeLessCoreTests/AbbruchHotkeyTests.swift
git commit -m "Diktat-Abbrechen: AbbruchHotkey (Protokoll, Carbon-Escape, Attrappe)"
```

---

### Task 2: Registrierung an den Zustand koppeln

Der Hotkey wird registriert, solange verarbeitet wird — und sonst nicht. Der Abbruch **wirkt** noch nicht (Task 3); hier geht es allein darum, dass Escape nie länger belegt ist als nötig.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AbbruchHotkey`, `FakeAbbruchHotkey` (Task 1)
- Produces:
  - `DictationCoordinator.init(…, abbruchHotkey: AbbruchHotkey = SystemAbbruchHotkey())`
  - `private func synchronisiereAbbruchHotkey()` — idempotent, leitet den Zustand aus `session` ab
  - `makeCoordinator(…, abbruchHotkey: AbbruchHotkey = FakeAbbruchHotkey())` im Testfile

- [ ] **Step 1: Proben schreiben**

Am Ende von `DictationCoordinatorTests.swift` anfügen:

```swift
// MARK: - Abbruch-Hotkey: Registrierung folgt dem Zustand

@MainActor
@Test(.timeLimit(.minutes(1)))
func derAbbruchHotkeyIstNurWaehrendDerVerarbeitungRegistriert() async {
    // Escape ist eine systemweit belegte Taste, solange der Hotkey angemeldet ist — jede andere
    // App bekommt sie dann nicht. Deshalb darf er ausschließlich während der Verarbeitung
    // registriert sein: nicht im Leerlauf, nicht beim Aufnehmen, und danach wieder frei.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = GatedDictationClient()
    let abbruch = FakeAbbruchHotkey()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                     pasteboard: SpyPasteboard(), abbruchHotkey: abbruch)
    await coordinator.start()
    #expect(abbruch.istRegistriert == false, "im Leerlauf muss Escape frei sein")

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    #expect(abbruch.istRegistriert == false,
            "beim Sprechen erledigt die Fn-als-Modifier-Wache den Abbruch — kein Hotkey nötig")

    hotkey.send(.released)
    await warteBis { coordinator.session == .processing }
    #expect(abbruch.istRegistriert, "während der Verarbeitung muss Escape belegt sein")

    client.freigeben(mit: .success(ergebnis("Hallo")))
    await warteBis { coordinator.session == .idle }
    #expect(abbruch.istRegistriert == false, "nach der Zustellung muss Escape wieder frei sein")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func derAbbruchHotkeyWirdAuchNachEinemFehlerFreigegeben() async {
    // Der teuerste Fehler dieser Task: ein Hotkey, der auf einem Fehlerpfad hängen bleibt. Escape
    // wäre dann bis zum Beenden der App systemweit blockiert — ohne dass der Anwender ahnt, warum.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .failure(.unreachable))
    let abbruch = FakeAbbruchHotkey()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                     pasteboard: SpyPasteboard(), abbruchHotkey: abbruch)
    await coordinator.start()
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)

    await warteBis { if case .failed = coordinator.session { return true } else { return false } }

    #expect(abbruch.istRegistriert == false, "auch nach einem Fehler muss Escape frei werden")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func einNeuesDiktatWaehrendDerVerarbeitungGibtDenHotkeyFrei() async {
    // Der Pfad, den `beendeVerarbeitung` NICHT sieht: Drückt der Anwender während der Verarbeitung
    // erneut Fn, wechselt `session` von `.processing` auf `.recording`, ohne dass eine Zustellung
    // stattfindet. Würde die Freigabe nur in `beendeVerarbeitung` stehen, blieb Escape belegt.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = GatedDictationClient()
    let abbruch = FakeAbbruchHotkey()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                     pasteboard: SpyPasteboard(), abbruchHotkey: abbruch)
    await coordinator.start()
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .processing }
    #expect(abbruch.istRegistriert)

    hotkey.send(.pressed)   // neues Diktat, alte Verarbeitung läuft weiter
    await warteBis { coordinator.session == .recording }

    #expect(abbruch.istRegistriert == false,
            "beim Wechsel zurück ins Aufnehmen muss Escape freigegeben werden")
    client.freigeben(mit: .success(ergebnis("Hallo")))   // die offene Verarbeitung auflösen
}
```

- [ ] **Step 2: Proben laufen lassen — müssen fehlschlagen**

Run: `cd apps/macos && swift test --filter derAbbruchHotkeyIstNurWaehrendDerVerarbeitungRegistriert`
Expected: Compile-Fehler — `makeCoordinator` kennt kein `abbruchHotkey`.

- [ ] **Step 3: Abhängigkeit und Synchronisierung einbauen**

In `DictationCoordinator.swift` bei den übrigen Abhängigkeiten (nach `private let target: InsertionTarget`) einfügen:

```swift
    /// Meldet Escape an, solange verarbeitet wird — der Auslöser für ``brichAb()``.
    private let abbruchHotkey: AbbruchHotkey
```

Im `init` den Parameter ergänzen (nach `target:`) und zuweisen:

```swift
                abbruchHotkey: AbbruchHotkey = SystemAbbruchHotkey(),
```
```swift
        self.abbruchHotkey = abbruchHotkey
```

Neue private Methode, sinnvoll direkt vor `beendeVerarbeitung` platziert:

```swift
    /// Hält die Escape-Registrierung im Einklang mit ``session``.
    ///
    /// **Bewusst am Ist-Zustand statt an Übergängen:** Es gibt mehrere Wege aus `.processing`
    /// heraus — die Zustellung (`beendeVerarbeitung`), ein Fehler, und ein **neues Diktat**
    /// (`handlePressed` setzt dann `.recording`, ohne dass je eine Zustellung stattfindet).
    /// Registrierte man an jedem einzelnen Übergang, bliebe Escape auf dem vergessenen Pfad
    /// systemweit belegt, bis die App beendet wird — ohne jeden Hinweis für den Anwender. Diese
    /// Methode ist deshalb idempotent und darf großzügig aufgerufen werden: Sie fragt nur, ob
    /// gerade verarbeitet wird.
    ///
    /// Während `.recording` wird **nicht** registriert: Dort verwirft die Fn-als-Modifier-Wache das
    /// Diktat schon, wenn eine Taste gedrückt wird (s. `handleReleased()`). Für den Anwender ist
    /// das Verhalten identisch — Escape bricht ab —, nur der Mechanismus unterscheidet sich.
    private func synchronisiereAbbruchHotkey() {
        if session == .processing {
            abbruchHotkey.registriere { [weak self] in
                Task { @MainActor in self?.brichAb() }
            }
        } else {
            abbruchHotkey.gibFrei()
        }
    }
```

Vorläufige `brichAb()`-Umsetzung — die Wirkung kommt in Task 3, aber ohne sie kompiliert die Closure oben nicht:

```swift
    /// Bricht die laufende Verarbeitung ab. Wirkung folgt in Task 3.
    private func brichAb() {}
```

Jetzt die **vier** Aufrufstellen. In `handleReleased()`, direkt nach `session = .processing` (`:518`) und vor `overlay = .verarbeitet`:

```swift
        synchronisiereAbbruchHotkey()
```

In `handlePressed()`, direkt nach der Zeile, die `session = .recording` setzt:

```swift
        synchronisiereAbbruchHotkey()
```

In `beendeVerarbeitung(id:zustellung:)` als **letzte** Zeile der Funktion, nach dem `switch`:

```swift
        synchronisiereAbbruchHotkey()
```

In `stop()`, unmittelbar vor dem `return` bzw. am Ende der Funktion:

```swift
        abbruchHotkey.gibFrei()
```

Hier bewusst der direkte `gibFrei()`-Aufruf statt der Synchronisierung: Beim Beenden soll Escape in **jedem** Fall frei werden, unabhängig davon, welchen Wert `session` gerade trägt.

- [ ] **Step 4: Attrappen-Durchreichung im Testfile**

In `makeCoordinator` (Testfile) den Parameter ergänzen — Default die Attrappe, **nie** `SystemAbbruchHotkey`:

```swift
                     abbruchHotkey: AbbruchHotkey = FakeAbbruchHotkey(),
```

und im Konstruktoraufruf durchreichen:

```swift
                         abbruchHotkey: abbruchHotkey,
```

Im Kommentarblock von `makeCoordinator` einen Satz ergänzen: Der Default ist die Attrappe, weil `SystemAbbruchHotkey` einen echten systemweiten Hotkey anmelden würde — ein Testlauf nähme dem ganzen Rechner Escape weg.

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift build && swift test`
Expected: PASS, 156 Proben (153 + 3 neue).

Wird eine bestehende Probe rot, melden statt anpassen — die Registrierung soll bestehendes Verhalten nicht verändern.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift \
        apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Diktat-Abbrechen: Escape nur waehrend der Verarbeitung registriert"
```

---

### Task 3: Der Abbruch wirkt

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `synchronisiereAbbruchHotkey()`, `brichAb()` (Task 2), `FakeAbbruchHotkey.druecke()` (Task 1)
- Produces: `Zustellung.abgebrochen`; wirksames `brichAb()`

- [ ] **Step 1: Proben schreiben**

Am Ende von `DictationCoordinatorTests.swift` anfügen:

```swift
// MARK: - Abbruch während der Verarbeitung

@MainActor
@Test(.timeLimit(.minutes(1)))
func escapeWaehrendDerVerarbeitungBrichtAbUndStelltNichtsZu() async {
    // Der Kern dieser Spec: Der Anwender merkt „das war Quatsch" und drückt Escape in den ~6 s
    // Verarbeitung. Nichts darf getippt werden, und die Zwischenablage muss ihren alten Inhalt
    // behalten — anders als bei einem geglückten Diktat, das dort immer ein Netz ablegt.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = GatedDictationClient()
    let abbruch = FakeAbbruchHotkey()
    let inserter = SpyInserter()
    let pasteboard = SpyPasteboard()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: pasteboard, inserter: inserter,
                                      abbruchHotkey: abbruch)
    await coordinator.start()
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .processing }

    abbruch.druecke()                                            // Escape
    // Danach trotzdem freigeben: `process` hängt in `withCheckedContinuation`, das auf `cancel()`
    // nicht reagiert. Die Task läuft erst weiter, wenn die Engine antwortet — und trifft dann den
    // `isCancelled`-Check. Genau dieser Ablauf entspricht der Realität: Die Engine rechnet ihr
    // Diktat zu Ende, das Ergebnis wird verworfen.
    client.freigeben(mit: .success(ergebnis("darf nie ankommen")))
    await warteBis { coordinator.overlay == .abgebrochen }

    #expect(coordinator.session == .idle, "ein Abbruch ist kein Fehler")
    #expect(coordinator.overlay == .abgebrochen)
    #expect(inserter.getippt.isEmpty, "es darf nichts getippt werden")
    #expect(pasteboard.geschrieben.isEmpty,
            "bei Abbruch bleibt die Zwischenablage unangetastet — kein Netz")
    #expect(abbruch.istRegistriert == false, "nach dem Abbruch muss Escape wieder frei sein")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func escapeOhneLaufendeVerarbeitungIstFolgenlos() async {
    // Außerhalb einer Verarbeitung ist der Hotkey gar nicht registriert. Diese Probe sichert, dass
    // ein trotzdem eintreffender Druck (Registrierung hängt, Ereignis kommt verspätet) keinen
    // Zustand umwirft — sonst könnte Escape ein frisches Diktat oder den Leerlauf zerstören.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis("Hallo")))
    let abbruch = FakeAbbruchHotkey()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: SpyPasteboard(), abbruchHotkey: abbruch)
    await coordinator.start()

    abbruch.druecke()
    await Task.yield()

    #expect(coordinator.session == .idle)
    #expect(coordinator.overlay == .aus)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func derAbbruchTrifftNurDieJuengsteVerarbeitung() async {
    // Läuft noch eine ältere Verarbeitung, gehört sie zu einem früheren Diktat, das der Anwender
    // nicht gemeint hat. Escape bezieht sich auf das, dessen Overlay er gerade sieht — die ältere
    // muss ungestört zu Ende laufen und ihren Text zustellen.
    //
    // Die Freigabe des torgesteuerten Clients ist FIFO: Der erste `freigeben`-Aufruf löst die
    // ÄLTERE Verarbeitung auf, der zweite die jüngere. Unterschiedliche Texte machen sichtbar,
    // welche von beiden zugestellt hat.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = GatedDictationClient()
    let abbruch = FakeAbbruchHotkey()
    let inserter = SpyInserter()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: SpyPasteboard(), inserter: inserter,
                                      abbruchHotkey: abbruch)
    await coordinator.start()
    // Erstes Diktat -> Verarbeitung läuft (torgesteuert, antwortet noch nicht)
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .processing }
    // Zweites Diktat -> wird die jüngste Verarbeitung
    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .processing }

    abbruch.druecke()                                       // trifft die JÜNGERE
    client.freigeben(mit: .success(ergebnis("Erstes")))     // FIFO: die ältere
    client.freigeben(mit: .success(ergebnis("Zweites")))    // die jüngere, abgebrochen
    await warteBis { coordinator.overlay == .abgebrochen }

    #expect(coordinator.session == .idle)
    #expect(inserter.getippt == ["Erstes"],
            "die ältere Verarbeitung darf NICHT mitabgebrochen werden — sie stellt zu")
}
```

- [ ] **Step 2: Proben laufen lassen — müssen fehlschlagen**

Run: `cd apps/macos && swift test --filter escapeWaehrendDerVerarbeitungBrichtAbUndStelltNichtsZu`
Expected: FAIL — `brichAb()` ist leer, das Overlay wird `.eingefuegt` statt `.abgebrochen`.

- [ ] **Step 3: `Zustellung.abgebrochen` ergänzen**

Im `private enum Zustellung` (`:526`) nach `case nichtsErkannt` einfügen:

```swift
        /// Der Anwender hat während der Verarbeitung abgebrochen. **Kein Fehler** — und
        /// ausdrücklich **kein** Netz in der Zwischenablage: Diesen Text will er nicht.
        case abgebrochen
```

Im `switch` von `beendeVerarbeitung` einen Zweig ergänzen (nach `.nichtsErkannt`):

```swift
        case .abgebrochen:
            session = .idle
            overlay = .abgebrochen
            blendeAusNach(dauerAbgebrochen)
```

- [ ] **Step 4: `brichAb()` mit Wirkung füllen**

Die vorläufige Fassung aus Task 2 ersetzen:

```swift
    /// Bricht die **jüngste** laufende Verarbeitung ab (Auslöser: Escape, s.
    /// ``synchronisiereAbbruchHotkey()``).
    ///
    /// Ältere, noch laufende Verarbeitungen bleiben unberührt — sie gehören zu einem früheren
    /// Diktat, das der Anwender nicht gemeint hat.
    ///
    /// Der Abbruch ist kooperativ: `cancel()` schließt über den Transport die HTTP-Verbindung
    /// (`HTTPUnixTransport.roundTrip` hängt in `withTaskCancellationHandler`), und der
    /// `isCancelled`-Check in `verarbeite` verhindert die Zustellung. Die **Engine** rechnet ihr
    /// Diktat trotzdem zu Ende: Die MLX-Generierung läuft in einem Worker-Thread und ist nicht
    /// unterbrechbar. Ein unmittelbar folgendes Diktat wartet daher ggf. wenige Sekunden auf den
    /// Lock des Sidecars — tolerierbar, und der Preis dafür, keinen serverseitigen Abbruch zu
    /// brauchen.
    private func brichAb() {
        guard session == .processing, let id = juengsteVerarbeitung else { return }
        verarbeitungen[id]?.cancel()
    }
```

- [ ] **Step 5: Den atomaren Schnitt in `verarbeite` einbauen**

Im `do`-Zweig der Task, **unmittelbar vor** `let zustellung = Self.stelleZu(...)`:

```swift
                // DER ATOMARE SCHNITT: Ab hier gibt es kein Zurück. `stelleZu` schreibt die
                // Zwischenablage und tippt; danach ist der Text beim Anwender. Weil `stelleZu` und
                // `beendeVerarbeitung` synchron auf dem MainActor laufen, liegt zwischen dieser
                // Prüfung und der Zustellung **kein Suspension-Punkt** — ein später eintreffender
                // Abbruch kann also nichts mehr halb erledigen. Entweder abgebrochen oder
                // zugestellt, nie beides.
                //
                // Ehrlich benannt: Ein Escape, das NACH dieser Zeile eintrifft, wird ignoriert und
                // der Text ist eingefügt. Das ist die sichere Seite — lieber ein nicht
                // abgebrochenes Diktat als ein halb eingefügtes.
                if Task.isCancelled {
                    self?.beendeVerarbeitung(id: id, zustellung: .abgebrochen)
                    return
                }
```

- [ ] **Step 6: Den Abbruch aus dem Fehlerpfad heraushalten**

Der `catch`-Zweig meldet heute jeden Fehler als `.fehler(...)`. Ein Abbruch, der den `await client.process(...)` trifft, kommt dort als `CancellationError` an und würde als Fehlschlag mit Warndreieck angezeigt. Den `catch`-Zweig ersetzen:

```swift
            } catch is CancellationError {
                // Der Anwender hat abgebrochen — kein Fehler, kein Warnzeichen, kein Netz.
                self?.beendeVerarbeitung(id: id, zustellung: .abgebrochen)
            } catch {
                // Echter Fehler (Engine weg, STT-Ausfall): Die Zwischenablage bleibt unangetastet
                // — der alte Inhalt ist besser als Leere.
                self?.beendeVerarbeitung(id: id, zustellung: .fehler(Self.beschreibe(error)))
            }
```

**Hinweis für die Umsetzung:** Der Transport wirft beim Abbruch möglicherweise nicht `CancellationError`, sondern einen eigenen Fehler (`TransportError.unreachable`, weil die Verbindung geschlossen wird). Läuft die Probe `escapeWaehrendDerVerarbeitungBrichtAbUndStelltNichtsZu` nach diesem Schritt in `.fehler` statt `.abgebrochen`, ist genau das der Grund. Dann zusätzlich am Anfang des `catch`-Zweigs auf `Task.isCancelled` prüfen und in diesem Fall `.abgebrochen` melden — der Abbruchwunsch des Anwenders schlägt die Fehlerursache. **Berichte, welcher der beiden Wege nötig war.**

- [ ] **Step 7: Tests laufen lassen**

Run: `cd apps/macos && swift build && swift test`
Expected: PASS, 159 Proben (156 + 3 neue).

- [ ] **Step 8: Mutationsprobe für den atomaren Schnitt**

Belege, dass der `isCancelled`-Check wirklich wacht: Entferne ihn testweise (die drei Zeilen aus Step 5), lass `escapeWaehrendDerVerarbeitungBrichtAbUndStelltNichtsZu` laufen — sie muss **rot** werden —, füge ihn wieder ein und lass sie erneut laufen: grün. Beide Ausgaben in den Report. **Kein `git stash`**, einfach die Zeilen entfernen und wieder einfügen; danach `git diff` prüfen, dass die Datei wieder unverändert ist.

- [ ] **Step 9: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift \
        apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Diktat-Abbrechen: Escape bricht die juengste Verarbeitung ab (atomarer Schnitt)"
```

---

### Task 4: Verdrahtung in der App und Dokumentation

**Files:**
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift` (nur falls nötig, s. Step 1)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: das fertige Verhalten aus Tasks 1–3
- Produces: nichts

- [ ] **Step 1: Prüfen, ob die App-Schicht etwas braucht**

Der `init`-Parameter hat den Default `SystemAbbruchHotkey()`, die App muss also nichts übergeben. Prüfe mit

```bash
grep -n "DictationCoordinator(" apps/macos/Sources/TypeLess/*.swift
```

ob dort explizit konstruiert wird. Falls ja und die übrigen Abhängigkeiten dort ausdrücklich gesetzt werden, ergänze `abbruchHotkey: SystemAbbruchHotkey()` **nur**, wenn es dem dortigen Stil entspricht; sonst nichts ändern und im Report vermerken, dass der Default greift.

- [ ] **Step 2: `CLAUDE.md` ergänzen**

Im Abschnitt „Diktieren (ab M4)" den Satz zum Abbruch erweitern. Er beschreibt derzeit nur den Abbruch beim Sprechen; ergänze die Verarbeitungsphase:

> Während der **Verarbeitung** bricht **Escape** ab (Overlay: „Abgebrochen"; die Zwischenablage bleibt dabei unangetastet — anders als bei einem geglückten Diktat, das dort immer ein Netz ablegt). Der Hotkey ist **nur** für die Dauer der Verarbeitung registriert, damit Escape sonst nicht systemweit blockiert ist; **bekannte Grenze:** Poppt in diesen ~6 s ein Dialog auf, den man mit Escape schließen will, bricht man stattdessen das Diktat ab.

Neuen Eintrag in der Meilenstein-Liste ergänzen (nach der M5-Umkehrung), wörtlich:

```markdown
- [x] **Diktat abbrechen (Verarbeitungsphase).** Bis dahin ließ sich ein Diktat nur **beim
  Sprechen** verwerfen (Taste bei gehaltenem Fn); in den ~6 s Verarbeitung gab es **keinen** Weg.
  Jetzt bricht **Escape** dort ab: `Task.cancel()` auf die jüngste Verarbeitung, Zustellung
  `.abgebrochen`, `session` zurück auf `.idle` — **kein Fehler**, kein Warnzeichen, und
  ausdrücklich **kein Netz** in der Zwischenablage (diesen Text will der Anwender nicht).
  **Datenschutz:** Der Auslöser ist `RegisterEventHotKey` (Carbon), **kein** Event-Tap — es sieht
  ausschließlich die angemeldete Kombination, nie andere Tastendrücke. Die Fn-Tap-Maske bleibt
  unverändert `.flagsChanged`.
  **Nur zeitweise registriert:** `synchronisiereAbbruchHotkey()` leitet die Registrierung
  idempotent aus `session` ab, statt sie an einzelne Übergänge zu hängen — es gibt drei Wege aus
  `.processing` heraus (Zustellung, Fehler, **neues Diktat**), und auf einem vergessenen bliebe
  Escape systemweit belegt, bis die App beendet wird.
  **Atomarer Schnitt:** Ein `Task.isCancelled`-Check unmittelbar vor `stelleZu` genügt, weil
  Zustellung und Zustandswechsel synchron auf dem MainActor laufen — dazwischen liegt kein
  Suspension-Punkt. Entweder abgebrochen oder zugestellt, nie beides. Ein Escape **nach** diesem
  Check wird bewusst ignoriert (lieber ein nicht abgebrochenes als ein halb eingefügtes Diktat).
  **Bewusst akzeptiert:** Die Engine rechnet ihr abgebrochenes Diktat zu Ende (MLX-Generierung ist
  nicht unterbrechbar), ein direkt folgendes Diktat wartet daher ggf. wenige Sekunden auf den Lock.
  Escape ist während der Verarbeitung systemweit belegt — s. Grenze unter „Diktieren".
```

- [ ] **Step 3: Volle Suite als Abschluss**

Run: `cd apps/macos && swift build && swift test`
Expected: PASS, 159 Proben.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md apps/macos/Sources/TypeLess/
git commit -m "Diktat-Abbrechen: CLAUDE.md dokumentiert beide Abbruch-Phasen"
```

---

## Handprobe nach Task 4 (nicht automatisierbar)

Die Suite prüft den Koordinator gegen die Attrappe — **ob Escape wirklich systemweit ankommt und
danach wieder freigegeben wird, kann nur die Handprobe zeigen.** `SystemAbbruchHotkey` ist
bewusst nicht unit-getestet.

Mit `bash scripts/build-app.sh` bauen, `apps/macos/TypeLess.app` starten:

| Schritt | Erwartung |
|---|---|
| Diktieren, während der Verarbeitung Escape | Overlay „Abgebrochen", **kein** Text im Feld |
| danach ⌘V | der **alte** Zwischenablage-Inhalt, nicht das abgebrochene Diktat |
| direkt danach normal diktieren | funktioniert; Text erscheint |
| **Escape im Leerlauf**, z. B. in einem Dialog einer anderen App | schließt den Dialog **normal** — der Hotkey ist freigegeben |
| Diktat abbrechen, dann sofort neues Diktat | zweites Diktat kommt an (Engine-Lock kann es kurz verzögern) |
| während der Verarbeitung neu diktieren (Fn), dann Escape im Leerlauf | Escape wirkt normal — Freigabe beim Wechsel nach `.recording` |

Der vierte und der letzte Punkt sind die wichtigsten: Ein hängengebliebener Hotkey blockiert Escape
systemweit, und das merkt man im Alltag erst, wenn ein Dialog sich nicht schließen lässt.
