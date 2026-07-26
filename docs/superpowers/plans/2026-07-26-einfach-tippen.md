# Einfach tippen — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TypeLess fügt seinen Text überall an der Cursorposition ein — auch in Feldern, die keine brauchbare AX-Auskunft geben (Spotify-, VS-Code-Suchfeld) —, legt jedes Diktat zusätzlich als Netz in die Zwischenablage und meldet einen Abbruch beim Sprechen.

**Architecture:** Umkehrung der M5-Logik in `DictationCoordinator.stelleZu`: statt vorab zu fragen, ob getippt werden darf, wird getippt — außer in vier Fällen, die **alle ohne fokussiertes AX-Element** prüfbar sind (Bedienungshilfen, sichere Eingabe, App-Wechsel, Passwortfeld). Vorgehen bewusst **additiv**: Tasks 1–4 bauen die neue Regel neben der alten auf (jede Task kompiliert und ist testbar), Task 5 räumt die dann unbenutzte alte API weg. Ohne diese Reihenfolge wäre der Zwischenstand in Swift nicht kompilierbar.

**Tech Stack:** Swift 6, SwiftUI-Shell (`apps/macos`), Swift Testing (`@Test`/`#expect`, **nicht** XCTest), ApplicationServices/Carbon für die AX- und Secure-Input-Abfragen.

**Spec:** `docs/superpowers/specs/2026-07-26-einfach-tippen-design.md`

## Global Constraints

- **Kommentare und Doku auf Deutsch**, bestehendem Stil folgen (begründend, nicht beschreibend).
- Alle Tests mit **Swift Testing** (`@Test`, `#expect`), nicht XCTest.
- **Die Event-Maske des Fn-Taps bleibt ausschließlich `.flagsChanged`.** Sie um `.keyDown` zu erweitern wäre ein Datenschutzbruch (M4-Regel). Diese Aufgabe fasst den Tap überhaupt nicht an.
- **`CGEventTextInserter.postTap` bleibt `.cgAnnotatedSessionEventTap`.** Ein Wechsel auf `.cghidEventTap` würde die Fn-als-Modifier-Wache brechen (s. `KeyDownCounter`). Nicht anfassen.
- **In Tests nie die echten `CGEventTextInserter`/`AXInsertionTarget`** — sonst tippt ein Testlauf echten Text in das vorderste Fenster. Immer `SpyInserter`/`FakeTarget`.
- **Datenschutz:** Es werden ausschließlich AX-**Metadaten** gelesen (Subrolle). Feldinhalte werden nie gelesen; `kAXValueAttribute` wird nach dieser Änderung gar nicht mehr angefasst.
- **Keine Mini-Pausen** zwischen den Tipp-Häppchen einbauen (bewusste Entscheidung, s. Spec „Bewusst nicht enthalten").
- Bauen und testen immer aus `apps/macos`: `swift build && swift test`. Einzelprobe: `swift test --filter <TestName>`.
- Vor jedem Commit muss `swift test` **vollständig grün** sein.

---

### Task 1: Die vier Prüfungen als Schnittstelle bereitstellen

Erweitert `InsertionTarget` **additiv** um alles, was die neue Regel braucht. Die alte API (`fokusziel()`, `fokusKennung()`) bleibt in dieser Task unberührt, damit alles kompiliert.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift`
- Modify: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift:246-279` (FakeTarget)
- Test: `apps/macos/Tests/TypeLessCoreTests/InsertionTargetTests.swift`

**Interfaces:**
- Consumes: nichts (erste Task)
- Produces:
  - `InsertionTarget.bedienungshilfenErteilt() -> Bool`
  - `InsertionTarget.sichereEingabeIstAktiv() -> Bool`
  - `InsertionTarget.istPasswortfeld() -> Bool`
  - `AXInsertionTarget.istPasswortSubrolle(_ subrolle: String?) -> Bool` (statisch, rein)
  - `FakeTarget(app:ziel:feld:bedienungshilfen:sichereEingabe:passwortfeld:)` plus `setzeBedienungshilfen(_:)`, `setzeSichereEingabe(_:)`, `setzePasswortfeld(_:)`

- [ ] **Step 1: Die reine Passwort-Regel als Test schreiben**

Die AX-Abfrage selbst braucht ein echtes Fenster und ist darum nicht scharf prüfbar. Deshalb — genau wie beim bestehenden `klassifiziere` — die **reine Regel** herausziehen und diese testen.

In `apps/macos/Tests/TypeLessCoreTests/InsertionTargetTests.swift` am Ende anfügen:

```swift
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
```

- [ ] **Step 2: Test laufen lassen — er muss fehlschlagen**

Run: `cd apps/macos && swift test --filter nurDieSichereSubrolleGiltAlsPasswortfeld`
Expected: Compile-Fehler — `istPasswortSubrolle`, `istPasswortfeld`, `bedienungshilfenErteilt`, `sichereEingabeIstAktiv` existieren nicht.

- [ ] **Step 3: Protokoll erweitern**

In `InsertionTarget.swift`, im `public protocol InsertionTarget`, **nach** `func vordersteApp() -> pid_t?` einfügen:

```swift
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
```

- [ ] **Step 4: `AXInsertionTarget` umsetzen**

In `InsertionTarget.swift`, in `public struct AXInsertionTarget`, **nach** `vordersteApp()` einfügen:

```swift
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
```

- [ ] **Step 5: `FakeTarget` erweitern**

In `DictationCoordinatorTests.swift`, `final class FakeTarget`. Die drei neuen Eigenschaften **nach** `private var feld: UInt64?` einfügen:

```swift
    /// Die drei Zustände der neuen Zustellregel (Spec: „einfach tippen"). Defaults sind der
    /// Normalfall „darf getippt werden", damit bestehende Proben unberührt bleiben.
    private var bedienungshilfen: Bool
    private var sichereEingabe: Bool
    private var passwortfeld: Bool
```

`init` ersetzen durch:

```swift
    init(app: pid_t? = 42, ziel: Fokusziel = .beschreibbaresTextfeld, feld: UInt64? = 1,
         bedienungshilfen: Bool = true, sichereEingabe: Bool = false, passwortfeld: Bool = false) {
        self.app = app
        self.ziel = ziel
        self.feld = feld
        self.bedienungshilfen = bedienungshilfen
        self.sichereEingabe = sichereEingabe
        self.passwortfeld = passwortfeld
    }
```

Und **nach** `func weckeBedienungshilfen(fuer pid: pid_t)` anfügen:

```swift
    func setzeBedienungshilfen(_ neu: Bool) { lock.lock(); bedienungshilfen = neu; lock.unlock() }
    func setzeSichereEingabe(_ neu: Bool) { lock.lock(); sichereEingabe = neu; lock.unlock() }
    func setzePasswortfeld(_ neu: Bool) { lock.lock(); passwortfeld = neu; lock.unlock() }

    func bedienungshilfenErteilt() -> Bool { lock.lock(); defer { lock.unlock() }; return bedienungshilfen }
    func sichereEingabeIstAktiv() -> Bool { lock.lock(); defer { lock.unlock() }; return sichereEingabe }
    func istPasswortfeld() -> Bool { lock.lock(); defer { lock.unlock() }; return passwortfeld }
```

- [ ] **Step 6: Tests laufen lassen — alle grün**

Run: `cd apps/macos && swift test`
Expected: PASS, inklusive der drei neuen Proben. Bestehende Proben unverändert grün (die neue API wird noch von niemandem benutzt).

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift \
        apps/macos/Tests/TypeLessCoreTests/InsertionTargetTests.swift \
        apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Einfach-Tippen: die vier Pruefungen als Schnittstelle (additiv)"
```

---

### Task 2: Die neue Zustellregel in `stelleZu`

Baut `stelleZu` auf die vier Bedingungen um. Danach wird überall getippt, wo nicht einer der vier Fälle greift — Spotify und VS-Code-Suchfeld eingeschlossen.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift:544-683` (`verarbeite`, `stelleZu`)
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift:364-376` (`handlePressed`: `fokusBeimDruck` wird nicht mehr gebraucht)
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `bedienungshilfenErteilt()`, `sichereEingabeIstAktiv()`, `istPasswortfeld()` (Task 1)
- Produces: `stelleZu(_:zielApp:target:inserter:pasteboard:) -> Zustellung` — **ohne** Parameter `zielFokus`

- [ ] **Step 1: Die zwei wirklich neuen Proben schreiben**

Wichtig: Für Bedienungshilfen und Passwortfeld gibt es **schon** Proben (`ohneBedienungshilfenWirdNichtGetippt` ab Zeile 1291, `inEinPasswortfeldWirdNiemalsGetippt` ab Zeile 1266). Die werden in Step 6 nur auf die neuen `FakeTarget`-Parameter **umgestellt** — keine neuen Proben mit kollidierenden Namen anlegen.

Neu sind nur zwei: der Kernfall der Umkehrung und die eigenständige Prüfung der sicheren Eingabe.

In `DictationCoordinatorTests.swift` am Ende anfügen:

```swift
// MARK: - Die neue Zustellregel (Spec „einfach tippen")

/// Hilfsaufbau: ein vollständiges Diktat durchlaufen lassen und die Zustellung abwarten.
@MainActor
private func diktiere(target: FakeTarget,
                      inserter: SpyInserter,
                      pasteboard: SpyPasteboard,
                      text: String = "Hallo") async {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis(text)))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: pasteboard, inserter: inserter, target: target)
    await coordinator.start()
    hotkey.druecke()
    await warteBis { coordinator.session == .recording }
    hotkey.lasseLos()
    await warteBis { coordinator.session == .idle || coordinator.session == .inZwischenablage }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func ohneAxAuskunftWirdTrotzdemGetippt() async {
    // DER KERN DIESER SPEC: Spotify liefert kein fokussiertes AX-Element, das VS-Code-Suchfeld
    // meldet unveränderlichen Anzeigetext. Beides fiel früher aus der Whitelist und landete in der
    // Zwischenablage. Jetzt wird dort getippt — die Whitelist ist weg. Diese Probe ist der
    // Nachfolger von `ohneGemerktesTextfeldWirdNichtGetippt`, dessen Erwartung sich umkehrt.
    let target = FakeTarget(app: 42)   // keine Element-Identität, keine Rolle — wie Spotify
    let inserter = SpyInserter()
    let pasteboard = SpyPasteboard()

    await diktiere(target: target, inserter: inserter, pasteboard: pasteboard)

    #expect(inserter.getippt == ["Hallo"],
            "ohne AX-Auskunft muss getippt werden — genau das ist die Umkehrung")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func beiSichererEingabeWirdNichtGetippt() async {
    // Secure Event Input verwirft synthetische Ereignisse UNABHÄNGIG von den Bedienungshilfen —
    // deshalb hier mit erteiltem Recht geprüft, sonst wäre die Regel nur von der Rechte-Prüfung
    // verdeckt. Mutationsprobe: Guard entfernen ⇒ rot.
    let target = FakeTarget(app: 42, bedienungshilfen: true, sichereEingabe: true)
    let inserter = SpyInserter()
    let pasteboard = SpyPasteboard()

    await diktiere(target: target, inserter: inserter, pasteboard: pasteboard)

    #expect(inserter.getippt.isEmpty, "bei sicherer Eingabe käme Getipptes nicht an")
}
```

- [ ] **Step 2: Tests laufen lassen — sie müssen fehlschlagen**

Run: `cd apps/macos && swift test --filter ohneAxAuskunftWirdTrotzdemGetippt`
Expected: FAIL — ohne gemerktes Feld führt der heutige Code auf die Zwischenablage, `inserter.getippt` ist leer.

- [ ] **Step 3: `stelleZu` umbauen**

In `DictationCoordinator.swift` die Funktion `stelleZu` **vollständig** ersetzen (von `/// Die fünf Bedingungen der Zustellung` bis zur schließenden Klammer):

```swift
    /// Die vier Bedingungen der Zustellung — **alle** müssen erfüllt sein, sonst Zwischenablage.
    ///
    /// **Die Umkehrung gegenüber M5:** Früher wurde vorab gefragt, ob das Ziel ein beschreibbares
    /// Textfeld ist und ob es noch dasselbe ist. Beide Fragen brauchten ein fokussiertes
    /// AX-Element — und genau daran scheiterten Apps mit unvollständigem AX-Baum (Spotify liefert
    /// kein Element, das VS-Code-Suchfeld meldet `AXStaticText`). Dort wurde nie getippt, obwohl das
    /// Tippen angekommen WÄRE.
    ///
    /// Jetzt wird getippt, außer in vier Fällen, die **alle ohne fokussiertes AX-Element** prüfbar
    /// sind. Zwei davon sind keine Vorsicht, sondern Physik (macOS verwirft die Ereignisse
    /// garantiert), einer ist ein nachgewiesener App-Wechsel, einer das Passwortfeld.
    ///
    /// **Bewusst eingekaufter Preis:** Ein Fokuswechsel INNERHALB derselben App (⌘L in die
    /// Adressleiste, Tab ins Betreff-Feld) wird nicht mehr erkannt — der Text landet dann im neuen
    /// Feld. Das ist exakt das Ergebnis, das echtes Tippen gehabt hätte, und der Text liegt
    /// zusätzlich in der Zwischenablage.
    ///
    /// Bewusst `static` und ohne `self`: Die Entscheidung hängt ausschließlich von den mitgereichten
    /// Werten ab (`zielApp` DIESES Diktats), nie vom aktuellen Zustand des Koordinators — ein
    /// überholtes Diktat darf nicht dorthin tippen, wo der Anwender INZWISCHEN steht.
    private static func stelleZu(_ text: String,
                                 zielApp: pid_t?,
                                 target: InsertionTarget,
                                 inserter: TextInserter,
                                 pasteboard: Pasteboard) -> Zustellung {
        // Leerer Text: nichts zu tun, nichts anzufassen — aber auch NICHT als Erfolg melden. Ohne
        // Ton ist das Overlay die einzige Rückmeldung; es muss „ist eingefügt" von „da war nichts"
        // unterscheiden können.
        guard !text.isEmpty else { return .nichtsErkannt }

        // Bedingung 1: Ohne Bedienungshilfen verwirft macOS jedes synthetische Ereignis.
        // Bedingung 2: Bei Secure Event Input ebenso — unabhängig von den Bedienungshilfen.
        // Beide sind Physik, nicht Vorsicht: Getipptes käme nicht an, `CGEventPost` meldet das aber
        // nicht zurück (s. ``TextInserter``) — das Diktat wäre bei zufriedener Anzeige verloren.
        guard target.bedienungshilfenErteilt(), !target.sichereEingabeIstAktiv() else {
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }

        // Bedingung 3: dieselbe App wie beim Fn-Druck. Der einzige Fall, in dem ein Fokuswechsel
        // SICHER feststeht — und ohne Sonderrecht prüfbar (`NSWorkspace`).
        guard let zielApp, target.vordersteApp() == zielApp else {
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }

        // Bedingung 4: kein Passwortfeld. Greift nur, wo AX überhaupt Auskunft gibt — die ehrlich
        // benannte Grenze (s. ``InsertionTarget/istPasswortfeld()``).
        guard !target.istPasswortfeld() else {
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }

        do {
            try inserter.insert(text)
            return .eingefuegt
        } catch {
            // Ein Diktat darf nie verloren gehen.
            pasteboard.write(text)
            return .inZwischenablage(text: text)
        }
    }
```

- [ ] **Step 4: Aufrufstelle und gemerkten Fokus anpassen**

In `verarbeite(_:zielApp:zielFokus:)`: Signatur und Aufruf entschlacken. Die Zeile

```swift
    private func verarbeite(_ samples: [Float], zielApp: pid_t?, zielFokus: Fokuskennung?) {
```

ersetzen durch:

```swift
    private func verarbeite(_ samples: [Float], zielApp: pid_t?) {
```

Im Task-Body die Capture-Liste und den `stelleZu`-Aufruf ersetzen:

```swift
        let task = Task { [weak self, client, pasteboard, inserter, target] in
            do {
                let ergebnis = try await client.process(pcm: pcm, mode: .diktat, language: nil)

                let zustellung = Self.stelleZu(ergebnis.finalText, zielApp: zielApp,
                                               target: target, inserter: inserter,
                                               pasteboard: pasteboard)
                self?.beendeVerarbeitung(id: id, zustellung: zustellung)
            } catch {
                self?.beendeVerarbeitung(id: id, zustellung: .fehler(Self.beschreibe(error)))
            }
        }
```

In `handleReleased()` den Aufruf anpassen:

```swift
        verarbeite(samples, zielApp: zielAppBeimDruck)
```

In `handlePressed()` die Zeile `fokusBeimDruck = target.fokusKennung()` **löschen**. Der Kommentarblock darüber muss mit: Den Absatz „M5: Ziel-App UND Ziel-Textfeld so früh wie möglich merken …" ersetzen durch:

```swift
        // Ziel-App so früh wie möglich merken — jetzt steht der Cursor noch dort, wo der Anwender
        // diktieren will. Beim Zustellen (in ~6 s) wird dagegen geprüft (Bedingung 3).
        // Electron-/Chromium-Apps beim Fn-Druck wecken: Ohne aufgebauten AX-Baum kann die
        // Passwortfeld-Prüfung (Bedingung 4) nichts erkennen. Der App-Wechsel-Beobachter
        // (s. `BedienungshilfenAufwecker`) tut das i. d. R. schon vorher; dies deckt den Fall ab,
        // dass die App beim TypeLess-Start bereits vorne war.
```

Die Eigenschaft `fokusBeimDruck` bleibt in dieser Task noch stehen (jetzt unbenutzt) — sie wird in Task 5 entfernt, zusammen mit `Fokuskennung`.

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: Die vier neuen Proben grün. **Erwartet rot sind jetzt die alten M5-Proben**, die den Feldwechsel prüfen (z. B. eine Probe mit `wechsleFeld`) — sie prüfen eine Regel, die es bewusst nicht mehr gibt.

- [ ] **Step 6: Bestehende M5-Proben umstellen bzw. entfernen**

Konkrete Liste (Zeilennummern vom Stand vor dieser Task, mit `grep -n "func <Name>"` neu finden):

**Löschen — sie prüfen bewusst entfallene Regeln:**
- `ohneTextfeldImFokusWirdNichtGetippt` (~1241, `ziel: .keinTextfeld`) — dort wird jetzt getippt.
- `anderesTextfeldInDerselbenAppVerhindertDasTippen` (~1446, `wechsleFeld(zu: 2)`) — Bedingung entfallen.
- `dasselbeTextfeldWirdWieBisherDirektGetippt` (~1482) — durch `ohneAxAuskunftWirdTrotzdemGetippt` abgedeckt.
- `ohneGemerktesTextfeldWirdNichtGetippt` (~1514, `feld: nil`) — die Erwartung **kehrt sich um**; der Nachfolger ist `ohneAxAuskunftWirdTrotzdemGetippt` aus Step 1.

**Umstellen — Regel bleibt, nur die Attrappen-Parameter ändern sich:**
- `ohneBedienungshilfenWirdNichtGetippt` (~1291): `FakeTarget(app: 42, ziel: .unbekannt)` → `FakeTarget(app: 42, bedienungshilfen: false)`.
- `inEinPasswortfeldWirdNiemalsGetippt` (~1266): `ziel: .passwortfeld` → `passwortfeld: true`.
- `jedesDiktatPruftSeinenEigenenGemerktenFokus` (~1382): Die Regel bleibt wichtig, gilt aber jetzt für die **App** statt das Feld. Auf `wechsleApp` umschreiben und umbenennen in `jedesDiktatPruftSeineEigeneGemerkteApp`; im Kommentar festhalten, dass ein überholtes Diktat nicht dorthin tippen darf, wo der Anwender inzwischen steht.
- Alle übrigen Stellen mit `ziel: .beschreibbaresTextfeld` (~1186, 1214, 1315, 1617, 1653, 1772, 1811, 1895): Parameter **weglassen**, der Default passt.

**Unverändert bleiben:** `appWechselWaehrendDerVerarbeitungVerhindertDasTippen` (~1214) und `scheiterndesTippenVerliertDasDiktatNicht` (~1315) — beide Regeln gelten weiter.

- [ ] **Step 7: Tests laufen lassen — vollständig grün**

Run: `cd apps/macos && swift test`
Expected: PASS, keine roten Proben mehr.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift \
        apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Einfach-Tippen: stelleZu auf vier Bedingungen umgebaut (tippen statt fragen)"
```

---

### Task 3: Zwischenablage als Netz

Jedes Diktat landet **zusätzlich** in der Zwischenablage, geschrieben **vor** dem Tippversuch. Damit ist Restrisiko 3 der Spec abgeräumt.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift` (`stelleZu`, Klassen-Doku)
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `stelleZu(_:zielApp:target:inserter:pasteboard:)` (Task 2)
- Produces: keine neuen Signaturen — geändertes Verhalten

- [ ] **Step 1: Tests für das Netz schreiben**

In `DictationCoordinatorTests.swift` am Ende anfügen:

```swift
// MARK: - Zwischenablage als Netz (Spec Teil 2)

@MainActor
@Test(.timeLimit(.minutes(1)))
func auchBeiErfolgreichemTippenLiegtDerTextInDerZwischenablage() async {
    // Das Netz: `CGEventPost` meldet keinen Misserfolg. Schluckt eine App die Ereignisse, wäre der
    // Text ohne Netz spurlos weg. Deshalb liegt er IMMER auch in der Zwischenablage — die
    // M5-Zusicherung „bei Erfolg unangetastet" ist dafür bewusst aufgegeben.
    let target = FakeTarget()
    let inserter = SpyInserter()
    let pasteboard = SpyPasteboard()

    await diktiere(target: target, inserter: inserter, pasteboard: pasteboard)

    #expect(inserter.getippt == ["Hallo"])
    #expect(pasteboard.geschrieben == ["Hallo"], "das Netz gilt auch im Erfolgsfall")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func dasNetzWirdVorDemTippenGeschrieben() async {
    // Die Reihenfolge ist tragend, nicht beliebig: Wirft der Einfüger, muss der Text trotzdem
    // vollständig in der Zwischenablage liegen — und zwar genau EINMAL, nicht zweimal.
    let target = FakeTarget()
    let inserter = SpyInserter(fehler: .ereignisNichtErzeugbar)
    let pasteboard = SpyPasteboard()

    await diktiere(target: target, inserter: inserter, pasteboard: pasteboard)

    #expect(inserter.getippt.isEmpty)
    #expect(pasteboard.geschrieben == ["Hallo"], "genau einmal geschrieben, nicht doppelt")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func leererTextFasstDieZwischenablageNichtAn() async {
    // Ein leeres Diktat darf die Zwischenablage nicht ohne Gegenwert zerstören — alter Inhalt
    // schlägt Leere.
    let target = FakeTarget()
    let inserter = SpyInserter()
    let pasteboard = SpyPasteboard()

    await diktiere(target: target, inserter: inserter, pasteboard: pasteboard, text: "")

    #expect(pasteboard.geschrieben.isEmpty, "leerer Text wird nie geschrieben")
    #expect(inserter.getippt.isEmpty)
}
```

- [ ] **Step 2: Tests laufen lassen — zwei müssen fehlschlagen**

Run: `cd apps/macos && swift test --filter auchBeiErfolgreichemTippenLiegtDerTextInDerZwischenablage`
Expected: FAIL — `pasteboard.geschrieben` ist leer, weil bei Erfolg heute nichts geschrieben wird.

- [ ] **Step 3: Das Netz einbauen**

In `stelleZu`: Direkt **nach** dem `guard !text.isEmpty`-Guard einfügen:

```swift
        // DAS NETZ (Spec Teil 2): Der Text liegt in JEDEM Fall in der Zwischenablage — und zwar
        // BEVOR getippt wird. Die Reihenfolge ist tragend: `CGEventPost` meldet keinen Misserfolg
        // (s. ``TextInserter``), „erst tippen, bei Misserfolg schreiben" ist also unmöglich.
        // Schluckt eine App die Ereignisse, rettet ⌘V das Diktat.
        //
        // Damit ist die M5-Zusicherung „bei Erfolg bleibt die Zwischenablage unangetastet" bewusst
        // aufgegeben (Entscheidung des Anwenders): Das Netz wiegt höher als eine ungestörte
        // Zwischenablage. Preis: vorher Kopiertes ist nach jedem Diktat weg.
        pasteboard.write(text)
```

Und **alle vier** `pasteboard.write(text)`-Aufrufe in den Guards und im `catch`-Zweig **entfernen** — der Text ist oben schon geschrieben. Ein zweites Schreiben wäre nicht falsch, aber irreführend (die Probe `dasNetzWirdVorDemTippenGeschrieben` prüft genau ein einziges Schreiben).

- [ ] **Step 4: Klassen-Doku korrigieren**

Am Kopf von `DictationCoordinator` steht eine jetzt **falsche** Zusicherung. Den Absatz

```swift
/// **Verbindlich (Entscheidung des Anwenders):** kein Ton; ein Overlay zeigt den Verlauf.
/// Deshalb bleibt bei **jedem** Fehlschlag die Zwischenablage unangetastet — dann liefert ⌘V
/// wenigstens den alten Inhalt statt Leere. Und wurde direkt eingefügt, bleibt sie ebenfalls
/// unangetastet: „Diktieren und Kopieren dürfen sich nicht gegenseitig stören."
```

ersetzen durch:

```swift
/// **Verbindlich (Entscheidung des Anwenders):** kein Ton; ein Overlay zeigt den Verlauf.
/// Bei **jedem Fehlschlag** bleibt die Zwischenablage unangetastet — dann liefert ⌘V wenigstens
/// den alten Inhalt statt Leere.
///
/// Ein **geglücktes** Diktat landet dagegen IMMER auch in der Zwischenablage (Netz, s.
/// `stelleZu`) — auch wenn direkt eingefügt wurde. Die frühere M5-Zusicherung „bei Erfolg bleibt
/// sie unangetastet" ist dafür bewusst aufgegeben: `CGEventPost` meldet keinen Misserfolg, ohne
/// Netz wäre ein verpufftes Diktat spurlos weg. Preis: vorher Kopiertes ist nach jedem Diktat weg.
```

- [ ] **Step 5: Bestehende Netz-Erwartungen umstellen**

Run: `cd apps/macos && swift test`

Jetzt werden Proben rot, die `pasteboard.geschrieben.isEmpty` erwarten, **obwohl die Zustellung glückt**. Das ist die beabsichtigte Verhaltensänderung.

**Das Kriterium:** Glückt die Zustellung (`.eingefuegt` / `.inZwischenablage`), muss die Erwartung auf den zugestellten Text umgestellt werden (`#expect(pasteboard.geschrieben == ["Hallo"])`), mit Kommentarverweis auf das Netz. Wird das Diktat dagegen **verworfen oder scheitert** (kein Text vorhanden), bleibt `isEmpty` korrekt und die Probe unverändert.

Kandidaten mit glückender Zustellung (`grep -n "geschrieben.isEmpty"` liefert die aktuellen Zeilen):
- `loslassenVerarbeitetUndStelltDenTextZu` (~397)
- `gescheiterterPreloadVerhindertDasDiktatNicht` (~452)
- `unpolierterTextWirdTrotzdemZugestellt` (~526)
- `aeltereVerarbeitungUeberschreibtNichtDenZustandDerNochLaufendenJuengeren` (~790)
- `normalfallTipptDirektUndLaesstDieZwischenablageInRuhe` (~1186) — hier ist zusätzlich **der Name jetzt falsch**: umbenennen in `normalfallTipptDirektUndLegtDenTextAlsNetzInDieZwischenablage`.

Bleiben unverändert (kein Text zuzustellen, `isEmpty` weiter korrekt):
- `diktatWaehrendDieEngineNochAufwaermtErklaertSichVerstaendlich` (~425)
- `zuKurzesAntippenWirdKommentarlosVerworfen` (~475)
- `stilleMeldetMikrofonproblemUndLaesstDieZwischenablageInRuhe` (~498)
- `fehlerLaesstDieZwischenablageUnangetastet` (~547) — **wichtig:** Das ist die Probe für „kein Netz bei Fehler" aus der Spec. Sie muss grün bleiben, ohne angefasst zu werden.
- `verloreneHaeppchenWerdenAlsFehlerGemeldetUndNichtVerarbeitet` (~653)
- `stopGibtBeiEinerHaengendenVerarbeitungNachDemZeitlimitAufOhneSieAbzubrechen` (~855)
- `verwaisteAufnahmeWirdVorNeustartVerworfen` (~905)

Jede rote Probe einzeln ansehen und nach dem Kriterium entscheiden — nicht pauschal ersetzen.

- [ ] **Step 5b: Tests laufen lassen — vollständig grün**

Run: `cd apps/macos && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift \
        apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Einfach-Tippen: Zwischenablage als Netz (vor dem Tippen, jedes Diktat)"
```

---

### Task 4: Abbruch beim Sprechen sichtbar machen

Der Abbruch existiert schon (Fn-als-Modifier-Wache verwirft das Diktat), passiert aber kommentarlos. Er bekommt eine Rückmeldung — **aber nur**, wenn wirklich gesprochen wurde, damit ein normales Fn+Pfeil kein „Abgebrochen" aufpoppen lässt.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Overlay/OverlayZustand.swift`
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift:474-478` (Verwerfen-Pfad), init
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: nichts aus Tasks 1–3
- Produces: `OverlayZustand.abgebrochen`; `DictationCoordinator.init(..., dauerAbgebrochen: Duration = .milliseconds(1500))`

- [ ] **Step 1: Tests schreiben**

In `DictationCoordinatorTests.swift` am Ende anfügen:

```swift
// MARK: - Abbruch beim Sprechen (Spec Teil 3)

@MainActor
@Test(.timeLimit(.minutes(1)))
func abbruchWaehrendDesSprechensWirdGemeldet() async {
    // Der Anwender redet, merkt „Quatsch" und drückt bei gehaltenem Fn eine Taste. Die
    // Fn-als-Modifier-Wache verwirft das Diktat — bisher kommentarlos. Jetzt sagt das Overlay es.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis("darf nie ankommen")))
    let counter = FakeKeyDownCounter()
    let pasteboard = SpyPasteboard()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: pasteboard, keyDownCounter: counter)
    await coordinator.start()
    hotkey.druecke()
    await warteBis { coordinator.session == .recording }
    counter.druecke()          // eine Taste bei gehaltenem Fn = Abbruch
    hotkey.lasseLos()

    await warteBis { coordinator.overlay == .abgebrochen }

    #expect(coordinator.session == .idle, "ein Abbruch ist kein Fehler")
    #expect(coordinator.overlay == .abgebrochen)
    #expect(client.processCount == 0, "die Engine wird gar nicht bemüht")
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage bleibt unangetastet")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func kurzesFnPlusTasteMeldetNichts() async {
    // DER ÄRGERNIS-FALL: Fn+Pfeil und Fn+Entf sind normale Tastaturnutzung, kein Diktat. Dabei darf
    // KEIN „Abgebrochen" aufpoppen. Unterschieden wird an der Audio-Menge: unter
    // `minimumSampleCount` war es kein Diktat. Entfernte man diese Schwelle, poppte das Overlay bei
    // jedem Fn+Pfeil auf — diese Probe würde dann rot.
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: [Float](repeating: 0.5, count: 100))  // weit unter 4 800
    let client = DictationClient(ergebnis: .success(ergebnis("egal")))
    let counter = FakeKeyDownCounter()
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder, client: client,
                                      pasteboard: SpyPasteboard(), keyDownCounter: counter)
    await coordinator.start()
    hotkey.druecke()
    await warteBis { coordinator.session == .recording }
    counter.druecke()
    hotkey.lasseLos()

    await warteBis { coordinator.session == .idle }

    #expect(coordinator.overlay == .aus, "kurzes Fn+Pfeil bleibt kommentarlos")
}
```

- [ ] **Step 2: Tests laufen lassen — sie müssen fehlschlagen**

Run: `cd apps/macos && swift test --filter abbruchWaehrendDesSprechensWirdGemeldet`
Expected: Compile-Fehler — `OverlayZustand.abgebrochen` existiert nicht.

Hinweis: `FakeKeyDownCounter.druecke(_ anzahl: UInt32 = 1)` ist die Methode, die einen Tastendruck bei gehaltenem Fn simuliert (Klasse ab Zeile 215). Sie heißt genauso wie `FakeHotkey.druecke()` — das sind zwei verschiedene Objekte, kein Konflikt.

- [ ] **Step 3: `OverlayZustand.abgebrochen` ergänzen**

In `OverlayZustand.swift`, **nach** `case eingefuegt` einfügen:

```swift
    /// Das Diktat wurde vom Anwender abgebrochen (Taste bei gehaltenem Fn). **Kein Fehler** —
    /// eigener Fall, damit das Overlay kein Warnzeichen zeigt, wo nichts schiefging.
    case abgebrochen
```

- [ ] **Step 4: Dauer und Verwerfen-Pfad umsetzen**

In `DictationCoordinator.swift` bei den übrigen Dauern (nach `dauerFehler`) einfügen:

```swift
    /// Abgebrochen — kurz, es ist nur eine Bestätigung ohne Inhalt.
    private let dauerAbgebrochen: Duration
```

Im `init` den Parameter ergänzen (nach `dauerFehler`) und zuweisen:

```swift
                dauerAbgebrochen: Duration = .milliseconds(1500)) {
```
```swift
        self.dauerAbgebrochen = dauerAbgebrochen
```

In `handleReleased()` den Verwerfen-Guard der Modifier-Wache ersetzen:

```swift
        guard zaehlerBeimLoslassen == zaehlerBeimDruck else {
            session = .idle
            // Nur melden, wenn wirklich gesprochen wurde. Die Wache kann nicht unterscheiden, ob
            // der Anwender ABBRECHEN wollte oder Fn nur als MODIFIER benutzt hat (Fn+Pfeil,
            // Fn+Entf) — beides führt zum Verwerfen, und das ist richtig. Eine Meldung bei jedem
            // Fn+Pfeil wäre aber ein Ärgernis: Das ist normale Tastaturnutzung, kein Diktat.
            // Dieselbe Schwelle wie beim versehentlichen Antippen entscheidet das.
            if recording.werte.count >= minimumSampleCount {
                overlay = .abgebrochen
                blendeAusNach(dauerAbgebrochen)
            } else {
                overlay = .aus
            }
            return
        }
```

- [ ] **Step 5: Anzeige ergänzen**

Der Overlay-View muss den neuen Fall behandeln, sonst kompiliert das `switch` nicht.

In `apps/macos/Sources/TypeLess/OverlayWindow.swift` **nach** dem `.eingefuegt`-Zweig (Zeile 19–20) einfügen:

```swift
            case .abgebrochen:
                zeile { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                    text: { Text("Abgebrochen") }
```

Bewusst `.secondary` statt der orangen Warnfarbe von `.fehler`: Ein Abbruch ist kein Fehlschlag, sondern eine bestätigte Absicht des Anwenders.

- [ ] **Step 6: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS, beide neuen Proben grün.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Overlay/OverlayZustand.swift \
        apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift \
        apps/macos/Sources/TypeLess/ \
        apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Einfach-Tippen: Abbruch beim Sprechen wird gemeldet (nur oberhalb der Audio-Schwelle)"
```

---

### Task 5: Die alte AX-API entfernen

`Fokusziel`, `Fokuskennung`, `klassifiziere`, `fokusziel()` und `fokusKennung()` werden von niemandem mehr benutzt. Toter Code in einem sicherheitsrelevanten Pfad ist schlechter als ein Git-Verlauf, der ihn zurückholt.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Insertion/InsertionTarget.swift`
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift` (`fokusBeimDruck`)
- Modify: `apps/macos/Tests/TypeLessCoreTests/InsertionTargetTests.swift`
- Modify: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift` (FakeTarget)

**Interfaces:**
- Consumes: alles aus Tasks 1–4
- Produces: `InsertionTarget` mit genau fünf Methoden — `vordersteApp()`, `bedienungshilfenErteilt()`, `sichereEingabeIstAktiv()`, `istPasswortfeld()`, `weckeBedienungshilfen(fuer:)`

- [ ] **Step 1: Prüfen, dass wirklich niemand mehr zugreift**

Run:
```bash
cd apps/macos && grep -rn "Fokusziel\|Fokuskennung\|klassifiziere\|fokusziel()\|fokusKennung()" Sources Tests
```
Erwartet: Treffer nur noch in den **Definitionen** (`InsertionTarget.swift`), in `FakeTarget` und in den alten Proben in `InsertionTargetTests.swift`. Gibt es einen Treffer in produktivem Aufruf-Code, ist Task 2 unvollständig — dort zuerst nachziehen.

- [ ] **Step 2: Aus dem Produktivcode entfernen**

In `InsertionTarget.swift` löschen:
- das komplette `public enum Fokusziel`
- das komplette `public struct Fokuskennung`
- `func fokusziel() -> Fokusziel` und `func fokusKennung() -> Fokuskennung?` aus dem **Protokoll**
- die Umsetzungen `fokusziel()`, `fokusKennung()` und `static func klassifiziere(...)` aus `AXInsertionTarget`

**`fokussiertesElement()` bleibt** — `istPasswortfeld()` braucht es.

In `DictationCoordinator.swift` die Eigenschaft `fokusBeimDruck` samt ihrem Doku-Kommentar löschen (der Block „Das Textfeld, in dem beim Fn-Druck der Cursor stand …").

- [ ] **Step 3: Aus den Tests entfernen**

In `InsertionTargetTests.swift` löschen: alle Proben unter `// MARK: - Klassifizierung eines fokussierten Elements` und unter `// MARK: - Abschluss-Review M5: die Identität des fokussierten Elements`, sowie `ohneBedienungshilfenIstDasFokuszielUnbekannt`, `beiSichererEingabeIstDasFokuszielUnbekannt` und `mitBedienungshilfenLiefertDasFokuszielEineEchteAntwort`.

**`vordersteAppLiefertEinePid` bleibt**, ebenso die in Task 1 ergänzten Proben.

In `FakeTarget` (`DictationCoordinatorTests.swift`) löschen: `ziel`, `feld`, `setzeZiel`, `wechsleFeld`, `fokusziel()`, `fokusKennung()` und die zugehörigen `init`-Parameter. Danach:

```swift
    init(app: pid_t? = 42,
         bedienungshilfen: Bool = true, sichereEingabe: Bool = false, passwortfeld: Bool = false) {
        self.app = app
        self.bedienungshilfen = bedienungshilfen
        self.sichereEingabe = sichereEingabe
        self.passwortfeld = passwortfeld
    }
```

Aufrufstellen anpassen: `FakeTarget(app: 42, feld: nil)` wird zu `FakeTarget(app: 42)`.

- [ ] **Step 4: Bauen und testen**

Run: `cd apps/macos && swift build 2>&1 | head -30`
Expected: keine Fehler. Bleiben Fehler, zeigen sie genau die vergessenen Aufrufstellen — dort nachziehen.

Run: `cd apps/macos && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources apps/macos/Tests
git commit -m "Einfach-Tippen: alte AX-API entfernt (Fokusziel, Fokuskennung, klassifiziere)"
```

---

### Task 6: Dokumentation nachziehen

Drei Stellen behaupten noch die alten Regeln. Eine falsche Doku an einer Sicherheitsentscheidung ist schlimmer als keine.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift:8-25` (`SessionState`)

**Interfaces:**
- Consumes: das fertige Verhalten aus Tasks 1–5
- Produces: nichts (nur Doku)

- [ ] **Step 1: `SessionState.inZwischenablage` korrigieren**

Der Doku-Kommentar zählt die „fünf Bedingungen" auf. Ersetzen durch:

```swift
    /// Der Text ist fertig, konnte aber nicht direkt eingefügt werden — er liegt in der
    /// Zwischenablage, ⌘V holt ihn.
    ///
    /// **Kein Fehler.** Alles hat funktioniert; nur eine der vier Bedingungen fürs direkte
    /// Einfügen war nicht erfüllt: fehlende Bedienungshilfen, aktives Secure Event Input, eine
    /// andere App im Vordergrund als beim Fn-Druck, oder ein erkanntes Passwortfeld. Ein eigener
    /// Fall und **nicht** `.failed`, weil das Menü sonst ein Warnzeichen zeigte, wo nichts
    /// schiefging — und weil der Anwender wissen soll, dass jetzt ⌘V dran ist.
    ///
    /// Hinweis: Der Text liegt bei **jedem** geglückten Diktat in der Zwischenablage (Netz, s.
    /// `stelleZu`). Dieser Zustand sagt darüber hinaus, dass ⌘V **nötig** ist.
```

- [ ] **Step 2: `CLAUDE.md` — M5-Abschnitt umschreiben**

Im Abschnitt „Aktueller Stand" den M5-Eintrag und die beiden M5-Nachbesserungs-Einträge so anpassen, dass sie den neuen Stand beschreiben. Verbindlich zu korrigieren:

1. „Der `DictationCoordinator` prüft beim Zustellen **fünf** Bedingungen" → **vier** Bedingungen, mit der neuen Liste (Bedienungshilfen, Secure Event Input, gleiche App, kein Passwortfeld).
2. „**Oberste Regel: entweder eingefügt oder in der Zwischenablage — nie ein drittes Ergebnis.**" bleibt — ergänzen: Der Text liegt jetzt **immer** auch in der Zwischenablage (Netz).
3. „Bei Erfolg bleibt die Zwischenablage unangetastet" → **streichen**, das gilt nicht mehr.
4. Der Satz „dasselbe Textfeld (Element-Identität, nicht Inhalt)" → streichen, diese Bedingung ist entfallen.
5. Die Behauptung, Suchfelder wie Spotify und das VS-Code-Suchfeld seien „**Weiter nicht erreichbar**" → **streichen**. Sie sind jetzt erreichbar; genau das war der Anlass. Ebenso den Satzteil, dass nur „⌘V" dort bleibt.
6. Beim Abschnitt „**Diktieren (ab M4)**": ergänzen, dass ein Diktat durch einen Tastendruck bei gehaltenem Fn abgebrochen wird (Overlay meldet „Abgebrochen").
7. Neuen Eintrag in der Meilenstein-Liste ergänzen (nach dem WebKit-Eintrag), wörtlich:

```markdown
- [x] **M5-Umkehrung — einfach tippen, überall.** Die M5-Vorabprüfung fragte über die
  Bedienungshilfen, *ob* getippt werden darf. Zwei ihrer fünf Bedingungen brauchten ein
  **fokussiertes AX-Element** („beschreibbares Textfeld?", „noch dasselbe Feld?") — und genau daran
  scheiterten Apps mit unvollständigem AX-Baum: Spotify liefert **kein** fokussiertes Element, das
  VS-Code-Suchfeld meldet `AXStaticText settable=false`. Dort wurde nie getippt, obwohl das Tippen
  angekommen **wäre**. Jetzt wird getippt, außer in **vier** Fällen, die alle **ohne** AX-Element
  prüfbar sind: Bedienungshilfen fehlen, Secure Event Input aktiv (beides Physik — macOS verwirft
  die Ereignisse garantiert), andere App als beim Fn-Druck, erkanntes Passwortfeld. `Fokusziel`,
  `Fokuskennung` und die Feldtypen-Whitelist sind **entfernt**.
  **Zwischenablage als Netz:** Jedes geglückte Diktat landet **zusätzlich** in der Zwischenablage,
  geschrieben **vor** dem Tippversuch (`CGEventPost` meldet keinen Misserfolg — „erst tippen, dann
  bei Misserfolg schreiben" ist unmöglich). Damit ist die M5-Zusicherung „bei Erfolg bleibt die
  Zwischenablage unangetastet" **bewusst aufgegeben**; bei **Fehlern** bleibt sie weiter unberührt.
  Preis: vorher Kopiertes ist nach jedem Diktat weg.
  **Abbruch beim Sprechen:** Eine Taste bei gehaltenem Fn verwirft das Diktat (das tat die
  Fn-als-Modifier-Wache schon immer) — jetzt meldet das Overlay „Abgebrochen", aber **nur** oberhalb
  der Audio-Mindestmenge, damit ein normales Fn+Pfeil kommentarlos bleibt.
  **Bewusst eingekaufte Restrisiken:** Ein Fokuswechsel **innerhalb** derselben App (⌘L in die
  Adressleiste, Tab ins Betreff-Feld) wird nicht mehr erkannt — der Text landet dann im neuen Feld,
  genau wie beim echten Tippen, und liegt dank Netz trotzdem in der Zwischenablage. Die
  Passwortfeld-Erkennung greift nur, wo AX Auskunft gibt; wo nicht, wird hineingetippt (Schaden
  asymmetrisch harmlos: TypeLess tippt **hinein** und liest nie **heraus**).
```

- [ ] **Step 3: Prüfen, dass keine alten Behauptungen übrig sind**

Run:
```bash
grep -n "fünf Bedingungen\|Element-Identität\|unangetastet\|nicht erreichbar\|Fokuskennung" CLAUDE.md
```
Jeden Treffer bewerten: beschreibt er noch das tatsächliche Verhalten? Falls nein, korrigieren. (Treffer zu „Zwischenablage bleibt bei **Fehlern** unangetastet" sind weiter korrekt und bleiben.)

- [ ] **Step 4: Volle Suite als Abschluss**

Run: `cd apps/macos && swift build && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift
git commit -m "Einfach-Tippen: CLAUDE.md und SessionState-Doku auf die neue Regel nachgezogen"
```

---

## Handprobe nach Task 6 (nicht automatisierbar)

Die Suite kann nicht prüfen, ob in echten Apps Text ankommt. Mit `bash scripts/build-app.sh` bauen, `apps/macos/TypeLess.app` starten und diktieren in:

| Ziel | Erwartung |
|---|---|
| **Spotify-Suchfeld** | direkt eingefügt (war vorher Zwischenablage) |
| **VS-Code-Suchfeld** | direkt eingefügt (war vorher Zwischenablage) |
| Mail-Nachrichtenrumpf, Claude, Slack | direkt eingefügt (unverändert) |
| Terminal mit „Sichere Tastatureingabe" | Zwischenablage, kein Tippen |
| natives Passwortfeld (z. B. Systemeinstellungen) | Zwischenablage, kein Tippen |
| während der Verarbeitung in eine andere App wechseln | Zwischenablage |
| Fn halten, sprechen, Taste drücken, loslassen | Overlay „Abgebrochen", kein Text |
| Fn+Pfeil kurz | **kein** Overlay |

Zusätzlich: nach jedem geglückten Diktat prüfen, dass ⌘V denselben Text liefert (Netz), und bei einem **langen** Diktat (BrainDump, > 1000 Zeichen) auf fehlende Zeichen achten — tritt Zeichenverlust auf, ist das der in der Spec benannte Fall für Mini-Pausen (dann eigenes Ticket, nicht hier).
