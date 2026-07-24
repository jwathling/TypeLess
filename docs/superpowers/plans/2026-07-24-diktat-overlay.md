# Diktat-Overlay Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein kleines, dezentes Overlay während des Diktats, das den Zustand (Live-Pegel beim Zuhören, Spinner beim Verarbeiten, Erfolg/Fehler) und — nur im Zwischenablage-Fall — den erkannten Text zeigt.

**Architecture:** Der `DictationCoordinator` (Kern, `@MainActor @Observable`) hält einen neuen, beobachtbaren `overlay: OverlayZustand`, den er an denselben Übergangsstellen setzt wie `session` — plus den Live-Pegel (vom Recorder) während der Aufnahme und den erkannten Text bei der Zustellung. Die App-Schicht zeigt diesen Zustand in einem passiven `NSPanel`, das nie den Tastaturfokus übernimmt (sonst bräche das direkte Einfügen aus M5). Die gesamte Anzeige-Logik ist ohne Fenster unit-testbar; nur die Fensterdarstellung ist Handprobe.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (`NSPanel`, `NSHostingController`), Swift Testing, `AVAudioEngine` (Pegel aus dem bestehenden Tap-Block).

## Global Constraints

- **Keine Töne** — das Overlay ist rein visuell.
- **Nur während eines Diktats sichtbar** — kein Dauer-Overlay; nach dem Ende blendet es aus.
- **Textvorschau nur im Zwischenablage-Fall** — bei direktem Einfügen kein Text (nur „Eingefügt ✓"), da der Text schon im Feld steht.
- **Vorschau-Kürzung:** erste **90 Zeichen**, am Wortende abgeschnitten, dann `" …"`; kürzere Texte ganz. Fester Startwert `90`, an einer Stelle justierbar.
- **Position:** unten mittig auf dem Bildschirm mit dem Tastaturfokus.
- **Passives Fenster:** übernimmt **nie** den Tastaturfokus (`.nonactivatingPanel`, `canBecomeKey`/`canBecomeMain` == `false`), klick-durchlässig (`ignoresMouseEvents = true`), Floating-Level, auf allen Spaces. Der Grund ist bindend: Fokus-Klau bräche das direkte Einfügen (M5).
- **Schichtung:** Anzeige-Logik in `TypeLessCore` (bleibt frei von SwiftUI/AppKit-UI); Fensterdarstellung nur in `Sources/TypeLess`.
- **Overlay ist nie Voraussetzung fürs Diktat** — schlägt seine Darstellung fehl, läuft Aufnahme/Verarbeitung/Zustellung unverändert weiter.
- **Datenschutz:** Text und Pegel bleiben im Prozess, verlassen den Rechner nicht.
- **Dauern:** „Eingefügt ✓" ~1 s, Zwischenablage ~4 s, Fehler ~2,5 s — dann ausblenden. Injizierbar (Defaults), damit Tests mit kurzen Dauern laufen.
- Kommentare/Docstrings auf **Deutsch** (bestehendem Stil folgen).

---

### Task 1: `OverlayZustand` + Textkürzung (Kern)

Der Anzeige-Typ und die reine Kürzungsfunktion — ohne jeden Coordinator-Bezug, damit sie isoliert testbar sind.

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Overlay/OverlayZustand.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/OverlayVorschauTests.swift`

**Interfaces:**
- Produces: `enum OverlayZustand: Sendable, Equatable` mit Fällen `aus`, `hoertZu(pegel: Float)`, `verarbeitet`, `eingefuegt`, `zwischenablage(vorschau: String)`, `fehler(String)`.
- Produces: `func overlayVorschau(_ text: String, grenze: Int = 90) -> String` (frei, `public`).

- [ ] **Step 1: Fehlschlagenden Test schreiben**

Datei `apps/macos/Tests/TypeLessCoreTests/OverlayVorschauTests.swift`:

```swift
import Testing
@testable import TypeLessCore

struct OverlayVorschauTests {
    @Test func kurzerTextBleibtGanz() {
        #expect(overlayVorschau("Ja, passt.") == "Ja, passt.")
    }

    @Test func langerTextWirdAmWortendeGekuerzt() {
        let text = "Ich schlage vor, dass wir das Feature erst nach dem Release angehen, weil sonst der Zeitplan kippt."
        let v = overlayVorschau(text, grenze: 40)
        #expect(v.hasSuffix(" …"))
        #expect(v.count <= 42)              // 40 + " …" minus entfernter Rest
        #expect(!v.dropLast(2).hasSuffix(" ")) // kein Leerzeichen vor dem Auslassungszeichen
        #expect(text.hasPrefix(String(v.dropLast(2)))) // der Anfang stimmt wörtlich
    }

    @Test func genauAnDerGrenzeBleibtGanz() {
        let text = String(repeating: "a", count: 30)
        #expect(overlayVorschau(text, grenze: 30) == text)
    }

    @Test func ohneWortgrenzeImKnappenBereichHarterSchnitt() {
        // Ein sehr langes Wort ohne Leerzeichen: es gibt keine sinnvolle Wortgrenze,
        // also wird hart an der Grenze geschnitten.
        let text = String(repeating: "b", count: 60)
        let v = overlayVorschau(text, grenze: 20)
        #expect(v == String(repeating: "b", count: 20) + " …")
    }

    @Test func fuehrendeUndFolgendeLeerzeichenWerdenGetrimmt() {
        #expect(overlayVorschau("   Hallo Welt   ") == "Hallo Welt")
    }
}
```

- [ ] **Step 2: Test ausführen, Fehlschlag bestätigen**

Run: `cd apps/macos && swift test --filter OverlayVorschauTests 2>&1 | tail -5`
Expected: FAIL (Kompilierfehler — `overlayVorschau`/`OverlayZustand` existieren nicht).

- [ ] **Step 3: Typ + Kürzung implementieren**

Datei `apps/macos/Sources/TypeLessCore/Overlay/OverlayZustand.swift`:

```swift
import Foundation

/// Was das Diktat-Overlay gerade anzeigt — die **Anzeige-Projektion** des Diktats, getrennt vom
/// ``SessionState`` (der die Wahrheit über den Ablauf trägt). Eigener Typ, weil das Overlay
/// Dinge zeigt, die der ``SessionState`` nicht kennt: den Live-Pegel, den erkannten Text, und den
/// kurzen „Eingefügt ✓"-Moment (den der ``SessionState`` zu `.idle` zusammenfasst).
public enum OverlayZustand: Sendable, Equatable {
    /// Nichts sichtbar — das Overlay ist ausgeblendet.
    case aus
    /// Aufnahme läuft; `pegel` (0…1, geglättet) treibt die Balken.
    case hoertZu(pegel: Float)
    /// Die Engine verarbeitet (STT + LLM).
    case verarbeitet
    /// Der Text wurde direkt an der Cursorposition eingefügt — kurze Erfolgsmeldung, KEIN Text
    /// (er steht ja schon im Feld).
    case eingefuegt
    /// Der Text liegt in der Zwischenablage (⌘V). Hier — und nur hier — zeigt das Overlay eine
    /// gekürzte Vorschau, damit der Anwender sieht, was ⌘V einfügt.
    case zwischenablage(vorschau: String)
    /// Ein Fehlschlag im Klartext (z. B. „Nichts erkannt").
    case fehler(String)
}

/// Kürzt den erkannten Text für die Zwischenablage-Vorschau auf den Anfang: erste `grenze`
/// Zeichen, am Wortende abgeschnitten, dann `" …"`. Kürzere Texte bleiben ganz. So bleibt das
/// Overlay eine Zeile breit, egal wie lang das Diktat ist.
///
/// **Datenschutz:** reine Zeichen-Operation, rein lokal — hier wird nur gekürzt, nichts gesendet.
public func overlayVorschau(_ text: String, grenze: Int = 90) -> String {
    let getrimmt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let zeichen = Array(getrimmt)
    guard zeichen.count > grenze else { return getrimmt }

    var schnitt = grenze
    // Letzte Wortgrenze (Leerzeichen) vor der Grenze — aber nur, wenn sie nicht ins erste knappe
    // Drittel fällt (sonst bliebe von einem langen Wort zu wenig übrig; dann hart schneiden).
    if let space = zeichen[0..<grenze].lastIndex(of: " "),
       space > Int(Double(grenze) * 0.55) {
        schnitt = space
    }
    var kopf = String(zeichen[0..<schnitt])
    // Abschließende Satzzeichen/Leerzeichen entfernen, damit „… ," o. Ä. nicht entsteht.
    while let last = kopf.last, last == " " || ",;:.".contains(last) { kopf.removeLast() }
    return kopf + " …"
}
```

- [ ] **Step 4: Test ausführen, Erfolg bestätigen**

Run: `cd apps/macos && swift test --filter OverlayVorschauTests 2>&1 | tail -5`
Expected: PASS (5 Tests).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Overlay/OverlayZustand.swift apps/macos/Tests/TypeLessCoreTests/OverlayVorschauTests.swift
git commit -m "Diktat-Overlay: OverlayZustand + Textkuerzung (Kern)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Coordinator hält & setzt `overlay` (ohne Pegel, ohne Auto-Ausblenden)

Der `DictationCoordinator` bekommt eine beobachtbare `overlay`-Eigenschaft und setzt sie an denselben Übergangsstellen wie `session`. Der Live-Pegel (Task 3) und das Auto-Ausblenden (Task 4) kommen danach; hier bleibt `overlay` schlicht auf dem gesetzten Wert stehen.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `OverlayZustand`, `overlayVorschau(_:grenze:)` (Task 1).
- Produces: `public private(set) var overlay: OverlayZustand` am `DictationCoordinator`.

- [ ] **Step 1: `Zustellung` um den Text erweitern**

In `DictationCoordinator.swift` das interne enum `Zustellung` (aktuell ~Z. 420) so ändern, dass der Zwischenablage-Fall den Text trägt (für die Vorschau):

```swift
    private enum Zustellung: Equatable {
        case eingefuegt
        case inZwischenablage(text: String)
        case nichtsErkannt
        case fehler(String)
    }
```

In `stelleZu(...)` die **drei** `return .inZwischenablage`-Stellen (nach je einem `pasteboard.write(text)`) auf `return .inZwischenablage(text: text)` umstellen. Die `pasteboard.write(text)`-Aufrufe bleiben unverändert davor stehen.

- [ ] **Step 2: `overlay`-Eigenschaft ergänzen**

In `DictationCoordinator` direkt nach `public private(set) var session: SessionState = .idle` (Z. 43):

```swift
    /// Was das Overlay gerade anzeigt (s. ``OverlayZustand``). Getrennt von ``session``: Das
    /// Overlay zeigt den Live-Pegel und den erkannten Text, die der ``SessionState`` nicht trägt,
    /// und einen kurzen „Eingefügt ✓"-Moment, den ``session`` zu `.idle` zusammenfasst.
    public private(set) var overlay: OverlayZustand = .aus
```

- [ ] **Step 3: `overlay` an den Übergangsstellen setzen**

- Aufnahmestart: unmittelbar bei `session = .recording` (~Z. 341) davor/danach ergänzen:
  ```swift
      overlay = .hoertZu(pegel: 0)   // echter Pegel kommt in Task 3
  ```
- Verarbeitung: bei `session = .processing` (~Z. 413) ergänzen:
  ```swift
      overlay = .verarbeitet
  ```
- Zustellung: in `beendeVerarbeitung(id:zustellung:)` **innerhalb** der beiden bestehenden Guards
  (`guard id == juengsteVerarbeitung`, `guard session == .processing`) den `switch` erweitern, sodass
  neben `session` auch `overlay` gesetzt wird:
  ```swift
      switch zustellung {
      case .eingefuegt:
          session = .idle
          overlay = .eingefuegt
      case let .inZwischenablage(text):
          session = .inZwischenablage
          overlay = .zwischenablage(vorschau: overlayVorschau(text))
      case .nichtsErkannt:
          session = .failed("Nichts erkannt")
          overlay = .fehler("Nichts erkannt")
      case let .fehler(grund):
          session = .failed(grund)
          overlay = .fehler(grund)
      }
  ```

> Umsetzer-Hinweis: Die genauen Zeilennummern gegen die echte Datei prüfen (sie können minimal abweichen). Es gibt weitere Stellen, die `session = .failed(...)` setzen (Aufnahme-Abbruch, Gerätewechsel, kein Ton — ~Z. 274/323/325/359/391/402/409). Setze an **jeder** dieser Stellen zusätzlich `overlay = .fehler(<derselbe Text>)`, damit auch Aufnahme-Fehler im Overlay erscheinen. Wo `session` auf `.idle` geht, ohne dass etwas zugestellt wurde (z. B. verworfene Aufnahme, ~Z. 373/381), setze `overlay = .aus`.

- [ ] **Step 4: Fehlschlagenden Test schreiben**

An `DictationCoordinatorTests.swift` anhängen (nutzt die dort bereits vorhandenen Fakes/Helfer — der Umsetzer prüft deren echte Namen und den Aufbau eines Diktat-Durchlaufs in der Datei und folgt ihm):

```swift
    @Test func overlayZeigtVerarbeitetWaehrendDerVerarbeitung() async {
        // Aufbau eines Diktats bis in die Verarbeitung analog zu den bestehenden Tests;
        // danach: overlay == .verarbeitet.
        // (Struktur an den vorhandenen Diktat-Durchlauf-Tests dieser Datei ausrichten.)
    }

    @Test func overlayTraegtDieZwischenablageVorschau() async {
        // Ein Diktat, das in der Zwischenablage landet (Zielbedingungen nicht erfüllt),
        // liefert overlay == .zwischenablage(vorschau: overlayVorschau(<erkannter Text>)).
    }

    @Test func overlayZeigtEingefuegtOhneText() async {
        // Ein Diktat, das direkt eingefügt wird, liefert overlay == .eingefuegt (kein Text).
    }
```

> Umsetzer-Hinweis: Fülle diese drei Proben mit dem konkreten Aufbau aus den bestehenden Tests dieser Datei (gleiche Fakes für `client`/`inserter`/`target`/`pasteboard`, gleiche Art, ein `.pressed`/`.released` auszulösen und auf das Ergebnis zu warten). Die Aussagen sind: `.verarbeitet` während der Verarbeitung, `.zwischenablage(vorschau:)` mit korrekt gekürztem Text im Zwischenablage-Fall, `.eingefuegt` im Einfüge-Fall. Kein Timing/Ausblenden hier (das ist Task 4) — nur der gesetzte Wert.

- [ ] **Step 5: Test ausführen (rot), implementieren ist bereits in Step 1–3 geschehen, dann grün**

Run: `cd apps/macos && swift test --filter DictationCoordinatorTests 2>&1 | tail -8`
Expected: die drei neuen Proben PASS, alle bestehenden weiter grün.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Diktat-Overlay: Coordinator haelt overlay-Zustand (ohne Pegel/Ausblenden)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Live-Pegel (Recorder liefert Peak, Coordinator pollt)

Der Recorder gibt während der Aufnahme den Spitzenpegel nach außen; der Coordinator pollt ihn und aktualisiert `overlay = .hoertZu(pegel:)`.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Audio/AudioRecorder.swift`
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Produces: `func aktuellerPegel() async -> Float` im `AudioRecorder`-Protokoll (0…1, Spitzenpegel des zuletzt eingegangenen Audio-Puffers; `0`, wenn nicht aufgenommen wird).
- Consumes: `overlay` (Task 2).

- [ ] **Step 1: Protokoll erweitern**

In `AudioRecorder.swift` das Protokoll (Z. 85) ergänzen:

```swift
public protocol AudioRecorder: Sendable {
    func start() async throws
    func stop() async throws -> AudioRecording
    /// Spitzenpegel (0…1) des zuletzt eingegangenen Audio-Puffers — für die Live-Anzeige während
    /// der Aufnahme. `0`, wenn gerade nicht aufgenommen wird. Bewusst ein billiger Momentanwert:
    /// Er wird im Echtzeit-Tap nur abgelegt (max. abs.), nicht gepuffert.
    func aktuellerPegel() async -> Float
}
```

- [ ] **Step 2: Peak im Recorder ablegen**

In `AVAudioEngineRecorder`: der `Sammler` (Z. 134) bekommt zusätzlich den letzten Peak (threadsicher, gleicher Lock-Stil):

```swift
        private var letzterPeak: Float = 0

        /// Legt den Spitzenpegel des zuletzt umgerechneten Häppchens ab (max. Absolutwert).
        /// Threadsicher wie `append`; der Echtzeit-Thread darf nichts Langsames tun — das ist eine
        /// einzige Reduktion über den Puffer.
        func peakSetzen(_ neue: [Float]) {
            var p: Float = 0
            for w in neue { let a = abs(w); if a > p { p = a } }
            lock.lock(); letzterPeak = p; lock.unlock()
        }

        func peakLesen() -> Float {
            lock.lock(); defer { lock.unlock() }; return letzterPeak
        }
```

Im Tap-Block (Z. 245, nach `sammler.append(neue)`) den Peak mit ablegen:

```swift
                    let neue = try resampler.append(puffer)
                    sammler.append(neue)
                    sammler.peakSetzen(neue)
```

In `stop()` beim Zurücksetzen (der Recorder ist danach `.gestoppt`) den Peak auf 0 setzen — ergänze in `stop()` nach `zustand = .gestoppt` (Z. 300): `sammler.peakSetzen([])`. Und die Actor-Methode:

```swift
    public func aktuellerPegel() async -> Float {
        guard zustand == .laeuft else { return 0 }
        return sammler.peakLesen()
    }
```

- [ ] **Step 3: Pegel-Poll im Coordinator**

Feld + Intervall (injizierbar) in `DictationCoordinator` ergänzen (bei den anderen privaten Feldern):

```swift
    private var pegelTask: Task<Void, Never>?
    private let pegelIntervall: Duration
```

Den `init` um `pegelIntervall: Duration = .milliseconds(66)` erweitern (≈ 15 Hz) und zuweisen.

Poll-Achse:

```swift
    /// Aktualisiert den Live-Pegel im Overlay, solange aufgenommen wird. Schreibt AUSSCHLIESSLICH,
    /// wenn das Overlay noch `.hoertZu` ist — sonst hat die Verarbeitung schon übernommen, und ein
    /// nachlaufender Poll dürfte sie nicht überschreiben (Prüfung + Schreiben unmittelbar auf dem
    /// MainActor, ohne `await` dazwischen).
    private func startePegelPoll() {
        pegelTask?.cancel()
        pegelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pegel = await self.recorder.aktuellerPegel()
                guard !Task.isCancelled else { return }
                if case .hoertZu = self.overlay { self.overlay = .hoertZu(pegel: pegel) }
                try? await Task.sleep(for: self.pegelIntervall)
            }
        }
    }

    private func stoppePegelPoll() {
        pegelTask?.cancel()
        pegelTask = nil
    }
```

Verdrahten: bei Aufnahmestart (nach `overlay = .hoertZu(pegel: 0)`) `startePegelPoll()`; beim Übergang zu `.processing` **und** in jedem Aufnahme-Fehlerpfad `stoppePegelPoll()` (der Poll darf nach dem Zuhören nicht weiterlaufen).

- [ ] **Step 4: Fehlschlagenden Test schreiben**

An `DictationCoordinatorTests.swift` anhängen. Nutzt einen Fake-Recorder, dessen `aktuellerPegel()` einen festen Wert liefert (der Umsetzer erweitert den in der Datei bereits vorhandenen Recorder-Fake um `aktuellerPegel()`):

```swift
    @Test func pegelLandetWaehrendDerAufnahmeImOverlay() async {
        // Fake-Recorder liefert aktuellerPegel() == 0.7. Aufnahme starten, kurz warten,
        // bis der Poll einmal lief; Erwartung: overlay == .hoertZu(pegel: 0.7).
        // Deterministisch über ein knappes pegelIntervall + eine „eventually"-Prüfung
        // (kein festes sleep), im Stil der vorhandenen Achsen-Tests.
    }
```

> Umsetzer-Hinweis: Vervollständige die Probe mit dem echten Fake-Aufbau der Datei. Erweitere den Recorder-Fake um ein einstellbares `aktuellerPegel()`. Halte den Test deterministisch (kurzes `pegelIntervall` im Test-`init`, Warten bis Bedingung erfüllt). Belege optional zusätzlich: nach `stop()`/Verarbeitung schreibt der Poll den Pegel nicht mehr (overlay ist dann `.verarbeitet`).

- [ ] **Step 5: Tests ausführen**

Run: `cd apps/macos && swift test --filter DictationCoordinatorTests 2>&1 | tail -8`
Expected: neue Pegel-Probe PASS, alle bestehenden grün.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Audio/AudioRecorder.swift apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Diktat-Overlay: echter Live-Pegel (Recorder-Peak + Poll)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Auto-Ausblenden der Endzustände (Timing)

Nach „Eingefügt ✓" (~1 s), Zwischenablage (~4 s) und Fehler (~2,5 s) blendet das Overlay von selbst aus. Ein neues Diktat bricht einen laufenden Ausblend-Timer ab.

**Files:**
- Modify: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Test: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `overlay` (Task 2).

- [ ] **Step 1: Ausblend-Task + injizierbare Dauern**

Felder ergänzen:

```swift
    private var ausblendTask: Task<Void, Never>?
    private let dauerEingefuegt: Duration
    private let dauerZwischenablage: Duration
    private let dauerFehler: Duration
```

`init` um `dauerEingefuegt: Duration = .seconds(1)`, `dauerZwischenablage: Duration = .seconds(4)`, `dauerFehler: Duration = .milliseconds(2500)` erweitern und zuweisen.

```swift
    /// Blendet das Overlay nach `dauer` aus — es sei denn, bis dahin hat ein neues Diktat den
    /// Zustand verändert (dann wurde dieser Task abgebrochen). Ein neues Diktat ruft beim Start
    /// `ausblendTask?.cancel()`.
    private func blendeAusNach(_ dauer: Duration) {
        ausblendTask?.cancel()
        ausblendTask = Task { [weak self] in
            try? await Task.sleep(for: dauer)
            guard let self, !Task.isCancelled else { return }
            self.overlay = .aus
        }
    }
```

- [ ] **Step 2: Verdrahten**

- In `beendeVerarbeitung` (Task 2, im `switch`) nach dem Setzen des Endzustands den passenden Timer starten:
  - `.eingefuegt` → `blendeAusNach(dauerEingefuegt)`
  - `.inZwischenablage` → `blendeAusNach(dauerZwischenablage)`
  - `.nichtsErkannt`/`.fehler` → `blendeAusNach(dauerFehler)`
- In **jedem** Aufnahme-Fehlerpfad, der `overlay = .fehler(...)` setzt (Task 2 Step 3, Umsetzer-Hinweis), ebenfalls `blendeAusNach(dauerFehler)`.
- Bei **Aufnahmestart** (vor/bei `overlay = .hoertZu(pegel: 0)`) `ausblendTask?.cancel()` — ein neues Diktat räumt einen noch laufenden Ausblend-Timer sofort weg.

- [ ] **Step 3: Fehlschlagende Tests schreiben**

```swift
    @Test func eingefuegtBlendetNachDerDauerAus() async {
        // Coordinator mit dauerEingefuegt: .milliseconds(20). Ein direkt eingefügtes Diktat:
        // overlay == .eingefuegt, dann nach der Dauer overlay == .aus.
    }

    @Test func neuesDiktatBrichtDenAusblendTimerAb() async {
        // Nach einem Zwischenablage-Diktat (langer dauerZwischenablage) startet ein neues
        // Diktat: overlay springt auf .hoertZu, und der alte Ausblend-Timer setzt danach NICHT
        // mehr auf .aus (deterministisch prüfen, im Stil der Task-Abbruch-Tests der Datei).
    }
```

> Umsetzer-Hinweis: Fülle beide Proben mit dem konkreten Diktat-Aufbau der Datei. Nutze kurze injizierte Dauern. Für die Abbruch-Probe: nach dem neuen Diktat eine Zeit länger als die alte (bereits abgebrochene) Dauer warten und belegen, dass `overlay` NICHT fälschlich auf `.aus` fiel.

- [ ] **Step 4: Tests ausführen**

Run: `cd apps/macos && swift test --filter DictationCoordinatorTests 2>&1 | tail -8`
Expected: neue Timing-Proben PASS, alle bestehenden grün.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift
git commit -m "Diktat-Overlay: Auto-Ausblenden der Endzustaende (injizierbare Dauern)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Overlay-Fenster (App-Schicht) + CLAUDE.md

Das passive `NSPanel`, das den `overlay`-Zustand anzeigt — AppDelegate-getrieben wie das Einrichtungs-Fenster (Teil 2b). Keine Unit-Tests (Handprobe in Task 6).

**Files:**
- Create: `apps/macos/Sources/TypeLess/OverlayWindow.swift`
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `DictationCoordinator.overlay` (Tasks 2–4).

- [ ] **Step 1: Die View + das passive Panel**

Datei `apps/macos/Sources/TypeLess/OverlayWindow.swift`. Enthält (a) die SwiftUI-View, die einen `OverlayZustand` rendert, und (b) eine `NSPanel`-Fabrik mit den bindenden passiven Eigenschaften.

```swift
import AppKit
import SwiftUI
import TypeLessCore

/// Die Anzeige des Diktat-Overlays. Rein darstellend — liest ``DictationCoordinator/overlay`` und
/// rendert die aktuelle Phase. macOS-HUD-Stil: kleines, dunkles, abgerundetes Panel.
struct OverlayView: View {
    let coordinator: DictationCoordinator

    var body: some View {
        Group {
            switch coordinator.overlay {
            case .aus:
                EmptyView()
            case let .hoertZu(pegel):
                zeile { Pegelbalken(pegel: pegel) } text: { Text("Hört zu …") }
            case .verarbeitet:
                zeile { ProgressView().controlSize(.small) } text: { Text("Verarbeitet …") }
            case .eingefuegt:
                zeile { Image(systemName: "checkmark").foregroundStyle(.green) } text: { Text("Eingefügt") }
            case let .zwischenablage(vorschau):
                VStack(alignment: .leading, spacing: 5) {
                    zeile { Image(systemName: "doc.on.clipboard") } text: { Text("Fertig · ⌘V") }
                    Text(vorschau).font(.system(size: 12)).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
                }
            case let .fehler(grund):
                zeile { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) } text: { Text(grund) }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .foregroundStyle(.white.opacity(0.94))
        .fixedSize()
    }

    private func zeile<L: View, T: View>(@ViewBuilder leading: () -> L, @ViewBuilder text: () -> T) -> some View {
        HStack(spacing: 9) { leading(); text().font(.system(size: 12.5, weight: .medium)).lineLimit(1) }
    }
}

/// Fünf kleine Balken, die den Live-Pegel zeigen. Rein dekorativ; bei Pegel 0 eine ruhige Ruhelage.
private struct Pegelbalken: View {
    let pegel: Float
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let hoehe = balkenHoehe(i)
                Capsule().fill(Color(red: 0.36, green: 0.62, blue: 1.0))
                    .frame(width: 2.5, height: hoehe)
            }
        }
        .frame(height: 13)
        .animation(.easeOut(duration: 0.08), value: pegel)
    }
    private func balkenHoehe(_ i: Int) -> CGFloat {
        // Mittlere Balken schlagen stärker aus; Pegel 0…1 auf 3…13 pt abbilden.
        let gewicht: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
        let p = CGFloat(max(0, min(1, pegel)))
        return 3 + p * 10 * gewicht[i]
    }
}

/// Baut das passive Overlay-Panel. **Bindend (M5):** übernimmt nie den Tastaturfokus, ist
/// klick-durchlässig, schwebt über allem, auf allen Spaces — sonst bräche das direkte Einfügen.
@MainActor
func macheOverlayPanel(inhalt: NSView) -> NSPanel {
    let panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.ignoresMouseEvents = true                 // klick-durchlässig
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.contentView = inhalt
    return panel
}

/// `NSPanel`-Unterklasse, die den Fokus GARANTIERT nie nimmt — die härteste Zusicherung gegen
/// das Stehlen des Tastaturfokus (über die Style-Maske hinaus).
final class PassivesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

> Umsetzer-Hinweis: Verwende `PassivesPanel` statt `NSPanel` in `macheOverlayPanel` (gleiche Konfiguration) — die überschriebenen Eigenschaften sind die verlässlichste Sperre gegen Fokus-Klau. Prüfe beim Bauen, dass `ProgressView`/SF-Symbole ohne zusätzliche Importe kompilieren.

- [ ] **Step 2: AppDelegate treibt das Panel**

In `TypeLessApp.swift` im `AppDelegate` (analog zu `setupWindow`/`beobachteSetup`/`aktualisiereSetupFenster` aus Teil 2b) ein Overlay-Panel-Feld, eine Beobachtung und die Positionierung ergänzen:

```swift
    private var overlayPanel: NSPanel?
    private var overlayHosting: NSHostingController<OverlayView>?

    /// Beobachtet ``DictationCoordinator/overlay`` von einer IMMER aktiven Stelle (nicht aus einer
    /// Fenster-Szene — s. Begründung bei `beobachteSetup`). `withObservationTracking` feuert
    /// einmalig, daher am Ende erneut registrieren.
    private func beobachteOverlay() {
        withObservationTracking {
            _ = dictation?.overlay
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.aktualisiereOverlay()
                self?.beobachteOverlay()
            }
        }
    }

    @MainActor private func aktualisiereOverlay() {
        guard let dictation else { return }
        if case .aus = dictation.overlay {
            overlayPanel?.orderOut(nil)
            return
        }
        if overlayPanel == nil {
            let hosting = NSHostingController(rootView: OverlayView(coordinator: dictation))
            hosting.view.frame.size = hosting.view.fittingSize
            let panel = macheOverlayPanel(inhalt: hosting.view)  // gibt ein PassivesPanel zurück
            overlayHosting = hosting
            overlayPanel = panel
        }
        guard let panel = overlayPanel, let hosting = overlayHosting else { return }
        // Größe an den aktuellen Inhalt anpassen, unten mittig auf dem aktiven Bildschirm platzieren.
        let groesse = hosting.view.fittingSize
        panel.setContentSize(groesse)
        if let screen = NSScreen.main {
            let r = screen.visibleFrame
            let x = r.midX - groesse.width / 2
            let y = r.minY + 96
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFront(nil)   // NICHT makeKey — der Fokus bleibt beim Zielfeld
    }
```

In `applicationDidFinishLaunching` (nach `beobachteSetup()`, Z. ~168) ergänzen:

```swift
        aktualisiereOverlay()
        beobachteOverlay()
```

- [ ] **Step 3: Bauen + bestehende Tests grün**

Run: `cd apps/macos && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!`; alle Kern-Tests grün (die App-Schicht ist nicht unit-getestet).

- [ ] **Step 4: `CLAUDE.md` anpassen**

In `CLAUDE.md` die „kein Overlay"-Aussagen aktualisieren. Konkret im Abschnitt „macOS-Shell … Diktieren (ab M4)": den Satz „**kein Overlay und keine Töne** — das Menüleisten-Symbol ist die einzige Rückmeldung" ersetzen durch eine Formulierung, die das neue Overlay beschreibt (klein, unten mittig, nur während des Diktats: Live-Pegel/Verarbeitung/Ergebnis; Textvorschau nur bei Zwischenablage; **weiterhin keine Töne**; Menüleisten-Symbol bleibt zusätzlich). Ebenso den analogen Hinweis im `DictationCoordinator`-Docstring (Z. 36–39: „Es gibt kein Overlay und keine Tonsignale.") auf „kein Ton; ein Overlay zeigt den Verlauf" anpassen, ohne die dahinterstehende Zwischenablage-Regel zu verändern.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TypeLess/OverlayWindow.swift apps/macos/Sources/TypeLess/TypeLessApp.swift apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift CLAUDE.md
git commit -m "Diktat-Overlay: passives NSPanel + AppDelegate-Steuerung, CLAUDE.md

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Abnahme (Handprobe)

Der eigentliche Beweis — die Fensterdarstellung ist nicht unit-getestet. Auf echter Hardware mit dem gebauten Bundle.

**Files:** keine (Abnahme; Ergebnis im Ledger/Report festhalten).

- [ ] **Step 1: Bundle bauen**

Run: `bash scripts/build-app.sh && open apps/macos/TypeLess.app`

- [ ] **Step 2: Alle fünf Phasen sichtbar prüfen**

Ein Diktat in ein normales Textfeld (direktes Einfügen): Overlay erscheint unten mittig, zeigt **Live-Pegel** beim Sprechen (Balken reagieren auf die Stimme), dann **Spinner**, dann kurz **„Eingefügt ✓"**, dann weg.
Ein Diktat in ein Ziel, das die Zwischenablage erzwingt (z. B. Terminal): Overlay endet mit **„Fertig · ⌘V" + gekürzter Textvorschau**, bleibt ein paar Sekunden.
Ein Diktat ohne Ton (Mikro stumm): **Fehler**-Overlay („Nichts erkannt" o. Ä.), dann weg.
Expected: alle Phasen sehen korrekt aus, das Overlay ist klein und unten mittig.

- [ ] **Step 3: Fokus-Nachweis (der kritische Punkt)**

Beim direkten Einfügen muss der Text weiterhin **an der Cursorposition** landen — das belegt, dass das Overlay den Fokus **nicht** gestohlen hat. Zusätzlich: Man kann das Overlay nicht anklicken (klick-durchlässig); Klicks gehen an das Fenster darunter.
Expected: direktes Einfügen funktioniert unverändert; das Overlay fängt keine Klicks/keinen Fokus.

- [ ] **Step 4: Ergebnis festhalten**

Ergebnis (bestanden/Befund) im Ledger notieren. Bei einem Fehlbefund an der Fokus-/Positions-Mechanik zurück in Task 5.

---

## Selbst-Review (gegen die Spec)

**Spec-Abdeckung:**
- Fünf Phasen (Hört zu/Verarbeitet/Eingefügt/Zwischenablage/Fehler) → Tasks 2 (Zustände) + 5 (Darstellung). ✅
- Live-Pegel echt (aus `SilenceDetector.peak`-Idee, Tap-Block) → Task 3. ✅
- Textvorschau nur bei Zwischenablage, 90 Zeichen Wortgrenze + „…" → Task 1 (Kürzung) + Task 2 (nur `.inZwischenablage` trägt sie). ✅
- „Eingefügt ✓" ~1 s, Zwischenablage ~4 s, Fehler ~2,5 s, Auto-Ausblenden → Task 4. ✅
- Position unten mittig; passives Fenster (kein Fokus-Klau, klick-durchlässig, floating, alle Spaces) → Task 5 (`PassivesPanel` + `macheOverlayPanel`). ✅
- Kern bleibt UI-frei; Logik testbar, Darstellung Handprobe → Tasks 1–4 im Core, Task 5 in `Sources/TypeLess`, Task 6 Handprobe. ✅
- Overlay nie Voraussetzung fürs Diktat → `overlay` ist reine Zusatz-Eigenschaft; keine Zustell-/Aufnahmelogik hängt daran. ✅
- Keine Töne → nichts im Plan erzeugt Ton. ✅
- CLAUDE.md/Docstring-Aktualisierung (M4-Umkehr) → Task 5 Step 4. ✅

**Platzhalter-Scan:** Die drei Test-Proben in Task 2/3/4 sind bewusst als Gerüst mit präziser Aussage + Umsetzer-Hinweis gehalten (sie müssen an die realen, hier nicht duplizierten Fakes der bestehenden `DictationCoordinatorTests.swift` andocken) — kein „TBD", sondern eine benannte, testbare Erwartung je Probe. Der gesamte Produktivcode ist vollständig ausformuliert.

**Typ-/Namenskonsistenz:** `OverlayZustand`-Fälle identisch über Task 1 (Definition), Task 2 (Setzen), Task 5 (Rendern). `overlay`, `overlayVorschau(_:grenze:)`, `aktuellerPegel()`, `startePegelPoll`/`stoppePegelPoll`, `blendeAusNach`, `PassivesPanel`/`macheOverlayPanel` durchgängig gleich benannt. `Zustellung.inZwischenablage(text:)` konsistent zwischen Task 2 Step 1 (Definition) und der Nutzung in `beendeVerarbeitung`.
