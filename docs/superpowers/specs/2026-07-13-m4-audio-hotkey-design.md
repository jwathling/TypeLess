# M4 — Audio, Hotkey und Diktat-Ablauf

**Ziel:** Fn-Taste halten, sprechen, loslassen — der fertige Text liegt in der Zwischenablage.
Damit ist TypeLess erstmals im Alltag benutzbar (wenn auch noch mit ⌘V statt automatischem
Einfügen; das kommt in M5).

**Stand:** Engine (M1/M2) und Swift-Shell (M3) sind fertig. `AppState` verwaltet den Sidecar,
`SidecarClient.process(pcm:mode:language:)` ist implementiert und gegen die echte Engine
verifiziert. M4 füllt die Lücke dazwischen: Es fehlt noch alles, was Ton aufnimmt und den
Hotkey hört.

## Entscheidungen des Anwenders

Diese Punkte sind mit dem Anwender geklärt und **nicht** vom Entwickler zu revidieren:

| Frage | Entscheidung |
|---|---|
| Auslösung | **Halten zum Sprechen** (kein Umschalten) |
| Taste | **Fn / 🌐** |
| Textausgabe in M4 | **Zwischenablage** (⌘V durch den Nutzer) |
| Sichtbare Rückmeldung | **Nur das Menüleisten-Symbol** — kein Overlay |
| Tonsignale | **Keine** — TypeLess bleibt stumm |
| Fn während laufender Verarbeitung | **Neue Aufnahme startet sofort**, die vorige läuft im Hintergrund weiter |

Der Entwickler hat gegen „kein Overlay" und „keine Töne" argumentiert (ohne beides gibt es
während und nach der Aufnahme faktisch keine Rückmeldung, wenn man nicht in die Menüleiste
sieht). Der Anwender hat das abgewogen und dabei bleibt es. Daraus folgt eine **verbindliche
Konsequenz**: Bei einem fehlgeschlagenen Diktat wird die Zwischenablage **nicht** überschrieben —
ein stiller Fehlschlag liefert dann wenigstens den alten Inhalt statt Leere.

## Verifizierte Vorbedingungen

Am Zielrechner **gemessen**, nicht angenommen:

- Ein `CGEventTap` (`.cgSessionEventTap`, `.listenOnly`) sieht die Fn-Taste als
  `flagsChanged` mit `keyCode == 63`; Drücken und Loslassen kommen als getrennte Ereignisse
  (`CGEventFlags.maskSecondaryFn` gesetzt bzw. nicht gesetzt).
- Die Systemeinstellung „Beim Drücken der 🌐-Taste" steht auf **„Keine Aktion"**
  (`defaults read com.apple.HIToolbox AppleFnUsageType` → `0`). Damit öffnet die Fn-Taste
  **keinen** Emoji-Picker mehr.
- **Folge: Wir verschlucken keine Ereignisse.** Der Tap liest nur mit. Alle Fn-Kombinationen
  (Fn+Pfeil, Fn+Entf) bleiben unangetastet. Das ist der entscheidende Vorteil gegenüber einem
  unterdrückenden Tap.

## Architektur

Alles Neue liegt in `TypeLessCore` (UI-frei, testbar). Die konkreten, hardwarenahen
Implementierungen stecken hinter Protokollen — der Koordinator ist damit vollständig ohne
Mikrofon, ohne Tastatur und ohne Sidecar testbar.

```
Sources/TypeLessCore/
  Hotkey/
    HotkeyMonitor.swift      # Protokoll + FnKeyMonitor (CGEventTap, nur mitlesend)
  Audio/
    AudioRecorder.swift      # Protokoll + AVAudioEngineRecorder
    AudioFormat.swift        # 48 kHz Stereo → 16 kHz Mono Float32 (AVAudioConverter)
  Dictation/
    DictationCoordinator.swift  # Zustandsautomat: idle → recording → processing → idle
    Pasteboard.swift         # Protokoll (Implementierung liegt in der App-Schicht)
  AppState.swift             # erweitert um `session` (s. u.)
Sources/TypeLess/
  SystemPasteboard.swift     # NSPasteboard — AppKit bleibt aus der Bibliothek heraus
```

### Zustände: zwei Achsen, nicht eine

`AppState.engine` (Sidecar: `stopped | starting | ready | failed`) bleibt **unverändert**.
Daneben tritt eine **zweite, unabhängige** Größe:

```swift
enum SessionState: Sendable, Equatable {
    case idle
    case recording(since: ContinuousClock.Instant)
    case processing
    case failed(String)      // letzter Fehlschlag, bis zum nächsten Diktat sichtbar
}
```

Das ist keine Kosmetik: Das `/health`-Polling schreibt alle 5 s in `engine`. Läge der
Aufnahmezustand im selben Enum, würde der nächste Poll die Aufnahmeanzeige überschreiben.
(Der Abschluss-Reviewer von M3 hat genau davor gewarnt.)

Das Menüleisten-Symbol leitet sich aus **beiden** Achsen ab, wobei die Sitzung Vorrang hat:

| Sitzung | Engine | Symbol |
|---|---|---|
| `recording` | — | `mic.circle.fill` (rot getönt) |
| `processing` | — | `ellipsis.circle` |
| `failed` | — | `exclamationmark.circle` |
| `idle` | `ready` | `mic.fill` |
| `idle` | `starting`/`stopped` | `mic` |
| `idle` | `failed` | `mic.slash` |

## Ablauf

```
Fn ↓ ──▶ AudioRecorder.start()          ──┐
         SidecarClient.preload()  (nebenläufig, Fehler werden ignoriert)
                                          │  … Nutzer spricht …
Fn ↑ ──▶ AudioRecorder.stop() → AudioBuffer
         │
         ├─ Dauer < 300 ms?  ──▶ kommentarlos verwerfen (versehentliches Antippen)
         ├─ nur Stille?      ──▶ session = .failed("Kein Ton aufgenommen — Mikrofon prüfen")
         │                        Zwischenablage bleibt unangetastet
         └─ sonst ──▶ session = .processing
                      SidecarClient.process(pcm:mode:.diktat, language: nil)
                        ├─ Erfolg ──▶ Pasteboard.write(finalText); session = .idle
                        └─ Fehler ──▶ session = .failed(Grund); Zwischenablage unangetastet
```

**`/preload` beim Drücken** ist der Grund, warum das Sprachmodell nicht erst nach dem
Loslassen zu laden beginnt. Schlägt es fehl, wird das ignoriert — `/process` lädt notfalls
selbst nach. Ein gescheiterter Preload darf ein Diktat **nie** verhindern.

**Nebenläufigkeit:** Drückt der Nutzer erneut, während noch verarbeitet wird, startet sofort
eine neue Aufnahme; die laufende Verarbeitung wird **nicht** abgebrochen und schreibt ihr
Ergebnis, sobald sie fertig ist. Der Sidecar serialisiert ohnehin (Lock, siehe M2), zwei
Diktate können sich also nicht überholen. Der Koordinator hält die laufenden Verarbeitungen
in einem Task-Set und wartet beim Beenden auf sie.

## Stille-Erkennung

Nach dem Loslassen wird der Spitzenpegel des gesamten Puffers bestimmt. Liegt er unter einem
Schwellwert (Vorschlag: **−50 dBFS**, entspricht rund 0,003 in Float32), gilt die Aufnahme als
tonlos: Es wird **nichts** an die Engine geschickt, `session` geht auf `.failed("Kein Ton
aufgenommen — Mikrofon prüfen")`, die Zwischenablage bleibt unberührt.

Das ist der einzige Fehlerfall, den der Nutzer ohne Overlay und ohne Ton sonst erst beim
Einfügen bemerken würde — und der einzige, der ihn 30 Sekunden Sprechen kostet.

Der Schwellwert wird gegen eine **echte, leise** Aufnahme kalibriert (nicht nur gegen
digitale Null), damit leises Sprechen nicht fälschlich als Stille gilt.

## Audioformat

Die Engine erwartet **16 kHz, mono, Float32** (siehe M2, `/process`). Das Eingabegerät liefert
üblicherweise 44,1 oder 48 kHz, oft stereo. `AVAudioConverter` rechnet um.

Diese Umrechnung ist die fehleranfälligste Stelle des Meilensteins — ein Fehler hier führt
nicht zu einem Absturz, sondern zu **stillschweigend schlechter Transkription** (falsche
Tonhöhe, halbe Geschwindigkeit). Deshalb wird sie mit einem **synthetischen Sinuston**
getestet: 440 Hz rein, 440 Hz raus, korrekte Länge, korrekte Abtastrate. Das fängt genau die
Klasse von Fehlern, die man sonst erst beim Anhören merkt.

## Berechtigungen

- **Mikrofon**: macOS fragt beim ersten Zugriff. Lehnt der Nutzer ab, geht `session` auf
  `.failed("Mikrofonzugriff verweigert")` mit einem Menüpunkt, der die Systemeinstellungen
  öffnet (`PermissionsService` aus M3 kann das bereits).
- **Eingabeüberwachung**: Ohne sie liefert `CGEvent.tapCreate` `nil`. Dann ist der Hotkey tot
  und die App **muss** das sagen, statt stumm zu bleiben: Menütext „Hotkey inaktiv —
  Eingabeüberwachung fehlt" plus Verweis in die Systemeinstellungen.
- **Fn-Einstellung**: Steht `AppleFnUsageType` nicht auf `0`, weist die App im Menü darauf hin
  („Fn öffnet den Emoji-Picker — in den Tastatur-Einstellungen auf ‚Keine Aktion' setzen").
  Nur ein Hinweis; die App ändert **keine** Systemeinstellungen.

## Robustheit des Tastatur-Hooks

macOS deaktiviert einen `CGEventTap` eigenmächtig, wenn dessen Callback zu langsam ist
(`.tapDisabledByTimeout`) oder der Nutzer ihn abschaltet (`.tapDisabledByUserInput`). Passiert
das unbemerkt, **klemmt der Hotkey stillschweigend** — der Nutzer drückt und nichts geschieht.

Daher: Der Callback behandelt beide Ereignistypen und macht den Tap sofort wieder scharf
(`CGEvent.tapEnable`). Der Callback selbst tut nichts Langsames — er reicht das Ereignis nur
weiter (kein Netzwerk, kein Dateizugriff, keine Modellaufrufe darin).

## Fehlerverhalten (vollständig)

| Fall | Verhalten |
|---|---|
| Aufnahme < 300 ms | kommentarlos verwerfen |
| nur Stille | `.failed("Kein Ton aufgenommen — Mikrofon prüfen")`, Zwischenablage unangetastet |
| Mikrofon-Recht fehlt | `.failed("Mikrofonzugriff verweigert")` + Weg in die Einstellungen |
| Eingabeüberwachung fehlt | Menü: „Hotkey inaktiv" + Weg in die Einstellungen |
| Engine nicht bereit | **trotzdem aufnehmen**; `/process` wartet, bis sie bereit ist |
| Engine gar nicht erreichbar | `.failed("Engine nicht erreichbar")`, Aufnahme verworfen |
| LLM ausgefallen (`refined: false`) | **kein Fehler** — der Rohtext geht in die Zwischenablage (M2-Vertrag) |
| Verarbeitung scheitert (500) | `.failed(Grund)`, Zwischenablage unangetastet |

## Tests

**Mit Attrappen (kein Mikrofon, keine Tastatur, kein Sidecar):**
- `DictationCoordinator`: der komplette Zustandsautomat — Drücken startet Aufnahme *und*
  Preload; Loslassen verarbeitet; zu kurz → verworfen; Stille → `.failed`, Pasteboard
  **nicht** beschrieben; Fehler → Pasteboard **nicht** beschrieben; `refined: false` → Text
  **doch** geschrieben; erneutes Drücken während der Verarbeitung → neue Aufnahme, alte läuft
  weiter.
- Ein gescheiterter Preload verhindert das Diktat nicht.

**Mit echtem Code, ohne Hardware:**
- `AudioFormat`: 440-Hz-Sinus, 48 kHz stereo → 16 kHz mono. Prüfung von Länge, Abtastrate und
  dominanter Frequenz (die Tonhöhe muss erhalten bleiben).
- Stille-Erkennung: digitale Null und sehr leises Rauschen → tonlos; normale Sprachlautstärke
  → nicht tonlos.

**Von Hand (gegen echte Hardware und echte Engine):**
- Fn halten, sprechen, loslassen → Text in der Zwischenablage, ⌘V fügt ihn ein.
- Fn kurz antippen → nichts passiert, kein Emoji-Picker.
- Fn+Pfeil, Fn+Entf funktionieren weiterhin normal.
- Mikrofon stummgeschaltet → „Kein Ton aufgenommen".
- Zweites Diktat während der Verarbeitung des ersten.

## Nicht in M4

- Automatisches Einfügen an der Cursorposition (**M5**).
- Modus-Umschalter (Diktat/E-Mail/Slack …) — M4 nutzt fest **Diktat** (**M6**).
- Frei belegbare Taste (**M7**).
- Overlay mit Pegelanzeige — bewusst verworfen; kann in M8 nachgezogen werden, ohne die
  Aufnahmelogik anzufassen.
